// ---- Preprocessor --------------------------------
#pragma semicolon 1
#pragma newdecls required

// ---- Includes ------------------------------------
#include <sourcemod>
#include <sdkhooks>
// <tf2_stocks> is included via tfdb.inc

#include <multicolors>
#include <cfgmap>
#include <tfdb>

// Requires tf2attributes.smx
#include <tf2attributes>

// ---- Plugin information --------------------------
#define PLUGIN_NAME        "[TF2] Dodgeball Unified"
#define PLUGIN_AUTHOR      "Mikah"
#define PLUGIN_VERSION     "1.3.1"
#define PLUGIN_URL         "https://github.com/Mikah31/TF2-Dodgeball-Unified"

public Plugin myinfo =
{
	name        = PLUGIN_NAME,
	author      = PLUGIN_AUTHOR,
	description = PLUGIN_NAME,
	version     = PLUGIN_VERSION,
	url         = PLUGIN_URL
};

// ---- Macros --------------------------------------
#define AnalogueTeam(%1) (%1^1) // Red & blue team differ by 1st bit, so we can xor to get other team, probably not that safe

// ---- Global variables ----------------------------
bool g_bEnabled;
bool g_bRoundStarted;

// Rocket spawning
int g_iRedSpawnerEntity;
int g_iBlueSpawnerEntity;
int g_iLastDeadTeam = view_as<int>(TFTeam_Red);
float g_fLastRocketSpawned;
Handle g_hManageRocketsTimer;

// FFA / NER
int g_iVoteTypeInProgress;
float g_fFFAvoteTime;
bool g_bFFAenabled;
float g_fNERvoteTime;
bool g_bNERenabled;

// Speedometer hud
char g_hHudText[225]; // 225 is character limit for hud text
Handle g_hHudTimer;
Handle g_hMainHudSync;

// Stealing
int g_iOldTeam[MAXPLAYERS + 1];
int g_iSteals [MAXPLAYERS + 1];

// Array of rocket structs & config struct
ArrayList g_rockets;
TFDBConfig currentConfig;

// ---- Forward handles (subplugins) ----------------
Handle g_ForwardOnRocketCreated;
Handle g_ForwardOnRocketDeflect;
Handle g_ForwardOnRocketSteal;
Handle g_ForwardOnRocketDelay;
Handle g_ForwardOnRocketNewTarget;
Handle g_ForwardOnRocketHitPlayer;
Handle g_ForwardOnRocketBounce;
Handle g_ForwardOnRocketsConfigExecuted;
Handle g_ForwardOnRocketOtherWavetype;
Handle g_ForwardOnRocketGameFrame;

// ---- Plugin start --------------------------------
public void OnPluginStart()
{
	LoadTranslations("tfdb.phrases.txt");

	// Loading configs whilst in game
	RegAdminCmd("sm_loadconfig", CmdLoadConfig, ADMFLAG_CONFIG, "Load TFDB config");

	// FFA
	RegAdminCmd("sm_ffa", CmdToggleFFA, ADMFLAG_CONFIG, "Forcefully toggle FFA (Free for all)");
	RegConsoleCmd("sm_voteffa", CmdVoteFFA, "Vote to toggle FFA");

	// NER
	RegAdminCmd("sm_ner", CmdToggleNER, ADMFLAG_CONFIG, "Forcefully toggle NER (Never ending rounds)");
	RegConsoleCmd("sm_votener", CmdVoteNER, "Vote to toggle NER");

	// Fixes soundbug (looping flamethrower sound) https://gitlab.com/nanochip/fixfireloop/-/blob/master/scripting/fixfireloop.sp
	AddTempEntHook("TFExplosion", OnTFExplosion);
}

// ---- Subplugin stuff -----------------------------
public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] strError, int iErrMax)
{
	RegPluginLibrary("tfdb");

	CreateNative("TFDB_IsDodgeballEnabled", Native_IsDodgeballEnabled);
	CreateNative("TFDB_CreateRocket", Native_CreateRocket);
	CreateNative("TFDB_IsValidRocket", Native_IsValidRocket);
	CreateNative("TFDB_FindRocketByEntity", Native_FindRocketByEntity);
	CreateNative("TFDB_GetRocketByIndex", Native_GetRocketByIndex);
	CreateNative("TFDB_SetRocketByIndex", Native_SetRocketByIndex);
	CreateNative("TFDB_IsRocketTarget", Native_IsRocketTarget);
	CreateNative("TFDB_GetCurrentConfig", Native_GetCurrentConfig);
	CreateNative("TFDB_SetCurrentConfig", Native_SetCurrentConfig);
	CreateNative("TFDB_IsFFAenabled", Native_IsFFAenabled);
	CreateNative("TFDB_ToggleFFA", Native_ToggleFFA);
	CreateNative("TFDB_IsNERenabled", Native_IsNERenabled);
	CreateNative("TFDB_ToggleNER", Native_ToggleNER);

	SetupForwards();
	
	return APLRes_Success;
}

void SetupForwards()
{
	g_ForwardOnRocketCreated = CreateGlobalForward("TFDB_OnRocketCreated", ET_Ignore, Param_Cell, Param_Array);
	g_ForwardOnRocketDeflect = CreateGlobalForward("TFDB_OnRocketDeflect", ET_Ignore, Param_Cell, Param_Array);
	g_ForwardOnRocketSteal = CreateGlobalForward("TFDB_OnRocketSteal", ET_Ignore, Param_Cell, Param_Array, Param_Cell);
	g_ForwardOnRocketDelay = CreateGlobalForward("TFDB_OnRocketDelay", ET_Ignore, Param_Cell, Param_Array);
	g_ForwardOnRocketNewTarget = CreateGlobalForward("TFDB_OnRocketNewTarget", ET_Ignore, Param_Cell, Param_Array);
	g_ForwardOnRocketHitPlayer = CreateGlobalForward("TFDB_OnRocketHitPlayer", ET_Ignore, Param_Cell, Param_Array);
	g_ForwardOnRocketBounce = CreateGlobalForward("TFDB_OnRocketBounce", ET_Ignore, Param_Cell, Param_Array);
	g_ForwardOnRocketsConfigExecuted = CreateGlobalForward("TFDB_OnRocketsConfigExecuted", ET_Ignore, Param_String, Param_Array);
	g_ForwardOnRocketOtherWavetype = CreateGlobalForward("TFDB_OnRocketOtherWavetype", ET_Ignore, Param_Cell, Param_Array, Param_Cell, Param_Float, Param_Float);
	g_ForwardOnRocketGameFrame = CreateGlobalForward("TFDB_OnRocketGameFrame", ET_Ignore, Param_Cell, Param_Array);
}

// ---- Enabling & disabling dodgeball --------------
public void OnConfigsExecuted()
{
	if (!IsDodgeBallMap()) return;
	
	EnableDodgeball();
}

public void OnMapEnd()
{
	DisableDodgeball();
}

void EnableDodgeball()
{
	if (g_bEnabled) return;

	g_rockets = new ArrayList(sizeof(Rocket));

	// Hooking events
	HookEvent("arena_round_start", OnSetupFinished, EventHookMode_PostNoCopy);
	HookEvent("teamplay_round_win", OnRoundEnd, EventHookMode_PostNoCopy);
	HookEvent("teamplay_round_stalemate", OnRoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Post);
	HookEvent("player_death", OnPlayerDeath, EventHookMode_Pre);
	HookEvent("post_inventory_application", OnPlayerInventory, EventHookMode_Post);
	HookEvent("object_deflected", OnObjectDeflected);	
	
	PrecacheSound(SOUND_ALERT, true);
	PrecacheSound(SOUND_SPAWN, true);
	PrecacheSound(SOUND_SPEEDUP, true);
	PrecacheSound(SOUND_NER_RESPAWNED, true);

	// Resetting global variables
	g_fFFAvoteTime = 0.0;
	g_fNERvoteTime = 0.0;
	g_bFFAenabled = false;
	g_bNERenabled = false;
	g_bRoundStarted = false;

	// Rocket speedometer
	g_hMainHudSync = CreateHudSynchronizer();

	// Execute dodgeball server config, infinite airblast & arena mode
	ServerCommand("exec \"sourcemod/dodgeball_enable.cfg\"");

	// Parsing rocket configs
	ParseConfig();

	g_bEnabled = true;
}

void DisableDodgeball()
{
	if (!g_bEnabled) return;

	DestroyAllRockets();
	delete g_rockets;

	// Unhooking all events
	UnhookEvent("arena_round_start", OnSetupFinished, EventHookMode_PostNoCopy);
	UnhookEvent("teamplay_round_win", OnRoundEnd, EventHookMode_PostNoCopy);
	UnhookEvent("teamplay_round_stalemate", OnRoundEnd, EventHookMode_PostNoCopy);
	UnhookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Post);	
	UnhookEvent("player_death", OnPlayerDeath, EventHookMode_Pre);
	UnhookEvent("post_inventory_application", OnPlayerInventory, EventHookMode_Post);
	UnhookEvent("object_deflected", OnObjectDeflected);

	ServerCommand("exec \"sourcemod/dodgeball_disable.cfg\"");

	// Cleaning up timers
	if (g_hManageRocketsTimer != null)
	{
		KillTimer(g_hManageRocketsTimer);
		g_hManageRocketsTimer = null;
	}

	if (g_hHudTimer != null)
	{
		KillTimer(g_hHudTimer);
		g_hHudTimer = null;
	}

	delete g_hMainHudSync;

	g_bEnabled = false;
}

