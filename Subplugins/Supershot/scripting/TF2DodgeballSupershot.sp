#pragma semicolon 1
#pragma newdecls required

#include <tfdb>
#include <cfgmap>
#include <multicolors>

#define PLUGIN_NAME        "[TFDB] Supershot (from Redux) for TFDB Unified" 
#define PLUGIN_AUTHOR      "Mikah"
#define PLUGIN_VERSION     "1.0.0"
#define PLUGIN_URL         "https://github.com/Mikah31/TF2-Dodgeball-Unified"

public Plugin myinfo =
{
	name        = PLUGIN_NAME,
	author      = PLUGIN_AUTHOR,
	description = PLUGIN_NAME,
	version     = PLUGIN_VERSION,
	url         = PLUGIN_URL
};

#define SUPERSHOT_ALL		"weapons/airstrike_fire_03.wav"  
#define SUPERSHOT_OWNER		"weapons/loch_n_load_shoot_crit.wav"
#define SUPERSHOT_TARGET	"weapons/airstrike_fire_crit.wav"
#define SUPERSHOT_CANCELLED	"weapons/bumper_car_hit_ball.wav"

// Parameters to determine how easy/hard it is to lock on
#define Supershot_start			4.0
#define Supershot_gain			2.0
#define Supershot_loss			1.0
#define Supershot_threshold		8.0
#define Supershot_max			10.0

bool g_bEnabled;

bool g_bWarnTarget;

bool g_bAlertSoundAll;

bool g_bDraggingEnabled;

bool g_bCancelOnMultipleTargetting;
bool g_bCancelledChatMessage;
bool g_bCancelledPlaySound;

float g_fHudVerticalPosition;

float g_fSpeedMult;
float g_fTurnrateMult;

// Main plugin rocket config (we overwrite parts of it)
float config_fDragTimeMax;
int config_iWaveType;
bool config_bOneRocketPerTarget;
bool config_bIsModified;

// Supershot handling
Handle g_hHudTimer;
Handle g_hMainHudSync;
int g_iTargets[MAXPLAYERS + 1];
float g_fTimeOnTarget[MAXPLAYERS + 1];

public void OnPluginStart()
{
	LoadTranslations("tfdb.phrases.txt");
}

public void OnConfigsExecuted()
{
	PrecacheSound(SUPERSHOT_ALL, true);
	PrecacheSound(SUPERSHOT_OWNER, true);
	PrecacheSound(SUPERSHOT_TARGET, true);
	PrecacheSound(SUPERSHOT_CANCELLED, true);
}

public void OnMapEnd()
{
	if (!g_bEnabled) return;

	if (g_hHudTimer != null)
	{
		delete g_hMainHudSync;
		KillTimer(g_hHudTimer);
		g_hHudTimer = null;
	}

	g_bEnabled = false;
}

public void TFDB_OnRocketsConfigExecuted(const char[] strConfigFile, TFDBConfig config)
{
	ConfigMap cfg = new ConfigMap(strConfigFile);

	config_fDragTimeMax = config.fDragTimeMax;
	config_iWaveType = config.iWavetype;
	config_bOneRocketPerTarget = config.bOneRocketPerTarget;
	config_bIsModified = false;

	cfg.GetBool("subplugins.supershot.enabled", g_bEnabled);

	cfg.GetBool("subplugins.supershot.alert sound all", g_bAlertSoundAll);

	cfg.GetBool("subplugins.supershot.dragging enabled", g_bDraggingEnabled);

	cfg.GetBool("subplugins.supershot.warn target", g_bWarnTarget);

	cfg.GetBool("subplugins.supershot.cancel supershot", g_bCancelOnMultipleTargetting);
	cfg.GetBool("subplugins.supershot.cancelled text", g_bCancelledChatMessage);
	cfg.GetBool("subplugins.supershot.cancelled sound", g_bCancelledPlaySound);

	cfg.GetFloat("subplugins.supershot.hudtext position", g_fHudVerticalPosition);

	cfg.GetFloat("subplugins.supershot.speed multiplier", g_fSpeedMult);
	cfg.GetFloat("subplugins.supershot.turnrate multiplier", g_fTurnrateMult);

	if (g_hHudTimer == null && g_bEnabled)
	{
		g_hMainHudSync = CreateHudSynchronizer();
		g_hHudTimer = CreateTimer(0.1, HandleSupershot, _, TIMER_REPEAT);
	}
	else if (g_hHudTimer != null && !g_bEnabled)
	{
		delete g_hMainHudSync;
		KillTimer(g_hHudTimer);
		g_hHudTimer = null;
	}
}

