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
#define PLUGIN_VERSION     "1.6.3"
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

int g_iBot; // Keeping track of dodgeball bot (for NER)

int g_iOldTeam[MAXPLAYERS + 1];

Address g_pMyWearables; // Fix for wearables' colours not changing

// NER Horn volume level when players are respawned
ConVar g_Cvar_HornVolumeLevel;

// Speedometer hud
char g_hHudText[225]; // 225 is character limit for hud text
bool g_bCurving; // Longer text length so it is uncentered
Handle g_hHudTimer;
Handle g_hMainHudSync;

// Stealing
int g_iSteals [MAXPLAYERS + 1];

// Array of rocket structs & config struct
ArrayList g_rockets;
TFDBConfig currentConfig;

// Solo stuff
ArrayStack g_soloQueue;
bool g_bSoloEnabled[MAXPLAYERS + 1];

// ---- Debugging -----------------------------------
ConVar g_Cvar_SeeBotsAsPlayers; // For testing NER with bots

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
	g_Cvar_HornVolumeLevel = CreateConVar("NER_volume_level", "0.75", "Volume level of the horn played when respawning players.", _, true, 0.0, true, 1.0);
	g_Cvar_SeeBotsAsPlayers = CreateConVar("NER_BotDebug", "0", "Makes it so that NER plugin ignores bots & view them as players.", _, true, 0.0, true, 1.0);

	// Solo toggle
	RegConsoleCmd("sm_solo", CmdSolo, "Toggle solo mode");

	// Fixes soundbug (looping flamethrower sound) https://gitlab.com/nanochip/fixfireloop/-/blob/master/scripting/fixfireloop.sp
	AddTempEntHook("TFExplosion", OnTFExplosion);

	g_pMyWearables = view_as<Address>(FindSendPropInfo("CTFPlayer", "m_hMyWearables"));
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
	CreateNative("TFDB_NumRocketsTargetting", Native_NumRocketsTargetting);
	CreateNative("TFDB_GetCurrentConfig", Native_GetCurrentConfig);
	CreateNative("TFDB_SetCurrentConfig", Native_SetCurrentConfig);
	CreateNative("TFDB_IsFFAenabled", Native_IsFFAenabled);
	CreateNative("TFDB_ToggleFFA", Native_ToggleFFA);
	CreateNative("TFDB_IsNERenabled", Native_IsNERenabled);
	CreateNative("TFDB_ToggleNER", Native_ToggleNER);
	CreateNative("TFDB_HasRoundStarted", Native_HasRoundStarted);

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
	g_ForwardOnRocketHitPlayer = CreateGlobalForward("TFDB_OnRocketHitPlayer", ET_Ignore, Param_Cell, Param_Array, Param_Cell);
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
	g_soloQueue = new ArrayStack(sizeof(g_iRedSpawnerEntity)); // sizeof(int)

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

	// Remove airblast cost & arena queue
	SetConVarFloat(FindConVar("tf_flamethrower_burstammo"), 0.0); // default 25.0
	SetConVarBool(FindConVar("tf_arena_use_queue"), false); // default true

	// Parsing rocket configs
	ParseConfig();

	g_bEnabled = true;
}