// ---- Rocket homing logic -------------------------
public void OnGameFrame()
{
	if (!g_bEnabled || !g_bRoundStarted) return;

	if (!BothTeamsPlaying())
	{
		g_bRoundStarted = false;
		return;
	}
	
	Rocket rocket;

	// Go over each rocket in ArrayList
	for (int n = 0; n < g_rockets.Length; n++)
	{
		g_rockets.GetArray(n, rocket);

		// We will clear invalid rockets in our ManageRockets timer
		if (!IsValidRocket(rocket.iRef)) continue;

		// If we had set fTimeLastDeflect in OnObjectDeflected it would be out of sync with OnGameFrame, resulting in deflection delays
		if (rocket.bRecentlyReflected)
		{
			rocket.fTimeLastDeflect = GetGameTime(); 
			rocket.bRecentlyReflected = false;
		}

		// For creating crawling downspikes
		if (rocket.bRecentlyBounced)
		{
			rocket.fTimeLastBounce = GetGameTime();
			rocket.bRecentlyBounced = false;
		}
		
		float fTimeSinceLastDeflect = GetGameTime() - rocket.fTimeLastDeflect;
		float fTimeSinceLastBounce = GetGameTime() - rocket.fTimeLastBounce;

		static float fRocketPosition[3]; GetEntPropVector(rocket.iEntity, Prop_Data, "m_vecOrigin", fRocketPosition);

		// Dragging
		if (fTimeSinceLastDeflect <= currentConfig.fDragTimeMax)
		{
			static float fViewAngles[3];
			GetClientEyeAngles(rocket.iOwner, fViewAngles);
			GetAngleVectors(fViewAngles, rocket.fDirection, NULL_VECTOR, NULL_VECTOR);

			// Select new target if needed, rocket.fDirection has been changed already in above code for new target calculation
			if (!rocket.bHasTarget)
			{
				rocket.iTarget = SelectTarget(rocket.iTeam, rocket.iOwner, fRocketPosition, rocket.fDirection);

				Forward_OnRocketNewTarget(n, rocket);

				// If it is a wave rocket we need to set starting distance to the target to determine the phase of the wave
				if (currentConfig.iWavetype)
				{
					static float fPlayerPosition[3];
					GetClientEyePosition(rocket.iTarget, fPlayerPosition);
					rocket.fWaveDistance = GetVectorDistance(fPlayerPosition, fRocketPosition);
				}

				rocket.bHasTarget = true;
				rocket.EmitRocketSound(SOUND_ALERT);
			}
		}
		// Turn to target if not dragging & outside of delay till turning
		else if (rocket.bHasTarget && fTimeSinceLastDeflect >= currentConfig.fTurningDelay + currentConfig.fDragTimeMax)
		{
			static float fDirectionToTarget[3], fPlayerPosition[3];

			GetClientEyePosition(rocket.iTarget, fPlayerPosition);

			MakeVectorFromPoints(fRocketPosition, fPlayerPosition, fDirectionToTarget);
			NormalizeVector(fDirectionToTarget, fDirectionToTarget);

			// Fake rocket curving without affecting velocity
			// Previously this was a side-effect of limiting sv_maxvelocity
			if (rocket.RangeToTarget() > CURVE_RANGE && rocket.fCurveFactor)
			{
				float fDistanceFactor = CURVE_RANGE / rocket.RangeToTarget();
				static float fDeltaToTarget[3]; SubtractVectors(fDirectionToTarget, rocket.fDirection, fDeltaToTarget);
				
				if (!rocket.fCurveDirection[0])
				{
					// This is might not be very intuitive, but it works well enough
					// We curve away from target
					rocket.fCurveDirection[0] = fDeltaToTarget[0] * rocket.fDirection[1] * rocket.fDirection[1] > 0.0 ? 1.0 : -1.0;
					rocket.fCurveDirection[1] = fDeltaToTarget[1] * rocket.fDirection[0] * rocket.fDirection[0] > 0.0 ? 1.0 : -1.0;
				}

				// We modify player position & recalculate direction to target, we let turnrate do the heavy lifting
				fPlayerPosition[0] += rocket.fCurveDirection[0] * (1.0 + FloatAbs(fDeltaToTarget[0])) * rocket.fCurveFactor * fDistanceFactor;
				fPlayerPosition[1] += rocket.fCurveDirection[1] * (1.0 + FloatAbs(fDeltaToTarget[1])) * rocket.fCurveFactor * fDistanceFactor;

				MakeVectorFromPoints(fRocketPosition, fPlayerPosition, fDirectionToTarget);
				NormalizeVector(fDirectionToTarget, fDirectionToTarget);
			}
			// Reset curve direction
			else
			{
				rocket.fCurveDirection[0] = 0.0;
				rocket.fCurveDirection[1] = 0.0;
			}

			// Turnrate has already been clamped between 0.0 & 1.0
			// Turning outside of orbit range, or if the rocket is being delayed
			if (rocket.RangeToTarget() > ORBIT_RANGE || rocket.bBeingDelayed)
			{
				// Smoothly change to direction to target using turnrate
				rocket.fDirection[0] += (fDirectionToTarget[0] - rocket.fDirection[0]) * rocket.fTurnrate;
				rocket.fDirection[1] += (fDirectionToTarget[1] - rocket.fDirection[1]) * rocket.fTurnrate;
				rocket.fDirection[2] += (fDirectionToTarget[2] - rocket.fDirection[2]) * rocket.fTurnrate;
			}
			// We want to turn less whilst in orbit to make it easier
			else
			{
				rocket.fDirection[0] += (fDirectionToTarget[0] - rocket.fDirection[0]) * rocket.fTurnrate * currentConfig.fOrbitFactor;
				rocket.fDirection[1] += (fDirectionToTarget[1] - rocket.fDirection[1]) * rocket.fTurnrate * currentConfig.fOrbitFactor;
				rocket.fDirection[2] += (fDirectionToTarget[2] - rocket.fDirection[2]) * rocket.fTurnrate;
			}

			// In orbit increase delay timer
			if (rocket.RangeToTarget() < ORBIT_RANGE)
				rocket.fTimeInOrbit += GetTickInterval();

			// Wave stuff, we do not wave whilst within certain range
			if (currentConfig.iWavetype && rocket.iDeflectionCount && rocket.RangeToTarget() < WAVE_RANGE)
			{
				float fDistanceToPlayer = GetVectorDistance(fPlayerPosition, fRocketPosition);
				
				// See inf. square well -> (L-x) * nπ/L, x starts at max distance, so L-x = distance travelled to target (not exactly, but close enough)
				float fPhase = (rocket.fWaveDistance - fDistanceToPlayer) * currentConfig.fWaveOscillations * 3.14159 / rocket.fWaveDistance;

				switch (currentConfig.iWavetype)
				{
					case(1): // Vertical wave
					{
						// (Attempted) recreation of the 'classic' way of waving
						rocket.fDirection[2] += currentConfig.fWaveAmplitude * -Cosine(fPhase);
					}
					case(2): // Horizontal wave
					{
						// In theory we should:
						// 1. define a new system of coordinates: x' y' that is in the travel direction of the rocket, which we define [1, 0], x' being the travel direction
						// 2. Transformation angle θ, following https://www.desmos.com/calculator/ckbuqs3edo, modulate the y' direction with a sine wave
						// 3. Calculate the changes in our absolute system of coordinates using rotation matrices
						// This however does not work, as the rocket slows down in weird ways, as fDirection is tied to velocity

						// This works suprisingly well, it does dampen when we're angled 45 deg
						if (FloatAbs(rocket.fDirection[0]) > FloatAbs(rocket.fDirection[1]))
							rocket.fDirection[1] += currentConfig.fWaveAmplitude * Sine(fPhase);
						else
							rocket.fDirection[0] += currentConfig.fWaveAmplitude * Sine(fPhase);
					}
					case (3): // Circular wave
					{
						if (FloatAbs(rocket.fDirection[0]) > FloatAbs(rocket.fDirection[1]))
							rocket.fDirection[1] += currentConfig.fWaveAmplitude * Sine(fPhase);
						else
							rocket.fDirection[0] += currentConfig.fWaveAmplitude * Sine(fPhase);

						// Offset by -90 deg, gives circular polarization which first waves up (so that it doesn't immediately hit the ground)
						rocket.fDirection[2] += currentConfig.fWaveAmplitude * Sine(fPhase + DegToRad(-90.0));
					}
					default: // Subplugin wavetypes
					{
						Forward_OnRocketOtherWavetype(n, rocket, currentConfig.iWavetype, fPhase, currentConfig.fWaveAmplitude);
					}
				}
			}
		}

		Forward_OnRocketGameFrame(n, rocket);

		static float fRocketAngles[3], fRocketVelocity[3];
		GetVectorAngles(rocket.fDirection, fRocketAngles);

		CopyVec3(fRocketVelocity, rocket.fDirection);
		ScaleVector(fRocketVelocity, rocket.fSpeed);
	
		// Rocket is being delayed
		if (rocket.fTimeInOrbit > currentConfig.fDelayTime)
		{
			if (!rocket.bBeingDelayed)
			{
				Forward_OnRocketDelay(n, rocket);

				CPrintToChatAll("%t", "Dodgeball_Delay_Announce_All", rocket.iTarget);
				rocket.EmitRocketSound(SOUND_SPEEDUP, rocket.iEntity);
				rocket.bBeingDelayed = true;
			}

			ScaleVector(fRocketVelocity, (rocket.fTimeInOrbit - currentConfig.fDelayTime) + 1.0);
		}

		// This to makes downspikes work, we dampen bounces when rocket is within waving range (otherwise the rocket might bounce back and forth over the player)
		if (fTimeSinceLastBounce > currentConfig.fBounceTime || (!currentConfig.bDownspikes && rocket.RangeToTarget() < WAVE_RANGE))
		{
			SetEntPropVector(rocket.iEntity, Prop_Data, "m_vecAbsVelocity", fRocketVelocity);
			SetEntPropVector(rocket.iEntity, Prop_Send, "m_angRotation", fRocketAngles);
		}

		// We have to write changes each time since we're using structs
		g_rockets.SetArray(n, rocket);
	}
}