public Action HandleSupershot(Handle hTimer, any aData)
{
	if (!TFDB_HasRoundStarted())
		return Plugin_Continue;

	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientInGame(iClient) || !IsPlayerAlive(iClient)) continue;

		if (!g_iTargets[iClient])
		{
			// We first select an enemy as target, GetClientAimTarget does not work in third person
			int iNewTarget = GetClientAimTarget(iClient, true);

			if (!IsValidClient(iNewTarget) || (GetClientTeam(iNewTarget) == GetClientTeam(iClient) && !TFDB_IsFFAenabled()))
				continue;

			g_iTargets[iClient] = iNewTarget;
			g_fTimeOnTarget[iClient] = Supershot_start;
		}
		else
		{
			// Target is locked & looked at
			g_fTimeOnTarget[iClient] += LookingAtTarget(iClient, g_iTargets[iClient]) ? Supershot_gain : -Supershot_loss;
			g_fTimeOnTarget[iClient] = g_fTimeOnTarget[iClient] > Supershot_max ? Supershot_max : g_fTimeOnTarget[iClient];

			// Not being looked at anymore
			if (g_fTimeOnTarget[iClient] <= 0.0)
			{
				g_iTargets[iClient] = 0;
				g_fTimeOnTarget[iClient] = 0.0;
				continue;
			}
			
			if (g_fTimeOnTarget[iClient] > Supershot_threshold)
			{
				// Setting RGB values of the text in accordance to the locking percentage
				SetHudTextParams(0.44, g_fHudVerticalPosition, 0.5, RoundFloat(255*(1-g_fTimeOnTarget[iClient]/Supershot_max)), RoundFloat(255*(g_fTimeOnTarget[iClient]/Supershot_max)), 0, 255, 0, 0.0, 0.12, 0.12);
				ShowSyncHudText(iClient, g_hMainHudSync, "%t", "Dodgeball_Supershot_Locked");

				// Warn only if target does not have someone else locked
				if (g_bWarnTarget && !g_iTargets[g_iTargets[iClient]])
				{
					SetHudTextParams(0.43, g_fHudVerticalPosition, 0.5, 255, 0, 0, 255, 0, 0.0, 0.12, 0.12);
					ShowSyncHudText(g_iTargets[iClient], g_hMainHudSync, "%t", "Dodgeball_Supershot_Being_Locked");
				}
			}
			else
			{
				SetHudTextParams(0.44, g_fHudVerticalPosition, 0.5, RoundFloat(255*(1-g_fTimeOnTarget[iClient]/Supershot_max)), RoundFloat(255*(g_fTimeOnTarget[iClient]/Supershot_max)), 0, 255, 0, 0.0, 0.12, 0.12);
				ShowSyncHudText(iClient, g_hMainHudSync, "%t", "Dodgeball_Supershot_Locking");
			}
		}
	}

	return Plugin_Continue;
}

// More reliable than GetClientAimTarget(..)
bool LookingAtTarget(int iClient, int iTarget)
{
	if (!IsValidClient(iTarget))
		return false;

	float fClientPos[3]; GetClientEyePosition(iClient, fClientPos);
	float fClientAng[3]; GetClientEyeAngles(iClient, fClientAng);

	Handle hTrace = TR_TraceRayFilterEx(fClientPos, fClientAng, MASK_PLAYERSOLID, RayType_Infinite, TraceFilter, iClient);

	float fTraceHitPos[3]; TR_GetEndPosition(fTraceHitPos, hTrace);
	float fTargetPos[3]; GetClientEyePosition(iTarget, fTargetPos);

	delete hTrace;

	// Hitting anywhere on enemy model is ~20-80 distance
	return GetVectorDistance(fTraceHitPos, fTargetPos) < 100;
}

public bool TraceFilter(int iEntity, int iContentsMask, any aData)
{
	return (iEntity != aData);
}

public void TFDB_OnRocketDeflect(int iIndex, Rocket rocket)
{
	if (!g_bEnabled)
		return;

	// Preventing multiple rockets targetting one person if config disallows it
	bool bShouldCancel = false;
	if (g_bCancelOnMultipleTargetting && config_bOneRocketPerTarget && TFDB_NumRocketsTargetting(g_iTargets[rocket.iOwner]))
	{
		if (g_bCancelledChatMessage)
			CPrintToChat(rocket.iOwner, "%t", "Dodgeball_Supershot_Cancelled");

		if (g_bCancelledPlaySound)
			EmitSoundToClient(rocket.iOwner, SUPERSHOT_CANCELLED);

		bShouldCancel = true;
	}
		
	if (bShouldCancel || g_fTimeOnTarget[rocket.iOwner] < Supershot_threshold)
	{
		// Return config back to normal
		if (config_bIsModified)
		{
			TFDBConfig config; TFDB_GetCurrentConfig(config);
			config.fDragTimeMax = config_fDragTimeMax;
			config.iWavetype = config_iWaveType;
			TFDB_SetCurrentConfig(config);

			config_bIsModified = false;
		}
		return;
	}

	// Supershot activated
	rocket.fSpeed *= g_fSpeedMult;
	rocket.fTurnrate *= g_fTurnrateMult;

	// Force target
	rocket.bHasTarget = true;
	rocket.iTarget = g_iTargets[rocket.iOwner];

	// This is to prevent copying the entire config each supershot (instead of when it is actually required)
	if (!g_bDraggingEnabled || config_iWaveType)
	{
		TFDBConfig config; TFDB_GetCurrentConfig(config);

		// Disabling dragging
		if (!g_bDraggingEnabled)
			config.fDragTimeMax = 0.0;

		// Disabling waving (breaks with supershot)
		config.iWavetype = 0;

		TFDB_SetCurrentConfig(config);
		config_bIsModified = true;
	}

	// Sounds
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientInGame(iClient)) continue;

		if (iClient == rocket.iOwner)
			EmitSoundToClient(iClient, SUPERSHOT_OWNER);
		else if (iClient == g_iTargets[rocket.iOwner])
		{
			EmitSoundToClient(iClient, SOUND_ALERT); // We skipped the targetting stage, so there was no alert sound
			EmitSoundToClient(iClient, SUPERSHOT_TARGET);
		}
		else if (g_bAlertSoundAll)
			EmitSoundToClient(iClient, SUPERSHOT_ALL);
	}

	g_fTimeOnTarget[rocket.iOwner] = Supershot_start;
}

bool IsValidClient(int iClient)
{
	if (iClient > 0 && iClient <= MaxClients)
		return IsClientInGame(iClient) && IsPlayerAlive(iClient);
	return false;
}