void DisableDodgeball()
{
	if (!g_bEnabled) return;

	DestroyAllRockets();
	delete g_rockets;

	g_soloQueue.Clear();
	delete g_soloQueue;

	// Unhooking all events
	UnhookEvent("arena_round_start", OnSetupFinished, EventHookMode_PostNoCopy);
	UnhookEvent("teamplay_round_win", OnRoundEnd, EventHookMode_PostNoCopy);
	UnhookEvent("teamplay_round_stalemate", OnRoundEnd, EventHookMode_PostNoCopy);
	UnhookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Post);
	UnhookEvent("player_death", OnPlayerDeath, EventHookMode_Pre);
	UnhookEvent("post_inventory_application", OnPlayerInventory, EventHookMode_Post);
	UnhookEvent("object_deflected", OnObjectDeflected);

	// Resetting to default
	SetConVarFloat(FindConVar("tf_flamethrower_burstammo"), 25.0);
	SetConVarBool(FindConVar("tf_arena_use_queue"), true);
	SetConVarFloat(FindConVar("sv_maxvelocity"), 3500.0);

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
	float currentTime = GetGameTime();

	// Go over each rocket in ArrayList
	for (int n = 0; n < g_rockets.Length; n++)
	{
		g_rockets.GetArray(n, rocket);

		// We will clear invalid rockets in our ManageRockets timer
		if (!IsValidRocket(rocket.iRef)) continue;

		// If we had set fTimeLastDeflect in OnObjectDeflected it would be out of sync with OnGameFrame, resulting in deflection delays
		if (rocket.bRecentlyReflected)
		{
			rocket.fTimeLastDeflect = currentTime; 
			rocket.bRecentlyReflected = false;
		}

		// For creating crawling downspikes
		if (rocket.bRecentlyBounced)
		{
			rocket.fTimeLastBounce = currentTime;
			rocket.bRecentlyBounced = false;
		}
		
		float fTimeSinceLastDeflect = currentTime - rocket.fTimeLastDeflect;
		float fTimeSinceLastBounce = currentTime - rocket.fTimeLastBounce;

		// The extra factor is to vary the spiking length, we should probably give control over this in config
		float fTimeSinceLastTurn = (currentTime - rocket.fTimeLastTurn) + (GetRandomFloat(-currentConfig.fSpikingTime*0.25, currentConfig.fSpikingTime*0.25));

		static float fRocketPosition[3]; GetEntPropVector(rocket.iEntity, Prop_Data, "m_vecOrigin", fRocketPosition);

		// Select new target if outside of dragging
		if (!rocket.bHasTarget && fTimeSinceLastDeflect >= currentConfig.fDragTimeMax)
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

		// Dragging
		if (fTimeSinceLastDeflect <= currentConfig.fDragTimeMax)
		{
			static float fViewAngles[3];
			GetClientEyeAngles(rocket.iOwner, fViewAngles);
			GetAngleVectors(fViewAngles, rocket.fDirection, NULL_VECTOR, NULL_VECTOR);
		}
		// Turn to target if not dragging & outside of delay till turning
		else if (rocket.bHasTarget && fTimeSinceLastDeflect >= currentConfig.fTurningDelay + currentConfig.fDragTimeMax)
		{
			static float fDirectionToTarget[3], fPlayerPosition[3];

			GetClientEyePosition(rocket.iTarget, fPlayerPosition);

			MakeVectorFromPoints(fRocketPosition, fPlayerPosition, fDirectionToTarget);
			NormalizeVector(fDirectionToTarget, fDirectionToTarget);

			// Spiking check
			if (!currentConfig.iSpikingDeflects
				|| currentConfig.iSpikingDeflects > rocket.iDeflectionCount
				|| rocket.RangeToTarget() < SPIKING_RANGE
				|| fTimeSinceLastTurn > currentConfig.fSpikingTime
				|| currentConfig.fSpikingMaxTime < fTimeSinceLastDeflect)
			{
				if (rocket.RangeToTarget() > ORBIT_RANGE || rocket.bBeingDelayed)
				{
					// Turning factor = normal rocket turning, or spiking behaviour -> we overturn when spiking
					float fTurningFactor = currentConfig.iSpikingDeflects && currentConfig.iSpikingDeflects <= rocket.iDeflectionCount && currentConfig.fSpikingMaxTime >= fTimeSinceLastDeflect && rocket.RangeToTarget() > SPIKING_RANGE ? currentConfig.fSpikingStrength : rocket.fTurnrate;

					// Smoothly change to direction to target using turnrate
					rocket.fDirection[0] += (fDirectionToTarget[0] - rocket.fDirection[0]) * fTurningFactor;
					rocket.fDirection[1] += (fDirectionToTarget[1] - rocket.fDirection[1]) * fTurningFactor;
					rocket.fDirection[2] += (fDirectionToTarget[2] - rocket.fDirection[2]) * fTurningFactor;
				}
				// We want to turn less whilst in orbit to make it easier
				else
				{
					rocket.fDirection[0] += (fDirectionToTarget[0] - rocket.fDirection[0]) * rocket.fTurnrate * currentConfig.fOrbitFactor;
					rocket.fDirection[1] += (fDirectionToTarget[1] - rocket.fDirection[1]) * rocket.fTurnrate * currentConfig.fOrbitFactor;
					rocket.fDirection[2] += (fDirectionToTarget[2] - rocket.fDirection[2]) * rocket.fTurnrate;
				}

				// We randomize spiking timing to vary length of spikes
				rocket.fTimeLastTurn = currentTime;
			}

			// In orbit increase delay timer
			if (rocket.RangeToTarget() < ORBIT_RANGE)
				rocket.fTimeInOrbit += GetTickInterval();

			// Wave stuff, we do not wave whilst within certain range
			if (currentConfig.iWavetype && rocket.iDeflectionCount && rocket.RangeToTarget() > WAVE_RANGE)
			{
				float fDistanceToPlayer = GetVectorDistance(fPlayerPosition, fRocketPosition);
				
				// See inf. square well -> (L-x) * nπ/L, x starts at max distance, so L-x = distance travelled to target (not exactly, should do -250 due to airblast range, but close enough)
				float fPhase = (rocket.fWaveDistance - fDistanceToPlayer) * rocket.fWaveOscillations * 3.14159 / rocket.fWaveDistance;

				switch (currentConfig.iWavetype)
				{
					case(1): // Vertical wave
					{
						// (Attempted) recreation of the 'classic' way of waving
						rocket.fDirection[2] += rocket.fWaveAmplitude * -Cosine(fPhase);
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
							rocket.fDirection[1] += rocket.fWaveAmplitude * Sine(fPhase);
						else
							rocket.fDirection[0] += rocket.fWaveAmplitude * Sine(fPhase);
					}
					case (3): // Circular wave
					{
						if (FloatAbs(rocket.fDirection[0]) > FloatAbs(rocket.fDirection[1]))
							rocket.fDirection[1] += rocket.fWaveAmplitude * Sine(fPhase);
						else
							rocket.fDirection[0] += rocket.fWaveAmplitude * Sine(fPhase);

						// Offset by -90 deg, gives circular polarization which first waves up (so that it doesn't immediately hit the ground)
						rocket.fDirection[2] += rocket.fWaveAmplitude * Sine(fPhase + DegToRad(-90.0));
					}
					default: // Subplugin wavetypes
					{
						Forward_OnRocketOtherWavetype(n, rocket, currentConfig.iWavetype, fPhase, rocket.fWaveAmplitude);
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

			// !!This is probably not needed anymore due to handling soft-antisteal differently!!
			// This is to prevent an instant crash that happens only if the spawn rocket was stolen, but the steal was ignored
			// This happens because m_hOriginalLauncher & m_hLauncher gets set by the stealer, but then we pass an m_hOwnerEntity of 0
			// When we pass m_hOwnerEntity = 0, but m_hOriginalLauncher & ... != -1 the server will instantly crash
			SetEntPropEnt(iEntity, Prop_Send, "m_hOriginalLauncher", -1);
			SetEntPropEnt(iEntity, Prop_Send, "m_hLauncher", -1);

			rocket.iOwner = 0;
		}
		
		if (rocket.bStolen && !currentConfig.bStolenRocketsDoDamage && rocket.bHasTarget)
		{
			SetEntDataFloat(rocket.iEntity, FindSendPropInfo("CTFProjectile_Rocket", "m_iDeflected") + 4, 0.0, true);
			rocket.fDamage = 0.0;
		}
		
		Forward_OnRocketHitPlayer(iIndex, rocket, iClient);

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
	if (!currentConfig.bDownspikes && rocket.RangeToTarget() < ORBIT_RANGE)
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

	rocket.fTurnrate = EvaluateFormula(currentConfig.strTurnrateFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fTurnrate = Clamp(rocket.fTurnrate, 0.0, currentConfig.fTurnrateLimit);

	rocket.fDamage = EvaluateFormula(currentConfig.strDamageFormula, rocket.iDeflectionCount, rocket.fSpeed) / 3; // Account for critical rocket damage being 3x

	static float fPosition[3]; GetEntPropVector(iSpawnerEntity, Prop_Send, "m_vecOrigin", fPosition);
	static float fAngles[3]; GetEntPropVector(iSpawnerEntity, Prop_Send, "m_angRotation", fAngles);

	TeleportEntity(rocket.iEntity, fPosition, fAngles);

	GetAngleVectors(fAngles, rocket.fDirection, NULL_VECTOR, NULL_VECTOR);

	SetEntProp(rocket.iEntity, Prop_Send, "m_iTeamNum", currentConfig.bAirblastTeamRockets ? rocket.iTeam + 32 : rocket.iTeam);
	SetEntProp(rocket.iEntity, Prop_Send, "m_bCritical", 1); // We just want critical rockets for visibility

	// We have to set rocket owner to a valid player, otherwise first object_deflected event is skipped
	// This does mean that the rocket can't hit the selected owner either
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

	Forward_OnRocketCreated(g_rockets.Length, rocket);

	Format(g_hHudText, sizeof(g_hHudText), "%t", "Dodgeball_Hud_Speedometer", rocket.fSpeed, rocket.SpeedMpH(), rocket.iDeflectionCount, rocket.fSpeed / currentConfig.fMaxVelocity);
	g_bCurving = false;

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

	int iNewOwner = GetClientOfUserId(hEvent.GetInt("userid"));
	int iWeapon;

	// Stealing check
	if (iNewOwner != rocket.iTarget &&
		currentConfig.iMaxSteals >= 0 &&
		rocket.bHasTarget &&
		GetClientTeam(iNewOwner) != rocket.iTeam &&
		!rocket.bBeingDelayed &&
		GetEntitiesDistance(rocket.iTarget, iNewOwner) > currentConfig.fWallingDistance)
	{		
		g_iSteals[iNewOwner]++;
		Forward_OnRocketSteal(iIndex, rocket, g_iSteals[iNewOwner]);

		// Soft anti-steal
		if (currentConfig.bSoftAntiSteal)
		{
			// Prevent further stealing
			if (g_iSteals[iNewOwner] >= currentConfig.iMaxSteals)
			{
				CPrintToChat(iNewOwner, "%t", "Dodgeball_Soft_Stealing_No_Steals");
				if (currentConfig.bAnnounceSteals)
					CPrintToChatAll("%t", "Dodgeball_No_Steals_Announce_All", iNewOwner);
				
				// Disabling the ability of reflecting rocket using attributes if not a target of (another) rocket
				if (!NumRocketsTargetting(iNewOwner))
				{
					iWeapon = GetEntPropEnt(iNewOwner, Prop_Data, "m_hActiveWeapon");
					TF2Attrib_SetByDefIndex(iWeapon, 826, 1.0); // Attrib 826 : airblast_deflect_projectiles_disabled
				}
			}
			// Warn stealer
			else
			{
				CPrintToChat(iNewOwner, "%t", "Dodgeball_Soft_Stealing_Warn", g_iSteals[iNewOwner], currentConfig.iMaxSteals);
				if (currentConfig.bAnnounceSteals)
					CPrintToChatAll("%t", "Dodgeball_Steal_Announce_All", iNewOwner, rocket.iTarget);
			}
		}
		// Hard anti-steal
		else
		{
			// Kill Stealer
			if (g_iSteals[iNewOwner] > currentConfig.iMaxSteals)
			{
				CPrintToChat(iNewOwner, "%t", "Dodgeball_Steal_Slay_Client");
				if (currentConfig.bAnnounceSteals)
					CPrintToChatAll("%t", "Dodgeball_Steal_Announce_Slay_All", iNewOwner); 

				ForcePlayerSuicide(iNewOwner);
			}
			// Warn stealer
			else
			{
				CPrintToChat(iNewOwner, "%t", "Dodgeball_Steal_Warning_Client", g_iSteals[iNewOwner], currentConfig.iMaxSteals);
				if (currentConfig.bAnnounceSteals)
					CPrintToChatAll("%t", "Dodgeball_Steal_Announce_All", iNewOwner, rocket.iTarget);
			}
		}
		rocket.bStolen = true;
	}
	else
	{
		rocket.bStolen = false;
	}

	// If rocket was stolen from a stealer we also need to disable again
	if (currentConfig.bSoftAntiSteal && g_iSteals[rocket.iTarget] >= currentConfig.iMaxSteals && NumRocketsTargetting(rocket.iTarget) == 1)
	{
		iWeapon = GetEntPropEnt(rocket.iTarget, Prop_Data, "m_hActiveWeapon");
		TF2Attrib_SetByDefIndex(iWeapon, 826, 1.0);
	}

	// Setting new rocket variables	
	rocket.iOwner = iNewOwner;
	rocket.iTeam = g_bFFAenabled ? 1 : GetClientTeam(rocket.iOwner);
	rocket.iDeflectionCount++;

	rocket.iBounces = 0; 
	rocket.fWaveDistance = 0.0;
	rocket.fTimeInOrbit = 0.0;

	rocket.fSpeed = EvaluateFormula(currentConfig.strSpeedFormula, rocket.iDeflectionCount, rocket.fSpeed);

	rocket.fTurnrate = EvaluateFormula(currentConfig.strTurnrateFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fTurnrate = Clamp(rocket.fTurnrate, 0.0, currentConfig.fTurnrateLimit);

	rocket.fWaveOscillations = EvaluateFormula(currentConfig.strWaveOscillationsFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fWaveOscillations = Clamp(rocket.fWaveOscillations, currentConfig.fWaveOscillationsMin, currentConfig.fWaveOscillationsMax);

	rocket.fWaveAmplitude = EvaluateFormula(currentConfig.strWaveAmplitudeFormula, rocket.iDeflectionCount, rocket.fSpeed);
	rocket.fWaveAmplitude = Clamp(rocket.fWaveAmplitude, currentConfig.fWaveAmplitudeMin, currentConfig.fWaveAmplitudeMax);

	rocket.fDamage = EvaluateFormula(currentConfig.strDamageFormula, rocket.iDeflectionCount, rocket.fSpeed) / 3;

	// m_iTeamNum is 6 bits, | 32 sets the highest bit (which apparently makes it so that you/teammates can hit your own projectiles)
	SetEntProp(rocket.iEntity, Prop_Send, "m_iTeamNum", currentConfig.bAirblastTeamRockets ? rocket.iTeam | 32 : rocket.iTeam);

	SetEntDataFloat(rocket.iEntity, FindSendPropInfo("CTFProjectile_Rocket", "m_iDeflected") + 4, rocket.fDamage, true);
	SetEntPropEnt(rocket.iEntity, Prop_Send, "m_hOwnerEntity", rocket.iOwner);

	rocket.bHasTarget = false;
	rocket.bRecentlyReflected = true; // We set our rocket.fTimeLastDeflect in sync with OnGameFrame for dragging

	Forward_OnRocketDeflect(iIndex, rocket);

	// Updating hud text, reflect 'curving' of the rocket aswell
	if (rocket.fSpeed > currentConfig.fMaxVelocity)
	{
		Format(g_hHudText, sizeof(g_hHudText), "%t", "Dodgeball_Hud_Speedometer_MaxSpeed", rocket.fSpeed, rocket.SpeedMpH(currentConfig.fMaxVelocity), rocket.iDeflectionCount, rocket.fSpeed / currentConfig.fMaxVelocity, rocket.SpeedMpH());
		g_bCurving = true;
	}
	else
	{
		Format(g_hHudText, sizeof(g_hHudText), "%t", "Dodgeball_Hud_Speedometer", rocket.fSpeed, rocket.SpeedMpH(), rocket.iDeflectionCount, rocket.fSpeed / currentConfig.fMaxVelocity);
		g_bCurving = false;
	}

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
		if (iTeam == GetClientTeam(iClient)) continue;	// Selecting a target NOT on iTeam
		if (iOwner == iClient) continue;				// Do not target owner (for FFA rockets)

		static float fClientPosition[3]; GetClientEyePosition(iClient, fClientPosition);
		static float fDirectionToClient[3]; MakeVectorFromPoints(fPosition, fClientPosition, fDirectionToClient);

		float fNewWeight = GetVectorDotProduct(fDirection, fDirectionToClient);

		if (fTargetWeight <= fNewWeight || (iTarget == -1))
		{
			iTarget = iClient;
			fTargetWeight = fNewWeight;
		}
	}

	if (iTarget > 0)
	{
		// Return ability to reflect rockets to target
		int iWeapon = GetEntPropEnt(iTarget, Prop_Data, "m_hActiveWeapon");
		TF2Attrib_SetByDefIndex(iWeapon, 826, 0.0);
	}
	
	return iTarget;
}

// ---- Round started, setup attributes & timers ----
public void OnSetupFinished(Event hEvent, char[] strEventName, bool bDontBroadcast)
{
	if (!BothTeamsPlaying()) return;

	//PopulateRocketSpawners(); // We've done this already when parsing config, I don't know if this breaks things, as other plugins always set it at the start of the round again
	g_fLastRocketSpawned = 0.0;
	g_iBot = GetBotClient();

	if (!g_bNERenabled && currentConfig.iForceNER >= 2)
	{
		g_bNERenabled = true;
		CPrintToChatAll("%t", "Dodgeball_NER_Forcefully_Enabled");
	}

	SetAttributes();

	// Solo stuff, round is starting
	g_soloQueue.Clear();
	char buffer[512], namebuffer[64];

	int iRedTeamCount = GetTeamClientCount(view_as<int>(TFTeam_Red));
	int iBlueTeamCount = GetTeamClientCount(view_as<int>(TFTeam_Blue));

	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsValidClient(iClient)) continue;

		g_iOldTeam[iClient] = 0; // FFA reset teams
		
		if (g_bSoloEnabled[iClient] && !IsSpectator(iClient))
		{
			// There are other players that are not solo'd (as of yet)
			if ((GetClientTeam(iClient) == view_as<int>(TFTeam_Red) ? --iRedTeamCount : --iBlueTeamCount) > 0)
			{
				if (g_soloQueue.Empty)
					Format(namebuffer, sizeof(namebuffer), "%N", iClient);
				else
					Format(namebuffer, sizeof(namebuffer), ", %N", iClient);
			
				StrCat(buffer, sizeof(buffer), namebuffer);

				g_soloQueue.Push(iClient);
				ForcePlayerSuicide(iClient);
			}
			// This person is last alive in team after all solo's, can't solo
			else
			{
				g_bSoloEnabled[iClient] = false;
				CPrintToChat(iClient, "%t", "Dodgeball_Solo_Not_Possible_No_Teammates");
			}
		}
	}

	g_hManageRocketsTimer = CreateTimer(0.5, ManageRockets, _, TIMER_REPEAT);

	if (currentConfig.bSpeedometer)
		g_hHudTimer = CreateTimer(0.1, RocketSpeedometer, _, TIMER_REPEAT);

	g_bRoundStarted = true;

	if (!g_soloQueue.Empty)
		CPrintToChatAll("%t", "Dodgeball_Solo_Announce_All_Soloers", buffer);
}

// ---- Spawning & deleting rockets -----------------
public Action ManageRockets(Handle hTimer, any aData)
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
public Action RocketSpeedometer(Handle hTimer, any aData)
{
	if (!g_bRoundStarted || !g_bEnabled || !currentConfig.bSpeedometer) return Plugin_Continue;
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientInGame(iClient)) continue;

		if (g_bCurving)
			SetHudTextParams(0.35, 0.925, 0.5, 255, 255, 255, 255, 0, 0.0, 0.12, 0.12);
		else
			SetHudTextParams(0.38, 0.925, 0.5, 255, 255, 255, 255, 0, 0.0, 0.12, 0.12);
		ShowSyncHudText(iClient, g_hMainHudSync, g_hHudText);
	}

	return Plugin_Continue;
}

// ---- General -------------------------------------
void PopulateRocketSpawners()
{
	// We do not support multiple rocket spawners this way (if that even was a thing), probably fine
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

void SetAttributes(int iSoloer = 0)
{
	// Setting weapon attributes (airblast delay, push prevention, etc.)
	int iWeapon;

	// Only set attributes for this soloer
	if (iSoloer)
	{
		if (!IsValidClient(iSoloer)) return;

		if (currentConfig.bDisablePlayerCollisions)
			SetEntProp(iSoloer, Prop_Data, "m_CollisionGroup", 17);
		else 
			SetEntProp(iSoloer, Prop_Data, "m_CollisionGroup", 5);

		iWeapon = GetEntPropEnt(iSoloer, Prop_Data, "m_hActiveWeapon");

		TF2Attrib_SetByDefIndex(iWeapon, 256, currentConfig.fAirblastDelay);
		// They are solo, so we do not have to include soft antisteal

		if (currentConfig.bPushPrevention)
		{
			TF2Attrib_SetByDefIndex(iWeapon, 823, 1.0);
		}
		else
		{
			TF2Attrib_SetByDefIndex(iWeapon, 823, 0.0);
			TF2Attrib_SetByDefIndex(iWeapon, 825, 1.0);
			TF2Attrib_SetByDefIndex(iWeapon, 255, currentConfig.fPushScale);
		}

		return;
	}

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

		// Soft antisteal if stealing is disabled
		if (!currentConfig.iMaxSteals && currentConfig.bSoftAntiSteal) // if 0
		{
			CPrintToChat(iClient, "%t", "Dodgeball_Soft_Stealing_Not_Enabled");
			TF2Attrib_SetByDefIndex(iWeapon, 826, 1.0); // Attrib 826 : airblast_deflect_projectiles_disabled
		}

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

public void OnClientPutInServer(int iClient)
{
	g_iSteals[iClient] = 0;
	g_iOldTeam[iClient] = 0;
	g_bSoloEnabled[iClient] = false;
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

		if (rocket.fSpeed > currentConfig.fMaxVelocity)
			CPrintToChatAll("%t", "Dodgeball_Death_Message_MaxSpeed", iClient, rocket.fSpeed, rocket.SpeedMpH(currentConfig.fMaxVelocity), rocket.iDeflectionCount, rocket.fSpeed / currentConfig.fMaxVelocity, rocket.SpeedMpH());
		else
			CPrintToChatAll("%t", "Dodgeball_Death_Message", iClient, rocket.fSpeed, rocket.SpeedMpH(), rocket.iDeflectionCount, rocket.fSpeed / currentConfig.fMaxVelocity);
	}
	
	// If it is a 1v1 (someone left / went to spectator, disable NER)
	if (g_bNERenabled && GetTeamClientCount(g_iLastDeadTeam) <= 1 && GetTeamClientCount(AnalogueTeam(g_iLastDeadTeam)) <= 1)
	{
		CPrintToChatAll("%t", "Dodgeball_NER_Not_Enough_Players_Disabled");
		g_fNERvoteTime = 0.0;
		g_bNERenabled = false;
	}

	if (GetTeamAliveCount(g_iLastDeadTeam) == 1)
	{

		// Giving priority to solo players, as otherwise it is too boring with NER or FFA
		if (!g_soloQueue.Empty)
		{
			int iSoloer;

			// Handles people who don't have solo enabled anymore, but are still left in queue
			while (!g_soloQueue.Empty)
			{
				iSoloer = g_soloQueue.Pop();

				if (g_bSoloEnabled[iSoloer] && !IsSpectator(iSoloer) && !IsPlayerAlive(iSoloer))
					break;
			}
				
			if (g_bSoloEnabled[iSoloer] && !IsSpectator(iSoloer) && !IsPlayerAlive(iSoloer))
			{
				// Respawn solo player
				ChangeClientTeam(iSoloer, g_iLastDeadTeam);
				TF2_RespawnPlayer(iSoloer);

				EmitSoundToClient(iSoloer, SOUND_NER_RESPAWNED, _, _, _, _, g_Cvar_HornVolumeLevel.FloatValue);

				return;
			}
		}
		// Switch people's team until 1 player left if NER
		else if ((g_bNERenabled || g_bFFAenabled) && GetTeamAliveCount(AnalogueTeam(g_iLastDeadTeam)) > 1)
		{
			int iRandomOpponent = GetTeamRandomAliveClient(AnalogueTeam(g_iLastDeadTeam));
			g_iOldTeam[iRandomOpponent] = AnalogueTeam(g_iLastDeadTeam);
		
			ChangeAliveClientTeam(iRandomOpponent, g_iLastDeadTeam);

			return;
		}		

		// Both teams had 1 player left, no soloers & no can be switched so respawn everyone
		if (g_bNERenabled && GetTeamAliveCount(AnalogueTeam(g_iLastDeadTeam)) == 1)
		{
			// Let round end if bot voted off & round didn't forcefully end
			if (g_iBot != GetBotClient())
				return;

			char buffer[512], namebuffer[64]; // keeping track of soloer names

			int iTotalNERplayers = 0;
			int iNERplayers[MAXPLAYERS + 1];

			// For solo
			g_soloQueue.Clear();
			int iWinner = GetTeamRandomAliveClient(AnalogueTeam(g_iLastDeadTeam));
			int iMarkedSoloer = 0;

			// Add to list to be reshuffled & respawned			
			for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer++)
			{
				if (!IsClientInGame(iPlayer) || IsSpectator(iPlayer))
					continue;

				int iLifeState = GetEntProp(iPlayer, Prop_Send, "m_lifeState");

				// Winner & loser not in here
				if (iLifeState && iPlayer != g_iBot)
					// Mark soloers to avoid round end, otherwise add to shuffle list
					if (!g_bSoloEnabled[iPlayer])
						iNERplayers[iTotalNERplayers++] = iPlayer;
					else
						iMarkedSoloer = iPlayer;
			}

			// No players available, remove someone from solo
			if (!iTotalNERplayers)
			{
				// This client should never be 0, as our earlier check would've ended solo if 1v1
				iNERplayers[iTotalNERplayers++] = iMarkedSoloer;

				g_bSoloEnabled[iMarkedSoloer] = false;
				CPrintToChat(iMarkedSoloer, "%t", "Dodgeball_Solo_Not_Possible_NER_Would_End");
			}

			// If it's player v bot then respawn on 1 side, otherwise randomize
			int iNewTeam;
			if (g_iBot)
				iNewTeam = AnalogueTeam(GetClientTeam(g_iBot));
			else
				iNewTeam = g_iLastDeadTeam;

			// fisher yates shuffle & respawn, start respawning for last dead team to avoid round end
			for (int i = iTotalNERplayers - 1; i >= 0; i--)
			{						
				int j = GetRandomInt(0, i);

				ChangeClientTeam(iNERplayers[j], iNewTeam);
				TF2_RespawnPlayer(iNERplayers[j]);
				
				if (!g_iBot)
					iNewTeam = AnalogueTeam(iNewTeam);
					
				iNERplayers[j] = iNERplayers[i];
			}

			// For some reason randomly some people do not get respawned, do not know if issue persists after refactoring (post 1.3.1)
			// Keeping it in, as the issue is likely not resolved yet
			for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer++)
			{
				if (!IsValidClient(iPlayer) || IsSpectator(iPlayer) || g_bSoloEnabled[iPlayer])
					continue;
				
				if (!IsPlayerAlive(iPlayer))
				{
					ChangeClientTeam(iPlayer, iNewTeam);
					TF2_RespawnPlayer(iPlayer);

					if (!g_iBot)
						iNewTeam = AnalogueTeam(iNewTeam);
				}
			}

			// Red & blue players count changed, we do not switch the winner
			int iRedTeamCount = GetTeamClientCount(view_as<int>(TFTeam_Red)) - 1;
			int iBlueTeamCount = GetTeamClientCount(view_as<int>(TFTeam_Blue)) - 1;

			// message all solo players that they weren't respawned & push back to queue
			for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer++)
			{
				if (!IsClientInGame(iPlayer) || IsSpectator(iPlayer))
					continue;

				if (g_bSoloEnabled[iPlayer] && iPlayer != iWinner)
				{
					if ((GetClientTeam(iPlayer) == view_as<int>(TFTeam_Red) ? iRedTeamCount-- : iBlueTeamCount--) > 0)
					{
						if (g_soloQueue.Empty)
							Format(namebuffer, sizeof(namebuffer), "%N", iPlayer);
						else
							Format(namebuffer, sizeof(namebuffer), ", %N", iPlayer);
		
						StrCat(buffer, sizeof(buffer), namebuffer);

						g_soloQueue.Push(iPlayer);
						CPrintToChat(iPlayer, "%t", "Dodgeball_Solo_NER_Notify_Not_Respawned");
					}
					else
					{
						g_bSoloEnabled[iPlayer] = false;
						CPrintToChat(iPlayer, "%t", "Dodgeball_Solo_Not_Possible_NER_Would_End");

						TF2_RespawnPlayer(iPlayer);
					}
				}
			}

			if (g_bSoloEnabled[iWinner])
			{
				// Winner is not only one alive in the team, so they can return to solo
				if (GetTeamAliveCount(AnalogueTeam(g_iLastDeadTeam)) > 1)
				{
					if (g_soloQueue.Empty)
						Format(namebuffer, sizeof(namebuffer), "%N", iWinner);
					else
						Format(namebuffer, sizeof(namebuffer), ", %N", iWinner);
			
					StrCat(buffer, sizeof(buffer), namebuffer);

					g_soloQueue.Push(iWinner);
					CPrintToChat(iWinner, "%t", "Dodgeball_Solo_NER_Notify_Not_Respawned");
					ForcePlayerSuicide(iWinner);
				}
				// Can't solo, last in team
				else
				{
					g_bSoloEnabled[iWinner] = false;
					CPrintToChat(iWinner, "%t", "Dodgeball_Solo_Not_Possible_NER_Would_End");
					SetEntityHealth(iWinner, 175);
				}
			}
			else
				SetEntityHealth(iWinner, 175);

			// We have to respawn the last player 1 frame later, as they haven't died yet (since this is a PRE hook)
			if (g_bSoloEnabled[iClient])
				RequestFrame(RespawnPlayerCallback, 0);
			else
				RequestFrame(RespawnPlayerCallback, iClient); 

			if (!g_soloQueue.Empty)
				CPrintToChatAll("%t", "Dodgeball_Solo_Announce_All_Soloers", buffer);
		}
	}
}