// ---- Rocket bouncing -----------------------------
public Action OnStartTouch(int iEntity, int iClient)
{
	int iIndex = FindRocketIndexByEntity(iEntity);
	if (iIndex == -1) return Plugin_Continue;

	Rocket rocket;
	g_rockets.GetArray(iIndex, rocket);

	// We have hit a player
	if (IsValidClient(iClient))
	{
		// We set the rocket owner to 0 if rocket is spawn rocket, otherwise kill would be awarded to an opponent we set it to earlier
		if (rocket.iDeflectionCount == 0)
		{
			SetEntPropEnt(rocket.iEntity, Prop_Send, "m_hOwnerEntity", 0);
			rocket.iOwner = 0;
		}
		
		if (rocket.bStolen && !currentConfig.bStolenRocketsDoDamage && rocket.bHasTarget)
		{
			SetEntDataFloat(rocket.iEntity, FindSendPropInfo("CTFProjectile_Rocket", "m_iDeflected") + 4, 0.0, true);
			rocket.fDamage = 0.0;
		}
		
		Forward_OnRocketHitPlayer(iIndex, rocket);

		return Plugin_Continue;
	}

	// Bounce limit reached, destroy rocket
	if (++rocket.iBounces > currentConfig.iMaxBounces)
	{
		RemoveEdict(rocket.iEntity);
		g_rockets.Erase(iIndex);

		return Plugin_Continue;
	}

	// We have only modified the number of bounces
	g_rockets.SetArray(iIndex, rocket);

	// The rocket hits the ground, calculate new rocket angles after bounce in OnTouch
	SDKHook(rocket.iEntity, SDKHook_Touch, OnTouch);
	
	return Plugin_Continue;
}

public Action OnTouch(int iEntity, int iClient)
{
	int iIndex = FindRocketIndexByEntity(iEntity);
	if (iIndex == -1) return Plugin_Continue;

	Rocket rocket;
	g_rockets.GetArray(iIndex, rocket);

	static float fPosition[3]; GetEntPropVector(rocket.iEntity, Prop_Data, "m_vecOrigin", fPosition);
	static float fAngles[3]; GetEntPropVector(rocket.iEntity, Prop_Data, "m_angRotation", fAngles);
	static float fVelocity[3]; GetEntPropVector(rocket.iEntity, Prop_Data, "m_vecAbsVelocity", fVelocity);

	Handle hTrace = TR_TraceRayFilterEx(fPosition, fAngles, MASK_SHOT, RayType_Infinite, TraceFilter, rocket.iEntity);

	if (!TR_DidHit(hTrace))
	{
		delete hTrace;
		return Plugin_Continue;
	}

	static float fNormal[3];
	TR_GetPlaneNormal(hTrace, fNormal);

	delete hTrace;

	// We scale fNormal with 2 * dotproduct & subtract fVelocity to get the 'outgoing' bounce vector
	static float fBounceVec[3];
	ScaleVector(fNormal, GetVectorDotProduct(fNormal, fVelocity) * 2.0);
	SubtractVectors(fVelocity, fNormal, fBounceVec);
	
	static float fNewAngles[3];
	GetVectorAngles(fBounceVec, fNewAngles);

	TeleportEntity(rocket.iEntity, NULL_VECTOR, fNewAngles, fBounceVec);

	// We force non-elastic bounces when in orbit, as otherwise rocket will bounce around the player constantly
	if (!currentConfig.bDownspikes && rocket.RangeToTarget() < WAVE_RANGE)
	{
		// The reason why crawling downspikes work is because the direction was never updated
		NormalizeVector(fBounceVec, fBounceVec);
		CopyVec3(rocket.fDirection, fBounceVec);
	}

	rocket.bRecentlyBounced = true;

	Forward_OnRocketBounce(iIndex, rocket);

	// We have modified bRecentlyBounced & fDirection->(depending on if we should do crawling downspikes or not)
	g_rockets.SetArray(iIndex, rocket);
	
	SDKUnhook(rocket.iEntity, SDKHook_Touch, OnTouch);

	return Plugin_Handled;
}

public bool TraceFilter(int iEntity, int iContentsMask, any aData)
{
	// Pretty sure TraceFilters are broken, but we're checking if the entity hit by the trace is our rocket (as we do not want to surface normal of our rocket)
	return (iEntity != aData);
}

// ---- Rocket spawning -----------------------------
void CreateRocket(int iSpawnerEntity, int iTeam)
{
	Rocket rocket;

	rocket.iEntity = CreateEntityByName("tf_projectile_rocket");
	rocket.iRef = EntIndexToEntRef(rocket.iEntity);
	rocket.iTeam = g_bFFAenabled ? 1 : iTeam;

	rocket.fSpeed = EvaluateFormula(currentConfig.strSpeedFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fSpeed = Clamp(rocket.fSpeed, currentConfig.fSpeedMin, currentConfig.fSpeedMax);
	rocket.fTurnrate = EvaluateFormula(currentConfig.strTurnrateFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fTurnrate = Clamp(rocket.fTurnrate, currentConfig.fTurnrateMin, currentConfig.fTurnrateMax);
	rocket.fTurnrate = Clamp(rocket.fTurnrate, 0.0, 1.0);
	rocket.fDamage = EvaluateFormula(currentConfig.strDamageFormula, rocket.iDeflectionCount, rocket.fSpeed) / 3; // Account for critical rocket damage being 3x

	static float fPosition[3]; GetEntPropVector(iSpawnerEntity, Prop_Send, "m_vecOrigin", fPosition);
	static float fAngles[3]; GetEntPropVector(iSpawnerEntity, Prop_Send, "m_angRotation", fAngles);

	TeleportEntity(rocket.iEntity, fPosition, fAngles);

	GetAngleVectors(fAngles, rocket.fDirection, NULL_VECTOR, NULL_VECTOR);

	SetEntProp(rocket.iEntity, Prop_Send, "m_iTeamNum", currentConfig.bAirblastTeamRockets ? rocket.iTeam + 32 : rocket.iTeam);
	SetEntProp(rocket.iEntity, Prop_Send, "m_bCritical", 1); // We just want critical rockets for visibility

	// We have to set rocket owner to a valid player, otherwise first object_deflected event is skipped
	// This does mean that the rocket can't hit the selected enemy either
	rocket.iOwner = SelectTarget(AnalogueTeam(iTeam), 0, fPosition, rocket.fDirection);
	SetEntPropEnt(rocket.iEntity, Prop_Send, "m_hOwnerEntity", rocket.iOwner);

	// using sm_dump_netprops:
	// CTFProjectile_Rocket (type DT_TFProjectile_Rocket)
	// ...
	// Member: m_iDeflected (offset 1264) (type integer) (bits 4) (Unsigned)
  	// Member: m_hLauncher (offset 1272) (type integer) (bits 21) (Unsigned)
	//
	// Missing m_fldamage? We set damage by offsetting from m_iDeflected
	SetEntDataFloat(rocket.iEntity, FindSendPropInfo("CTFProjectile_Rocket", "m_iDeflected") + 4, rocket.fDamage, true);

	rocket.iTarget = SelectTarget(iTeam, rocket.iOwner, fPosition, rocket.fDirection);
	rocket.bHasTarget = true;

	SDKHook(rocket.iEntity, SDKHook_StartTouch, OnStartTouch);

	Format(g_hHudText, sizeof(g_hHudText), "%t", "Dodgeball_Hud_Speedometer", rocket.SpeedMpH(), rocket.iDeflectionCount);

	Forward_OnRocketCreated(g_rockets.Length, rocket);

	g_rockets.PushArray(rocket);
	DispatchSpawn(rocket.iEntity);

	rocket.EmitRocketSound(SOUND_ALERT);
	rocket.EmitRocketSound(SOUND_SPAWN, rocket.iTeam == view_as<int>(TFTeam_Blue) ? g_iBlueSpawnerEntity : g_iRedSpawnerEntity);
}

// ---- Rocket deflecting ---------------------------
public void OnObjectDeflected(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	int iEntity = hEvent.GetInt("object_entindex");

	int iIndex = FindRocketIndexByEntity(iEntity);
	if (iIndex == -1) return; // Object deflected was not a rocket of ours

	Rocket rocket;
	g_rockets.GetArray(iIndex, rocket);

	int iRocketPreviousTeam = rocket.iTeam; // For stealing check

	// Setting new rocket variables
	rocket.iOwner = GetClientOfUserId(hEvent.GetInt("userid"));
	rocket.iTeam = g_bFFAenabled ? 1 : GetClientTeam(rocket.iOwner);
	rocket.iDeflectionCount++;

	rocket.iBounces = 0; 
	rocket.fWaveDistance = 0.0;
	rocket.fTimeInOrbit = 0.0;

	rocket.fSpeed = EvaluateFormula(currentConfig.strSpeedFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fSpeed = Clamp(rocket.fSpeed, currentConfig.fSpeedMin, currentConfig.fSpeedMax);

	rocket.fTurnrate = EvaluateFormula(currentConfig.strTurnrateFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fTurnrate = Clamp(rocket.fTurnrate, currentConfig.fTurnrateMin, currentConfig.fTurnrateMax);
	rocket.fTurnrate = Clamp(rocket.fTurnrate, 0.0, 1.0);

	rocket.fCurveFactor = EvaluateFormula(currentConfig.strCurveFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fCurveFactor = Clamp(rocket.fCurveFactor, currentConfig.fCurveMin, currentConfig.fCurveMax);

	rocket.fDamage = EvaluateFormula(currentConfig.strDamageFormula, rocket.iDeflectionCount, rocket.fSpeed) / 3;

	// m_iTeamNum is 6 bits, | 32 sets the highest bit (which apparently makes it so that you/teammates can hit your own projectiles)
	SetEntProp(rocket.iEntity, Prop_Send, "m_iTeamNum", currentConfig.bAirblastTeamRockets ? rocket.iTeam | 32 : rocket.iTeam);

	SetEntDataFloat(rocket.iEntity, FindSendPropInfo("CTFProjectile_Rocket", "m_iDeflected") + 4, rocket.fDamage, true);
	SetEntPropEnt(rocket.iEntity, Prop_Send, "m_hOwnerEntity", rocket.iOwner);

	// Stealing check, we can not steal a rocket which doesn't have a target
	// We can also not steal a rocket which didn't change team (hit own rocket, or whilst FFA)
	if (rocket.iOwner != rocket.iTarget && rocket.bHasTarget && iRocketPreviousTeam != rocket.iTeam)
	{
		g_iSteals[rocket.iOwner]++;
		Forward_OnRocketSteal(iIndex, rocket, g_iSteals[rocket.iOwner]);

		if (currentConfig.iMaxSteals >= 0)
		{
			// Kill Stealer
			if (g_iSteals[rocket.iOwner] > currentConfig.iMaxSteals)
			{
				CPrintToChat(rocket.iOwner, "%t", "Dodgeball_Steal_Slay_Client");
				CPrintToChatAll("%t", "Dodgeball_Steal_Announce_Slay_All", rocket.iOwner);

				SDKHooks_TakeDamage(rocket.iOwner, rocket.iOwner, rocket.iOwner, 9999.0);
			}
			// Warn stealer
			else
			{
				CPrintToChat(rocket.iOwner, "%t", "Dodgeball_Steal_Warning_Client", g_iSteals[rocket.iOwner], currentConfig.iMaxSteals);
				CPrintToChatAll("%t", "Dodgeball_Steal_Announce_All", rocket.iOwner, rocket.iTarget);
			}
		}
		rocket.bStolen = true;
	}
	else
	{
		rocket.bStolen = false;
	}

	rocket.bHasTarget = false;
	rocket.bRecentlyReflected = true; // We set our rocket.fTimeLastDeflect in sync with OnGameTick() for dragging

	// Updating hud text
	Format(g_hHudText, sizeof(g_hHudText), "%t", "Dodgeball_Hud_Speedometer", rocket.SpeedMpH(), rocket.iDeflectionCount);

	Forward_OnRocketDeflect(iIndex, rocket);

	g_rockets.SetArray(iIndex, rocket);
}

// ---- Rocket target selection ---------------------
int SelectTarget(int iTeam, int iOwner, float fPosition[3], float fDirection[3])
{
	int iTarget = -1;
	float fTargetWeight = 0.0;

	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsValidClient(iClient)) continue;
		if (iTeam == GetClientTeam(iClient)) continue; 	// Selecting a target NOT on iTeam
		if (iOwner == iClient) continue; 				// Do not target owner (for FFA rockets)

		static float fClientPosition[3]; GetClientEyePosition(iClient, fClientPosition);
		static float fDirectionToClient[3]; MakeVectorFromPoints(fPosition, fClientPosition, fDirectionToClient);

		float fNewWeight = GetVectorDotProduct(fDirection, fDirectionToClient);

		if (fTargetWeight <= fNewWeight || (iTarget == -1))
		{
			iTarget = iClient;
			fTargetWeight = fNewWeight;
		}
	}

	return iTarget;
}

// ---- Round started, setup attributes & timers ----
public void OnSetupFinished(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	if (!BothTeamsPlaying()) return;

	PopulateRocketSpawners();
	g_fLastRocketSpawned = 0.0;

	SetAttributes();

	g_hManageRocketsTimer = CreateTimer(0.5, ManageRockets, _, TIMER_REPEAT);

	if (currentConfig.bSpeedometer)
		g_hHudTimer = CreateTimer(0.1, RocketSpeedometer, _, TIMER_REPEAT);

	g_bRoundStarted = true;
}

// ---- Spawning & deleting rockets -----------------
public Action ManageRockets(Handle hTimer, any Data)
{
	if (!g_bRoundStarted || !g_bEnabled) return Plugin_Continue;

	RemoveInvalidRockets();

	// Spawn new rockets if needed
	if (g_rockets.Length < currentConfig.iMaxRockets && g_fLastRocketSpawned + currentConfig.fSpawnInterval < GetGameTime())
	{
		CreateRocket(g_iLastDeadTeam == view_as<int>(TFTeam_Blue) ? g_iBlueSpawnerEntity : g_iRedSpawnerEntity, g_iLastDeadTeam);
		g_fLastRocketSpawned = GetGameTime();
	}

	return Plugin_Continue;
}

// ---- Speedometer hud -----------------------------
public Action RocketSpeedometer(Handle hTimer, any Data)
{
	if (!g_bRoundStarted || !g_bEnabled || !currentConfig.bSpeedometer) return Plugin_Continue;
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientInGame(iClient)) continue;

		SetHudTextParams(0.375, 0.925, 0.5, 255, 255, 255, 255, 0, 0.0, 0.12, 0.12);			
		ShowSyncHudText(iClient, g_hMainHudSync, g_hHudText);
	}

	return Plugin_Continue;
}

void PopulateRocketSpawners()
{
	int iEntity = -1;

	while ((iEntity = FindEntityByClassname(iEntity, "info_target")) != -1)
	{
		char strName[32]; GetEntPropString(iEntity, Prop_Data, "m_iName", strName, sizeof(strName));

		// Have not seen tf_dodgeball_TEAM as of yet
		if ((StrContains(strName, "rocket_spawn_red") != -1) || (StrContains(strName, "tf_dodgeball_red") != -1))
			g_iRedSpawnerEntity = iEntity;
			
		if ((StrContains(strName, "rocket_spawn_blu") != -1) || (StrContains(strName, "tf_dodgeball_blu") != -1))
			g_iBlueSpawnerEntity = iEntity;
	}
}

void SetAttributes()
{
	// Setting weapon attributes (airblast delay, push prevention, etc.)
	int iWeapon;

	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsValidClient(iClient)) continue;

		// Disable collisions with other players, COLLISION_GROUP_PUSHAWAY = 17
		if (currentConfig.bDisablePlayerCollisions)
			SetEntProp(iClient, Prop_Data, "m_CollisionGroup", 17);
		// Set back to normal, COLLISION_GROUP_PLAYER = 5
		else 
			SetEntProp(iClient, Prop_Data, "m_CollisionGroup", 5);

		iWeapon = GetEntPropEnt(iClient, Prop_Data, "m_hActiveWeapon");

		// Attribute 256 is "mult airblast refire time", which governs airblast delays (https://wiki.teamfortress.com/wiki/List_of_item_attributes)
		TF2Attrib_SetByDefIndex(iWeapon, 256, currentConfig.fAirblastDelay);

		if (currentConfig.bPushPrevention)
		{
			// No airblast pushback: 823
			TF2Attrib_SetByDefIndex(iWeapon, 823, 1.0);
		}
		else
		{
			TF2Attrib_SetByDefIndex(iWeapon, 823, 0.0);
			// No viewpunch (Otherwise we airblast spectating people): 825
			TF2Attrib_SetByDefIndex(iWeapon, 825, 1.0);
			// Airblast pushback scale: 255
			TF2Attrib_SetByDefIndex(iWeapon, 255, currentConfig.fPushScale);
		}
	}
}