void RespawnPlayerCallback(any aData)
{
	if (aData)
		TF2_RespawnPlayer(aData);
		
	// We only notify non-solo players of being respawned
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!g_bSoloEnabled[iClient] && IsValidClient(iClient))
			EmitSoundToClient(iClient, SOUND_NER_RESPAWNED, _, _, _, _, g_Cvar_HornVolumeLevel.FloatValue);
	}
	
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
bool ParseConfig(char[] strConfigFile = "general.cfg", bool bUpdateGameplayConfig = true)
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

	// Max velocity
	cfg.GetFloat("rocket.max velocity", currentConfig.fMaxVelocity);
	SetConVarFloat(FindConVar("sv_maxvelocity"), currentConfig.fMaxVelocity);

	// Rocket speed
	cfg.Get("rocket.speed formula", strBuffer, sizeof(strBuffer));
	currentConfig.strSpeedFormula = ShuntingYard(strBuffer);

	// Thresholds
	cfg.GetInt("rocket.threshold a", currentConfig.iThresholdA);
	cfg.GetInt("rocket.threshold b", currentConfig.iThresholdB);

	// Rocket turnrate
	cfg.Get("rocket.turnrate formula", strBuffer, sizeof(strBuffer));
	currentConfig.strTurnrateFormula = ShuntingYard(strBuffer);
	cfg.GetFloat("rocket.turnrate limit", currentConfig.fTurnrateLimit);

	// Spiking
	cfg.GetInt("rocket.spiking deflect", currentConfig.iSpikingDeflects);
	cfg.GetFloat("rocket.spiking strength", currentConfig.fSpikingStrength);
	cfg.GetFloat("rocket.spiking time", currentConfig.fSpikingTime);
	cfg.GetFloat("rocket.spiking max time", currentConfig.fSpikingMaxTime);

	// Orbitting
	cfg.GetFloat("rocket.orbit factor", currentConfig.fOrbitFactor);

	// Rocket dragging
	cfg.GetFloat("rocket.drag time max", currentConfig.fDragTimeMax);
	cfg.GetFloat("rocket.turning delay", currentConfig.fTurningDelay);

	// Rocket bouncing
	cfg.GetBool("rocket.down spiking", currentConfig.bDownspikes);	// There was a bug in .GetBool in cfgmap.inc; Changed line 656: sizeof(strval)-1 -> sizeof(strval)
	cfg.GetFloat("rocket.bounce time", currentConfig.fBounceTime);
	cfg.GetInt("rocket.max bounces", currentConfig.iMaxBounces);

	// Waving
	cfg.GetInt("rocket.wave type", currentConfig.iWavetype);

	cfg.Get("rocket.wave oscillations formula", strBuffer, sizeof(strBuffer));
	currentConfig.strWaveOscillationsFormula = ShuntingYard(strBuffer);
	cfg.GetFloat("rocket.minimum oscillations", currentConfig.fWaveOscillationsMin);
	cfg.GetFloat("rocket.maximum oscillations", currentConfig.fWaveOscillationsMax);

	cfg.Get("rocket.wave amplitude formula", strBuffer, sizeof(strBuffer));
	currentConfig.strWaveAmplitudeFormula = ShuntingYard(strBuffer);
	cfg.GetFloat("rocket.minimum amplitude", currentConfig.fWaveAmplitudeMin);
	cfg.GetFloat("rocket.maximum amplitude", currentConfig.fWaveAmplitudeMax);

	// General gameplay
	if (bUpdateGameplayConfig)
	{
		// Rocket spawning
		cfg.GetInt("gameplay.max rockets", currentConfig.iMaxRockets);
		cfg.GetFloat("gameplay.rocket spawn interval", currentConfig.fSpawnInterval);

		// Airblast pushback
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
		cfg.GetBool("gameplay.soft antisteal", currentConfig.bSoftAntiSteal);
		cfg.GetFloat("gameplay.walling distance", currentConfig.fWallingDistance);
		cfg.GetBool("gameplay.announce stealing", currentConfig.bAnnounceSteals);

		// Solo
		cfg.GetBool("gameplay.solo enabled", currentConfig.bSoloAllowed);

		// FFA (Free for all)
		cfg.GetBool("gameplay.free for all", currentConfig.bFFAallowed);
		cfg.GetFloat("gameplay.ffa voting timeout", currentConfig.fFFAvotingTimeout);

		// NER (Never ending rounds)
		cfg.GetBool("gameplay.never ending rounds", currentConfig.bNeverEndingRoundsAllowed);
		cfg.GetFloat("gameplay.ner voting timeout", currentConfig.fNERvotingTimeout);
		cfg.GetInt("gameplay.ner forced", currentConfig.iForceNER);

		if (currentConfig.bNeverEndingRoundsAllowed && currentConfig.iForceNER)
			g_bNERenabled = true;
	}
	
	PopulateRocketSpawners();
	Forward_OnRocketsConfigExecuted(strFileName, currentConfig);

	// If FFA, NER or solo is not allowed anymore disable them
	if (!currentConfig.bFFAallowed && g_bFFAenabled)
	{
		g_bFFAenabled = false;
		CPrintToChatAll("%t", "Dodgeball_FFA_Disabled_By_New_Config");
	}
	if (!currentConfig.bNeverEndingRoundsAllowed && g_bNERenabled)
	{
		g_bNERenabled = false;
		CPrintToChatAll("%t", "Dodgeball_NER_Disabled_By_New_Config");
	}

	if (!currentConfig.bSoloAllowed)
	{
		for (int iClient = 1; iClient <= MaxClients; iClient++)
		{
			if (g_bSoloEnabled[iClient])
			{
				g_bSoloEnabled[iClient] = false;
				CPrintToChat(iClient, "%t", "Dodgeball_Solo_Disabled_By_New_Config");
			}
		}
		g_soloQueue.Clear();
	}

	DestroyAllRockets();

	return true;
}