// ---- General -------------------------------------
public void OnClientPutInServer(int iClient)
{
	g_iSteals[iClient] = 0;
	g_iOldTeam[iClient] = 0;
}

// Removing flamethrower attack
public Action OnPlayerRunCmd(int iClient, int &iButtons)
{
	if (g_bEnabled) iButtons &= ~IN_ATTACK;

	return Plugin_Continue;
}

// Removing all slots except for flamethrower
public void OnPlayerInventory(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	if (!IsValidClient(iClient)) return;
	
	for (int iSlot = 1; iSlot < 5; iSlot++)
	{
		int iEntity = GetPlayerWeaponSlot(iClient, iSlot);
		if (iEntity != -1)
			RemoveEdict(iEntity);
	}
}

public void OnPlayerSpawn(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	if (!IsValidClient(iClient)) return;
	
	TFClassType iClass = TF2_GetPlayerClass(iClient);
	
	if (iClass == TFClass_Pyro) return;
	
	TF2_SetPlayerClass(iClient, TFClass_Pyro, _, true);
	TF2_RespawnPlayer(iClient);
}

public void OnPlayerDeath(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	if (!g_bRoundStarted) return;

	int iClient = GetClientOfUserId(hEvent.GetInt("userid"));
	g_iLastDeadTeam = GetClientTeam(iClient);

	g_iSteals[iClient] = 0;

	int iInflictor = hEvent.GetInt("inflictor_entindex");
	int iIndex = FindRocketIndexByEntity(iInflictor);

	// Player died due a rocket
	if (iIndex != -1)
	{
		Rocket rocket;
		g_rockets.GetArray(iIndex, rocket);

		CPrintToChatAll("%t", "Dodgeball_Death_Message", iClient, rocket.SpeedMpH(), rocket.iDeflectionCount);
	}
	
	// If it is a 1v1 (someone left / went to spectator, disable NER)
	if (g_bNERenabled && GetTeamClientCount(g_iLastDeadTeam) <= 1 && GetTeamClientCount(AnalogueTeam(g_iLastDeadTeam)) <= 1)
	{
		CPrintToChatAll("%t", "Dodgeball_NER_Not_Enough_Players_Disabled");
		g_fNERvoteTime = 0.0;
		g_bNERenabled = false;
	}

	// Switch people's team until 1 player left if FFA or NER
	if ((g_bNERenabled || g_bFFAenabled) && GetTeamAliveCount(g_iLastDeadTeam) == 1 && GetTeamAliveCount(AnalogueTeam(g_iLastDeadTeam)) > 1)
	{
		int iRandomOpponent = GetTeamRandomAliveClient(AnalogueTeam(g_iLastDeadTeam));
		g_iOldTeam[iRandomOpponent] = AnalogueTeam(g_iLastDeadTeam);
		
		// This is how to switch a persons team who is alive
		SetEntProp(iRandomOpponent, Prop_Send, "m_lifeState", 2); // LIFE_DEAD = 2
		ChangeClientTeam(iRandomOpponent, g_iLastDeadTeam);
		SetEntProp(iRandomOpponent, Prop_Send, "m_lifeState", 0); // LIFE_ALIVE = 0
	}

	// Respawn all if never ending rounds is enabled, someone died & both teams had 1 player left
	if (g_bNERenabled && GetTeamAliveCount(g_iLastDeadTeam) == 1 && GetTeamAliveCount(AnalogueTeam(g_iLastDeadTeam)) == 1)
	{
		// Respawn every (dead) player
		for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer++)
		{
			if (!IsClientInGame(iPlayer))
				continue;

			int iLifeState = GetEntProp(iPlayer, Prop_Send, "m_lifeState");

			// If player is NOT alive, (LIFE_ALIVE = 0), respawn them
			if (iLifeState)
			{
				// Reset to old team
				if (g_iOldTeam[iPlayer])
				{
					ChangeClientTeam(iPlayer, g_iOldTeam[iPlayer]);
					g_iOldTeam[iPlayer] = 0;
				}

				// If the dead team only has 1 player left (in the team) the round will end (since we respawn that player the next frame), we switch someone
				if (GetTeamClientCount(g_iLastDeadTeam) == 1 && GetTeamClientCount(AnalogueTeam(g_iLastDeadTeam)) > 1)
					ChangeClientTeam(iPlayer, g_iLastDeadTeam);
				
				TF2_RespawnPlayer(iPlayer);
			}
		}
		// We have to respawn the last player 1 frame later, as they haven't died yet (since this is a PRE hook)
		// We also (re)set all attributes again & emit respawn sound
		RequestFrame(RespawnPlayerCallback, iClient);
	}
}

void RespawnPlayerCallback(any iData)
{
	TF2_RespawnPlayer(iData);

	EmitSoundToAll(SOUND_NER_RESPAWNED); // Notify everyone that respawning happened
	SetAttributes(); // Otherwise player collisions are not disabled (weapon attributes should remain the same if loadout wasn't changed)
}

public void OnRoundEnd(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	if (g_hManageRocketsTimer != null)
	{
		KillTimer(g_hManageRocketsTimer);
		g_hManageRocketsTimer = null;
	}

	if (g_hHudTimer != null)
	{
		KillTimer(g_hHudTimer);
		g_hHudTimer = null;
	}

	// Set every player back to their original team
	if (g_bFFAenabled)
	{
		for (int iClient = 1; iClient <= MaxClients; iClient++)
		{
			if (!IsClientInGame(iClient))
			{
				g_iOldTeam[iClient] = 0;
				continue;
			}

			if (g_iOldTeam[iClient])
			{
				int iLifeState = GetEntProp(iClient, Prop_Send, "m_lifeState");

				// If player is (last) alive do not switch them
				if (!iLifeState) continue; 

				ChangeClientTeam(iClient, g_iOldTeam[iClient]);
				g_iOldTeam[iClient] = 0;
			}
		}
	}

	DestroyAllRockets();
	g_bRoundStarted = false;
}

// ---- Config --------------------------------------
bool ParseConfig(char[] strConfigFile = "general.cfg")
{
	// Relative location of config
	char strFileName[PLATFORM_MAX_PATH];
	FormatEx(strFileName, sizeof(strFileName), "configs/dodgeball/%s", strConfigFile);

	// Build complete path to config
	char strPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, strPath, sizeof(strPath), strFileName);
	if (!FileExists(strPath)) { LogMessage("Couldn't load Config: \"%s\"", strConfigFile); return false; }

	ConfigMap cfg = new ConfigMap(strFileName);

	char strBuffer[256];

	// Rocket damage
	cfg.Get("rocket.damage formula", strBuffer, sizeof(strBuffer));
	currentConfig.strDamageFormula = ShuntingYard(strBuffer); // We have to convert our formula's to reverse polish notation (RPN) to evaluate them

	// Rocket speed
	cfg.Get("rocket.speed formula", strBuffer, sizeof(strBuffer));
	currentConfig.strSpeedFormula = ShuntingYard(strBuffer);
	cfg.GetFloat("rocket.minimum speed", currentConfig.fSpeedMin);
	cfg.GetFloat("rocket.maximum speed", currentConfig.fSpeedMax);

	// Thresholds
	cfg.GetInt("rocket.threshold a", currentConfig.iThresholdA);
	cfg.GetInt("rocket.threshold b", currentConfig.iThresholdB);

	// Rocket turnrate
	cfg.Get("rocket.turnrate formula", strBuffer, sizeof(strBuffer));
	currentConfig.strTurnrateFormula = ShuntingYard(strBuffer);
	cfg.GetFloat("rocket.minimum turnrate", currentConfig.fTurnrateMin);
	cfg.GetFloat("rocket.maximum turnrate", currentConfig.fTurnrateMax);

	// Orbitting
	cfg.GetFloat("rocket.orbit factor", currentConfig.fOrbitFactor);

	// Curving
	cfg.Get("rocket.curving formula", strBuffer, sizeof(strBuffer));
	currentConfig.strCurveFormula = ShuntingYard(strBuffer);
	cfg.GetFloat("rocket.minimum curving", currentConfig.fCurveMin);
	cfg.GetFloat("rocket.maximum curving", currentConfig.fCurveMax);

	// Rocket spawning
	cfg.GetInt("gameplay.max rockets", currentConfig.iMaxRockets);
	cfg.GetFloat("gameplay.rocket spawn interval", currentConfig.fSpawnInterval);

	// Rocket dragging
	cfg.GetFloat("rocket.drag time max", currentConfig.fDragTimeMax);
	cfg.GetFloat("rocket.turning delay", currentConfig.fTurningDelay);

	// Rocket bouncing
	cfg.GetBool("rocket.down spiking", currentConfig.bDownspikes);	// There was a bug in .GetBool in cfgmap.inc; Changed line 656: sizeof(strval)-1 -> sizeof(strval)
	cfg.GetFloat("rocket.bounce time", currentConfig.fBounceTime);
	cfg.GetInt("rocket.max bounces", currentConfig.iMaxBounces);

	// Wave
	cfg.GetInt("rocket.wave type", currentConfig.iWavetype);
	cfg.GetFloat("rocket.wave amplitude", currentConfig.fWaveAmplitude);
	cfg.GetFloat("rocket.wave oscillations", currentConfig.fWaveOscillations);

	// General gameplay
	cfg.GetBool("gameplay.airblast push prevention", currentConfig.bPushPrevention);
	cfg.GetFloat("gameplay.airblast push scale", currentConfig.fPushScale); // Does nothing if bPushPrevention enabled

	cfg.GetBool("gameplay.disable player collisions", currentConfig.bDisablePlayerCollisions);
	cfg.GetBool("gameplay.airblastable team rockets", currentConfig.bAirblastTeamRockets);
	cfg.GetBool("gameplay.rocket speedometer", currentConfig.bSpeedometer);
	cfg.GetFloat("gameplay.delay time", currentConfig.fDelayTime);

	cfg.GetFloat("gameplay.airblast delay", currentConfig.fAirblastDelay);
	currentConfig.fAirblastDelay /= 0.75 ; // 0.75 is normal airblast delay, the attribute is a multiplier, so we convert to multiplier

	// Stealing
	cfg.GetInt("gameplay.max steals", currentConfig.iMaxSteals);
	cfg.GetBool("gameplay.stolen rockets do damage", currentConfig.bStolenRocketsDoDamage);
	
	// FFA (Free for all)
	cfg.GetBool("gameplay.free for all", currentConfig.bFFAallowed);
	cfg.GetFloat("gameplay.ffa voting timeout", currentConfig.fFFAvotingTimeout);

	// NER (Never ending rounds)
	cfg.GetBool("gameplay.never ending rounds", currentConfig.bNeverEndingRoundsAllowed);
	cfg.GetFloat("gameplay.ner voting timeout", currentConfig.fNERvotingTimeout);
	
	delete cfg;

	Forward_OnRocketsConfigExecuted(strConfigFile, currentConfig);

	return true;
}

// "sm_loadconfig <config_name>"
public Action CmdLoadConfig(int iClient, int iArgs)
{
	if (!IsDodgeBallMap())
	{
		CReplyToCommand(iClient, "%t", "Command_DodgeballDisabled");		
		return Plugin_Handled;
	}
	
	// Loading default config
	if (!iArgs)
	{
		CReplyToCommand(iClient, "%t", "Dodgeball_Config_Loading_Default");
		LogMessage("%N: loading default config", iClient);
		ParseConfig();
	}
	// Loading supplied config
	else
	{
		char strConfigFile[64];
		GetCmdArgString(strConfigFile, sizeof(strConfigFile));

		LogMessage("%N: loading config \"%s\"", iClient, strConfigFile);

		if (strConfigFile[0] == '.' || strConfigFile[0] == '\'' || strConfigFile[0] == '\\' || strConfigFile[0] == '/') // Stop some ..\ or "C:\.." exploration attempts
			return Plugin_Handled;
		
		if (ParseConfig(strConfigFile))
		{
			CReplyToCommand(iClient, "%t", "Dodgeball_Config_Loading_New_Config", strConfigFile);
		}
		else
		{
			CReplyToCommand(iClient, "%t", "Dodgeball_Config_Not_Found");
			return Plugin_Handled;
		}
	}
	
	CPrintToChatAll("%t", "Dodgeball_New_Config_Announce_All");
	DestroyAllRockets();
	SetAttributes();

	if (!currentConfig.bFFAallowed && g_bFFAenabled)
		ToggleFFA();
	if (!currentConfig.bNeverEndingRoundsAllowed && g_bNERenabled)
		ToggleNER();

	return Plugin_Handled;
}

// ---- Formula stuff -------------------------------

// Evaluates a formula given a deflection count (Formula has to be in RPN (reverse polish) notation!)
float EvaluateFormula(char[] strFormula, int iDeflectionCount, float fSpeed)
{
	// 64 max strings, each with max length of 8 chars
	char strExploded[128][16];
	int iLength = ExplodeString(strFormula, " ", strExploded, sizeof(strExploded), sizeof(strExploded[]));

	float EvalBuffer[128];
	int i = 0; // Index in EvalBuffer

	for (int n = 0; n < iLength; n++)
	{
		if (StringToFloat(strExploded[n]))
		{
			EvalBuffer[i++] = StringToFloat(strExploded[n]);
		}
		else if (StringToInt(strExploded[n]))
		{
			EvalBuffer[i++] = float(StringToInt(strExploded[n]));
		}
		else if (StrContains(strExploded[n], "x", false) != -1) // x = deflection count
		{
			if (StrContains(strExploded[n], "-", false) != -1) // We do this check for if there is "*-x", "2-x" is not handled by this
				EvalBuffer[i++] = -float(iDeflectionCount);
			else
				EvalBuffer[i++] = float(iDeflectionCount);
		}
		else if (StrContains(strExploded[n], "s", false) != -1) // s = rocket speed
		{
			if (StrContains(strExploded[n], "-", false) != -1)
				EvalBuffer[i++] = -fSpeed;
			else
				EvalBuffer[i++] = fSpeed;
		}
		else if (StrContains(strExploded[n], "a", false) != -1) // a = deflection threshold a
		{
			if (StrContains(strExploded[n], "-", false) != -1)
				EvalBuffer[i++] = iDeflectionCount >= currentConfig.iThresholdA ? -1.0 : 0.0;
			else
				EvalBuffer[i++] = iDeflectionCount >= currentConfig.iThresholdA ? 1.0 : 0.0;
		}
		else if (StrContains(strExploded[n], "b", false) != -1) // b = deflection threshold b
		{
			if (StrContains(strExploded[n], "-", false) != -1)
				EvalBuffer[i++] = iDeflectionCount >= currentConfig.iThresholdB ? -1.0 : 0.0;
			else
				EvalBuffer[i++] = iDeflectionCount >= currentConfig.iThresholdB ? 1.0 : 0.0;
		}
		else if (StrContains(strExploded[n], "o", false) != -1) // o = 0.0, we can't use 0.0 as StringToFloat returns 0.0 on error, so not recognized
		{
			EvalBuffer[i++] = 0.0;
		}
		else // Is operator, do operation
		{
			i -= 2; // [4, 2, 8], i is currently 3, we need it to be 1, as the operation is on the last 2 items
			EvalBuffer[i] = DoOperation(EvalBuffer[i], EvalBuffer[i+1], view_as<int>(strExploded[n][0])); // doesn't matter that EvalBuffer[i+1] is something we set earlier
			i++; // We point to next value in array again
		}
	}

	return EvalBuffer[0]; // 0th index contains answer
}

float DoOperation(float a, float b, int iOperator)
{
	switch(iOperator)
	{
		case 43:
			return a + b;
		case 45:
			return a - b;
		case 42:
			return a * b;
		case 47:
			return a / b;
		case 94:
			return Pow(a, b);
		default:
		{
			SetFailState("Unknown operator in formula: %c", view_as<char>(iOperator));
			return 0.0; // Otherwise compiler complains
		}	
	}
}

// Shunting-yard algorithm to write an input formula to reverse polish notation
char[] ShuntingYard(char[] strFormula)
{
	char buffer; 	// Read token from input formula
	char popBuffer; // Temp buffer to store popped value

	ArrayStack operatorStack = new ArrayStack(sizeof(buffer));	// Temp stack for our operators
	ArrayStack outputStack = new ArrayStack(sizeof(buffer));	// output stack for our formula in RPN form

	int iPrecendence;		// Precedence for evaluation mathematical expression of an operator
	int iStackPrecedence;	// Precedence of top of stack

	bool bLastWasDigit = false;
	
	for (int n = 0; n < strlen(strFormula); n++)
	{
		buffer = strFormula[n];
		iPrecendence = OperatorPrecendence(view_as<int>(buffer));

		if (!iPrecendence || (iPrecendence == 2 && !bLastWasDigit)) // if precedence == 2 it could be a sign if last wasn't a digit
		{
			outputStack.Push(buffer); // Digits always gets pushed to output stack
			bLastWasDigit = true;
		}
		else
		{
			bLastWasDigit = false;

			// Read char is an operator, always push operator if stack is empty
			if (operatorStack.Empty)
			{
				operatorStack.Push(buffer);

				if (!outputStack.Empty)
				{
					// Seperator when digits are not connected, we skip the adding of ' ' at the end, operatorstack can become empty (again) if we begin with (5+3)*2
					popBuffer = outputStack.Pop();
					outputStack.Push(popBuffer);

					if (view_as<int>(popBuffer) != 32) // char(32) -> ' '
						outputStack.Push(' ');
				}

				continue;
			}

			// We need precedence of operator on top of stack
			popBuffer = operatorStack.Pop();
			iStackPrecedence = OperatorPrecendence(view_as<int>(popBuffer));
			operatorStack.Push(popBuffer);

			if (iPrecendence == -1) // Found a )
			{
				while (view_as<int>(buffer) != 40) // Pop onto output until (
				{
					buffer = operatorStack.Pop();

					if (view_as<int>(buffer) != 40) // Do not write ( back onto output stack
					{
						outputStack.Push(' ');
						outputStack.Push(buffer);
					}
				}
				bLastWasDigit = true; // We do not have a signed digit after ...)-3 only cases like ...*-3
			}
			else if (iPrecendence <= iStackPrecedence && iPrecendence != 1) // 1 = (
			{
				// Pop onto array if we are pushing lower or same precendence onto stack
				outputStack.Push(' ');
				outputStack.Push(operatorStack.Pop());

				operatorStack.Push(buffer);
			}
			else // No special cases, so just push onto operatorStack
			{
				operatorStack.Push(buffer);
			}	
		}

		if (outputStack.Empty)
			continue;

		// Add seperator ' ' for exploding string later
		popBuffer = outputStack.Pop();
		outputStack.Push(popBuffer);

		if (!bLastWasDigit && view_as<int>(popBuffer) != 32)
			outputStack.Push(' ');
	}

	// Push remaining operators at the end
	while (!operatorStack.Empty)
	{
		outputStack.Push(' ');
		outputStack.Push(operatorStack.Pop());
	}

	// Creating string in reverse polish notation
	operatorStack.Clear(); // We will temporarily use this stack to reverse order of output stack since stacks are FIFO, so if we read directly it will be in polish notation

	char strParsedFormula[256];
	char readBuf[2]; // We can't just StrCat a char, has to be char[] for StrCat, null terminator so size 2

	// Reversing stack
	while (!outputStack.Empty)
		operatorStack.Push(outputStack.Pop());

	// Reading string from stack
	while (!operatorStack.Empty)
	{
		operatorStack.PopString(readBuf, sizeof(readBuf));
		StrCat(strParsedFormula, sizeof(strParsedFormula), readBuf);
	}

	// Cleanup
	delete operatorStack;
	delete outputStack;

	return strParsedFormula;
}