// "sm_loadconfig <config_name>"
public Action CmdLoadConfig(int iClient, int iArgs)
{
	if (!IsDodgeBallMap())
	{
		CReplyToCommand(iClient, "%t", "Command_Dodgeball_Disabled");		
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
		
		if (StrContains(strConfigFile, ".cfg", false) == -1)
			StrCat(strConfigFile, sizeof(strConfigFile), ".cfg");

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
		// Is Special variable
		if (StrContains(strExploded[n], "x", false) != -1) // x = deflection count
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
		// Is operator
		else if (OperatorPrecendence(view_as<int>(strExploded[n][0])))
		{
			i -= 2; // [4, 2, 8], i is currently 3, we need it to be 1, as the operation is on the last 2 items
			EvalBuffer[i] = DoOperation(EvalBuffer[i], EvalBuffer[i+1], view_as<int>(strExploded[n][0])); // doesn't matter that EvalBuffer[i+1] is something we set earlier
			i++; // We point to next value in array again
		}
		// Is number
		else if (StringToFloat(strExploded[n]))
		{
			EvalBuffer[i++] = StringToFloat(strExploded[n]);
		}
		else if (StringToInt(strExploded[n]))
		{
			EvalBuffer[i++] = float(StringToInt(strExploded[n]));
		}
		else
		{
			EvalBuffer[i++] = 0.0;
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
	}
	// Otherwise compiler complains
	return 0.0;
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

// ---- Solo ----------------------------------------

// "sm_solo"
public Action CmdSolo(int iClient, int iArgs)
{
	if (!iClient)
	{
		PrintToServer("Command is in game only.");

		return Plugin_Handled;
	}

	if (!g_bEnabled)
	{
		CReplyToCommand(iClient, "%t", "Command_Dodgeball_Disabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bSoloAllowed)
	{
		CReplyToCommand(iClient, "%t", "Command_Disabled_By_Config");

		return Plugin_Handled;
	}

	// Disable solo mode
	if (g_bSoloEnabled[iClient])
	{
		CPrintToChat(iClient, "%t", "Dodgeball_Solo_Toggled_Off");
		g_bSoloEnabled[iClient] = false;
	}
	// Last alive, we can not active solo mode in this state
	else if (IsValidClient(iClient) && GetTeamAliveCount(GetClientTeam(iClient)) == 1)
	{
		CPrintToChat(iClient, "%t", "Dodgeball_Solo_Not_Possible_Last_Alive");
	}
	// Activate solo mode
	else
	{
		// Alive, kill player & add to queue
		if (IsValidClient(iClient) && g_bRoundStarted)
		{
			ForcePlayerSuicide(iClient);
			g_soloQueue.Push(iClient);
		}

		CPrintToChat(iClient, "%t", "Dodgeball_Solo_Toggled_On");
		g_bSoloEnabled[iClient] = true;
	}

	return Plugin_Continue;
}

// ---- FFA voting/enabling -------------------------

// "sm_ffa"
public Action CmdToggleFFA(int iClient, int iArgs)
{
	if (!g_bEnabled)
	{
		CReplyToCommand(iClient, "%t", "Command_Dodgeball_Disabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bFFAallowed)
	{
		CReplyToCommand(iClient, "%t", "Command_Disabled_By_Config");

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
		CReplyToCommand(iClient, "%t", "Command_Dodgeball_Disabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bFFAallowed)
	{
		CReplyToCommand(iClient, "%t", "Command_Disabled_By_Config");

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
		CPrintToChatAll("%t", "Dodgeball_FFA_Enabled");
		SetConVarInt(FindConVar("mp_friendlyfire"), 1);

		g_bFFAenabled = true;
		return;
	}

	CPrintToChatAll("%t", "Dodgeball_FFA_Disabled");
	SetConVarInt(FindConVar("mp_friendlyfire"), 0);

	g_bFFAenabled = false;
}

// ---- NER voting/enabling -------------------------

// "sm_ner"
public Action CmdToggleNER(int iClient, int iArgs)
{
	if (!g_bEnabled)
	{
		CReplyToCommand(iClient, "%t", "Command_Dodgeball_Disabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bNeverEndingRoundsAllowed)
	{
		CReplyToCommand(iClient, "%t", "Command_Disabled_By_Config");

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
		CReplyToCommand(iClient, "%t", "Command_Dodgeball_Disabled");
		
		return Plugin_Handled;
	}

	if (!currentConfig.bNeverEndingRoundsAllowed)
	{
		CReplyToCommand(iClient, "%t", "Command_Disabled_By_Config");

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
		CPrintToChatAll("%t", "Dodgeball_NER_Enabled");

		g_bNERenabled = true;
		return;
	}

	CPrintToChatAll("%t", "Dodgeball_NER_Disabled");
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
			// Rocket owner if soft antisteal shouldn't be able to reflect anymore
			if (currentConfig.bSoftAntiSteal && g_iSteals[rocket.iTarget] >= currentConfig.iMaxSteals && NumRocketsTargetting(rocket.iTarget) == 1)
			{
				int iWeapon = GetEntPropEnt(rocket.iTarget, Prop_Data, "m_hActiveWeapon");
				TF2Attrib_SetByDefIndex(iWeapon, 826, 1.0);
			}

			g_fLastRocketSpawned = GetGameTime(); // Delay until spawning next rocket
			
			g_rockets.Erase(n--); // g_rockets.Length changes
		}
		else if (!IsValidClient(rocket.iOwner) || !IsValidClient(rocket.iTarget)) // Target / owner became invalid (left game or died), could also prevent soft anti steal, but rare cases
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

// Technically all valid references would be a valid 'rocket', assuming a rocket reference is meant to be checked
bool IsValidRocket(int iRef)
{
	return EntRefToEntIndex(iRef) != INVALID_ENT_REFERENCE ? true : false;
}

bool IsDodgeBallMap()
{
    char strMap[64]; GetCurrentMap(strMap, sizeof(strMap));
    return StrContains(strMap, "tfdb_", false) != -1;
}

int NumRocketsTargetting(int iClient)
{
	if (!IsValidClient(iClient))
		return 0;
	
	Rocket rocket;
	int count = 0;

	for (int n = 0; n < g_rockets.Length; n++)
	{
		g_rockets.GetArray(n, rocket);
		
		if (rocket.bHasTarget && rocket.iTarget == iClient)
			count++;
	}

	return count;
}

// ---- General utils -------------------------------
bool IsValidClient(int iClient)
{
	if (iClient > 0 && iClient <= MaxClients)
		return IsClientInGame(iClient) && IsPlayerAlive(iClient);
	return false;
}

bool IsSpectator(int iClient)
{
	return GetClientTeam(iClient) == view_as<int>(TFTeam_Spectator);
}

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

stock float GetEntitiesDistance(int iEnt1, int iEnt2)
{
	static float fOrig1[3]; GetEntPropVector(iEnt1, Prop_Send, "m_vecOrigin", fOrig1);
	static float fOrig2[3]; GetEntPropVector(iEnt2, Prop_Send, "m_vecOrigin", fOrig2);
	
	return GetVectorDistance(fOrig1, fOrig2);
}

bool BothTeamsPlaying()
{
	return GetTeamAliveCount(view_as<int>(TFTeam_Blue)) > 0 && GetTeamAliveCount(view_as<int>(TFTeam_Red)) > 0;
}

int GetBotClient()
{
	// Shouldn't really use this 'shortcut',
	// we should probably also check if bot is not in spectator or something along those lines
	if (g_Cvar_SeeBotsAsPlayers.BoolValue)
		return 0;

	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (IsClientInGame(iClient) && IsFakeClient(iClient))
			return iClient;
	}
	
	return 0;
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

void ChangeAliveClientTeam(int iClient, int iTeam)
{
	// Changing players team whilst keeping them alive
	SetEntProp(iClient, Prop_Send, "m_lifeState", 2);
	ChangeClientTeam(iClient, iTeam);
	SetEntProp(iClient, Prop_Send, "m_lifeState", 0);
	
	// Fixing colour of cosmetic(s) not changing
	int iWearable;
	int iWearablesCount = GetPlayerWearablesCount(iClient);

	Address pData = DereferencePointer(GetEntityAddress(iClient) + g_pMyWearables);
	
	for (int iIndex = 0; iIndex < iWearablesCount; iIndex++)
	{
		iWearable = LoadEntityHandleFromAddress(pData + view_as<Address>(0x04 * iIndex));
		
		SetEntProp(iWearable, Prop_Send, "m_nSkin", (iTeam == view_as<int>(TFTeam_Blue)) ? 1 : 0);
		SetEntProp(iWearable, Prop_Send, "m_iTeamNum", iTeam);
	}
}

/*
	https://github.com/nosoop/SM-TFUtils/blob/master/scripting/tf2utils.sp
	https://github.com/nosoop/stocksoup/blob/master/memory.inc
*/

int LoadEntityHandleFromAddress(Address pAddress)
{
	return EntRefToEntIndex(LoadFromAddress(pAddress, NumberType_Int32) | (1 << 31));
}

Address DereferencePointer(Address pAddress)
{
	// maybe someday we'll do 64-bit addresses
	return view_as<Address>(LoadFromAddress(pAddress, NumberType_Int32));
}

int GetPlayerWearablesCount(int iClient)
{
	return GetEntData(iClient, view_as<int>(g_pMyWearables) + 0x0C);
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

void Forward_OnRocketHitPlayer(int iIndex, Rocket rocket, int iClient)
{
	Call_StartForward(g_ForwardOnRocketHitPlayer);
	Call_PushCell(iIndex);
	Call_PushArrayEx(rocket, sizeof(rocket), SM_PARAM_COPYBACK);
	Call_PushCell(iClient);
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

public any Native_NumRocketsTargetting(Handle hPlugin, int iNumParams)
{
	int iClient = GetNativeCell(1);

	return NumRocketsTargetting(iClient);
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

public any Native_HasRoundStarted(Handle hPlugin, int iNumParams)
{
	return g_bRoundStarted;
}