int OperatorPrecendence(int iToken)
{
	switch (iToken)
	{
		case 40: 		// (
			return 1;
		case 41:		// )
			return -1;
		case 43, 45:	// + or -
			return 2;
		case 42, 47:	// * or /
			return 3;
		case 94:		// ^
			return 4;
		default:
			return 0;	// Not operator
	}
}

// ---- FFA voting/enabling -------------------------

// "sm_ffa"
public Action CmdToggleFFA(int iClient, int iArgs)
{
	if (!g_bEnabled)
	{
		CReplyToCommand(iClient, "%t", "Command_DodgeballDisabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bFFAallowed)
	{
		CReplyToCommand(iClient, "%t", "Command_DisabledByConfig");

		return Plugin_Handled;
	}

	ToggleFFA();

	return Plugin_Handled;
}

// "sm_voteffa"
public Action CmdVoteFFA(int iClient, int iArgs)
{

	if (!g_bEnabled)
	{
		CReplyToCommand(iClient, "%t", "Command_DodgeballDisabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bFFAallowed)
	{
		CReplyToCommand(iClient, "%t", "Command_DisabledByConfig");

		return Plugin_Handled;
	}

	if (!g_fFFAvoteTime && g_fFFAvoteTime + currentConfig.fFFAvotingTimeout > GetGameTime())
	{
		CReplyToCommand(iClient, "%t", "Dodgeball_FFAVote_Cooldown", g_fFFAvoteTime + currentConfig.fFFAvotingTimeout - GetGameTime());

		return Plugin_Handled;
	}

	if (IsVoteInProgress())
	{
		CReplyToCommand(iClient, "%t", "Dodgeball_Vote_Conflict");
		
		return Plugin_Handled;
	}

	char strMode[16];
	strMode = g_bFFAenabled ? "Disable" : "Enable";
	g_iVoteTypeInProgress = 1;
	
	Menu hMenu = new Menu(VoteMenuHandler);
	hMenu.VoteResultCallback = VoteResultHandler;
	
	hMenu.SetTitle("%s FFA mode?", strMode);
	
	hMenu.AddItem("0", "Yes");
	hMenu.AddItem("1", "No");
	
	int iTotal;
	int[] iClients = new int[MaxClients];
	
	for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer++)
	{
		if (!IsClientInGame(iPlayer) || IsFakeClient(iPlayer))
			continue;

		iClients[iTotal++] = iPlayer;
	}
	
	hMenu.DisplayVote(iClients, iTotal, 10);

	g_fFFAvoteTime = GetGameTime();
	return Plugin_Handled;
}

void ToggleFFA()
{
	DestroyAllRockets();

	if (!g_bFFAenabled)
	{
		CPrintToChatAll("%t", "Dodgeball_FFAVote_Enabled");
		SetConVarInt(FindConVar("mp_friendlyfire"), 1);

		g_bFFAenabled = true;
		return;
	}

	CPrintToChatAll("%t", "Dodgeball_FFAVote_Disabled");
	SetConVarInt(FindConVar("mp_friendlyfire"), 0);

	g_bFFAenabled = false;
}

// ---- NER voting/enabling -------------------------

// "sm_ner"
public Action CmdToggleNER(int iClient, int iArgs)
{
	if (!g_bEnabled)
	{
		CReplyToCommand(iClient, "%t", "Command_DodgeballDisabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bNeverEndingRoundsAllowed)
	{
		CReplyToCommand(iClient, "%t", "Command_DisabledByConfig");

		return Plugin_Handled;
	}

	ToggleNER();

	return Plugin_Handled;
}

// "sm_votener"
public Action CmdVoteNER(int iClient, int iArgs)
{

	if (!g_bEnabled)
	{
		CReplyToCommand(iClient, "%t", "Command_DodgeballDisabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bNeverEndingRoundsAllowed)
	{
		CReplyToCommand(iClient, "%t", "Command_DisabledByConfig");

		return Plugin_Handled;
	}

	if (!g_fNERvoteTime && g_fNERvoteTime + currentConfig.fNERvotingTimeout > GetGameTime())
	{
		CReplyToCommand(iClient, "%t", "Dodgeball_NERVote_Cooldown", g_fNERvoteTime + currentConfig.fNERvotingTimeout - GetGameTime());

		return Plugin_Handled;
	}

	if (IsVoteInProgress())
	{
		CReplyToCommand(iClient, "%t", "Dodgeball_Vote_Conflict");
		
		return Plugin_Handled;
	}

	char strMode[16];
	strMode = g_bNERenabled ? "Disable" : "Enable";
	g_iVoteTypeInProgress = 2;
	
	Menu hMenu = new Menu(VoteMenuHandler);
	hMenu.VoteResultCallback = VoteResultHandler;
	
	hMenu.SetTitle("%s NER mode?", strMode);
	
	hMenu.AddItem("0", "Yes");
	hMenu.AddItem("1", "No");
	
	int iTotal;
	int[] iClients = new int[MaxClients];
	
	for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer++)
	{
		if (!IsClientInGame(iPlayer) || IsFakeClient(iPlayer))
			continue;

		iClients[iTotal++] = iPlayer;
	}
	
	hMenu.DisplayVote(iClients, iTotal, 10);

	g_fNERvoteTime = GetGameTime();
	return Plugin_Handled;
}

void ToggleNER()
{
	DestroyAllRockets();

	if (!g_bNERenabled)
	{
		CPrintToChatAll("%t", "Dodgeball_NERVote_Enabled");

		g_bNERenabled = true;
		return;
	}

	CPrintToChatAll("%t", "Dodgeball_NERVote_Disabled");
	g_bNERenabled = false;
}

// ---- Voting handler ------------------------------
public int VoteMenuHandler(Menu hMenu, MenuAction iMenuActions, int iParam1, int iParam2)
{
	if (iMenuActions == MenuAction_End)
		delete hMenu;
	
	return 0;
}

public void VoteResultHandler(Menu hMenu, int iNumVotes, int iNumClients, const int[][] iClientInfo, int iNumItems, const int[][] iItemInfo)
{
	int iWinnerIndex = 0;
	
	// Equal votes so we choose a random winner (with 1 vote for enabling)
	if (iNumItems > 1 && (iItemInfo[0][VOTEINFO_ITEM_VOTES] == iItemInfo[1][VOTEINFO_ITEM_VOTES]))
		iWinnerIndex = GetRandomInt(0, 1);
	
	char strWinner[8];
	hMenu.GetItem(iItemInfo[iWinnerIndex][VOTEINFO_ITEM_INDEX], strWinner, sizeof(strWinner));
	
	// We use the same result handler, so we need to check what to enable
	if (StrEqual(strWinner, "0"))
	{
		switch (g_iVoteTypeInProgress)
		{
			case (1):
				ToggleFFA();
			case (2):
				ToggleNER();
		}
	}
	else
	{
		switch (g_iVoteTypeInProgress)
		{
			case (1):
				CPrintToChatAll("%t", "Dodgeball_FFAVote_Failed");
			case (2):
				CPrintToChatAll("%t", "Dodgeball_NERVote_Failed");
		}
	}
}

void RemoveInvalidRockets()
{
	Rocket rocket;
	for (int n = 0; n < g_rockets.Length; n++)
	{
		g_rockets.GetArray(n, rocket);

		if (!IsValidRocket(rocket.iRef)) // Rocket has exploded
		{
			g_rockets.Erase(n--); // g_rockets.Length changes
		}
		else if (!IsValidClient(rocket.iOwner) || !IsValidClient(rocket.iTarget)) // Target / owner became invalid (left game or died)
		{
			RemoveEdict(rocket.iEntity);
			g_rockets.Erase(n--);
		}
	}
}

// ---- TFDB utils ----------------------------------
void DestroyAllRockets()
{
	for (int n = 0; n < g_rockets.Length; n++)
	{
		if (IsValidRocket(g_rockets.Get(n, 1))) // rocket.iRef = [1]
			RemoveEdict(g_rockets.Get(n, 0)); 	// rocket.iEntity = [0]
	}
	g_rockets.Clear();
}

int FindRocketIndexByEntity(int iEntity)
{
	for (int n = 0; n < g_rockets.Length; n++)
	{
		if (iEntity == g_rockets.Get(n, 0))
			return n;			
	}
	return -1;
}

bool IsValidRocket(int iRef)
{
	return EntRefToEntIndex(iRef) != INVALID_ENT_REFERENCE ? true : false;
}

bool IsDodgeBallMap()
{
    char strMap[64]; GetCurrentMap(strMap, sizeof(strMap));
    return StrContains(strMap, "tfdb_", false) != -1;
}

bool IsValidClient(int iClient)
{
	if (iClient > 0)
		return IsClientInGame(iClient) && IsPlayerAlive(iClient);
	return false;
}

// ---- General utils -------------------------------
float Clamp(float fVal, float fMin, float fMax)
{
	if (fMax) 
		return fVal < fMin ? fMin : fVal > fMax ? fMax : fVal;
	return fVal > fMin ? fVal : fMin;
}

void CopyVec3(float fTo[3], float fFrom[3])
{
	fTo[0] = fFrom[0];
	fTo[1] = fFrom[1];
	fTo[2] = fFrom[2];
}

bool BothTeamsPlaying()
{
	return GetTeamAliveCount(view_as<int>(TFTeam_Blue)) > 0 && GetTeamAliveCount(view_as<int>(TFTeam_Red)) > 0;
}

int GetTeamAliveCount(int iTeam)
{
	int iCount;
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (IsValidClient(iClient) && (GetClientTeam(iClient) == iTeam))
			iCount++;
	}

	return iCount;
}

int GetTeamRandomAliveClient(int iTeam)
{
	int[] iClients = new int[MaxClients];
	int iCount;
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientInGame(iClient)) continue;
		
		if ((GetClientTeam(iClient) == iTeam) && IsPlayerAlive(iClient))
			iClients[iCount++] = iClient;
	}
	
	return iCount == 0 ? -1 : iClients[GetRandomInt(0, iCount - 1)];
}

// ---- Soundbug fix --------------------------------

// https://gitlab.com/nanochip/fixfireloop/-/blob/master/scripting/fixfireloop.sp
// The most significant change is Plugin_Continue instead of Plugin_Stop

public Action OnTFExplosion(const char[] strTEName, const int[] iClients, int iNumClients, float fDelay)
{
	static int bIgnoreHook;
	
	if (!g_bEnabled)
	{
		return Plugin_Continue;
	}
	
	if (bIgnoreHook)
	{
		bIgnoreHook = false;
		
		return Plugin_Continue;
	}
	
	TE_Start("TFExplosion");
	
	static float vecNormal[3]; TE_ReadVector("m_vecNormal", vecNormal);
	
	TE_WriteFloat("m_vecOrigin[0]", TE_ReadFloat("m_vecOrigin[0]"));
	TE_WriteFloat("m_vecOrigin[1]", TE_ReadFloat("m_vecOrigin[1]"));
	TE_WriteFloat("m_vecOrigin[2]", TE_ReadFloat("m_vecOrigin[2]"));
	
	TE_WriteVector("m_vecNormal", vecNormal);
	
	TE_WriteNum("m_iWeaponID", TE_ReadNum("m_iWeaponID"));
	TE_WriteNum("entindex", TE_ReadNum("entindex"));
	TE_WriteNum("m_nDefID", -1);
	TE_WriteNum("m_nSound", TE_ReadNum("m_nSound"));
	TE_WriteNum("m_iCustomParticleIndex", TE_ReadNum("m_iCustomParticleIndex"));
	
	bIgnoreHook = true;
	TE_Send(iClients, iNumClients, fDelay);

	return Plugin_Stop;
}

// ---- Interfacing ---------------------------------

// Forwards
void Forward_OnRocketCreated(int iIndex, Rocket rocket)
{
	Call_StartForward(g_ForwardOnRocketCreated);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_Finish();
}

void Forward_OnRocketDeflect(int iIndex, Rocket rocket)
{
	Call_StartForward(g_ForwardOnRocketDeflect);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_Finish();
}

void Forward_OnRocketSteal(int iIndex, Rocket rocket, int iStealCount)
{
	Call_StartForward(g_ForwardOnRocketSteal);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_PushCell(iStealCount);
	Call_Finish();
}

void Forward_OnRocketDelay(int iIndex, Rocket rocket)
{
	Call_StartForward(g_ForwardOnRocketDelay);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_Finish();
}

void Forward_OnRocketNewTarget(int iIndex, Rocket rocket)
{
	Call_StartForward(g_ForwardOnRocketNewTarget);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_Finish();
}

void Forward_OnRocketHitPlayer(int iIndex, Rocket rocket)
{
	Call_StartForward(g_ForwardOnRocketHitPlayer);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_Finish();
}

void Forward_OnRocketBounce(int iIndex, Rocket rocket)
{
	Call_StartForward(g_ForwardOnRocketBounce);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_Finish();
}

void Forward_OnRocketsConfigExecuted(const char[] strConfigFile, TFDBConfig config)
{
	Call_StartForward(g_ForwardOnRocketsConfigExecuted);
	Call_PushString(strConfigFile);
	Call_PushArrayEx(config, sizeof(config), SM_PARAM_COPYBACK);
	Call_Finish();
}

void Forward_OnRocketOtherWavetype(int iIndex, Rocket rocket, int iWavetype, float fPhase, float fWaveAmplitude)
{
	Call_StartForward(g_ForwardOnRocketOtherWavetype);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_PushCell(iWavetype);
	Call_PushFloat(fPhase);
	Call_PushFloat(fWaveAmplitude);
	Call_Finish();
}

void Forward_OnRocketGameFrame(int iIndex, Rocket rocket)
{
	Call_StartForward(g_ForwardOnRocketGameFrame);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_Finish();
}

// Natives
public any Native_IsDodgeballEnabled(Handle hPlugin, int iNumParams)
{
	return g_bEnabled;
}

public any Native_CreateRocket(Handle hPlugin, int iNumParams)
{
	int iTeam = GetNativeCell(1);
	
	CreateRocket(iTeam == view_as<int>(TFTeam_Blue) ? g_iBlueSpawnerEntity : g_iRedSpawnerEntity, iTeam);

	return 0;
}


public any Native_IsValidRocket(Handle hPlugin, int iNumParams)
{
	int iRef = GetNativeCell(1);

	return IsValidRocket(iRef);
}

public any Native_FindRocketByEntity(Handle hPlugin, int iNumParams)
{
	int iEntity = GetNativeCell(1);

	return FindRocketIndexByEntity(iEntity);
}

public any Native_GetRocketByIndex(Handle hPlugin, int iNumParams)
{
	int iIndex = GetNativeCell(1);

	if (iIndex > g_rockets.Length)
		return SP_ERROR_ARRAY_BOUNDS;

	Rocket rocket;
	g_rockets.GetArray(iIndex, rocket);

	return SetNativeArray(2, rocket, sizeof(rocket));
}

public any Native_SetRocketByIndex(Handle hPlugin, int iNumParams)
{
	int iIndex = GetNativeCell(1);

	if (iIndex > g_rockets.Length)
		return SP_ERROR_ARRAY_BOUNDS;

	Rocket rocket;
	GetNativeArray(2, rocket, sizeof(rocket));

	g_rockets.SetArray(iIndex, rocket);

	return SP_ERROR_NONE;
}

public any Native_IsRocketTarget(Handle hPlugin, int iNumParams)
{
	int iClient = GetNativeCell(1);

	if (!IsValidClient(iClient))
		return false;
	
	Rocket rocket;

	for (int n = 0; n < g_rockets.Length; n++)
	{
		g_rockets.GetArray(n, rocket);
		
		if (rocket.iTarget == iClient)
			return true;
	}

	return false;
}

public any Native_GetCurrentConfig(Handle hPlugin, int iNumParams)
{
	return SetNativeArray(1, currentConfig, sizeof(TFDBConfig));
}

public any Native_SetCurrentConfig(Handle hPlugin, int iNumParams)
{
	return GetNativeArray(1, currentConfig, sizeof(TFDBConfig));
}

public any Native_IsFFAenabled(Handle hPlugin, int iNumParams)
{
	return g_bFFAenabled;
}

public any Native_ToggleFFA(Handle hPlugin, int iNumParams)
{
	ToggleFFA();

	return 0;
}

public any Native_IsNERenabled(Handle hPlugin, int iNumParams)
{
	return g_bNERenabled;
}

public any Native_ToggleNER(Handle hPlugin, int iNumParams)
{
	ToggleNER();

	return 0;
}
