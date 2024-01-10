#if defined _tfdb_included_
  #endinput
#endif
#define _tfdb_included_

// Requires tf2_stocks for GetClientEyePosition & emitting sounds
#include <tf2_stocks>

// ---- Rocket structure ---------------------------------------
enum struct Rocket
{
	// Do not change the ordering of these variables, we read/write directly to these indices sometimes
	int iEntity;
	int iRef;
	//////////////////////

	int iOwner;
	int iTarget;
	int iTeam;

	float fDamage;
	float fSpeed;
	float fTurnrate;

	int iDeflectionCount;
	int iBounces;
	
	float fTimeLastDeflect;
	float fTimeLastBounce;
	float fTimeInOrbit;

	bool bHasTarget;
	bool bBeingDelayed;
	bool bStolen;
	bool bRecentlyReflected;
	bool bRecentlyBounced;	

	float fDirection[3];

	// Starting distance to target, used for calculating phase in wave
	float fWaveDistance;

	bool InOrbit()
	{
		if (!this.bHasTarget) return false;

		static float fTargetPosition[3]; GetClientEyePosition(this.iTarget, fTargetPosition);
		static float fRocketPosition[3]; GetEntPropVector(this.iEntity, Prop_Data, "m_vecOrigin", fRocketPosition);

		if (GetVectorDistance(fTargetPosition, fRocketPosition) < 300.0) // 300.0 is roughly airblasting distance
			return true;
		return false;
	}

	void EmitRocketSound(char[] strPathSound, int iEntitySource = 0)
	{
		if (iEntitySource)
			EmitSoundToAll(strPathSound, iEntitySource); // SOUND_SPAWN / SOUND_SPEEDUP
		else
			EmitSoundToClient(this.iTarget, strPathSound, _, _, _, _, 0.5); // SOUND_ALERT
	}

	float SpeedMpH()
	{
		// 0.042614 is the conversion factor to MpH in other plugins
		return this.fSpeed * 0.042614;
	}
}

// ---- Config structure ---------------------------------------

enum struct TFDBConfig
{
	char strDamageFormula[256]; // gives us an effective max equation length of worst case max ~128 characters due to added spacers
	char strSpeedFormula[256];
	char strTurnrateFormula[256];

	float fSpeedMin;
	float fSpeedMax;
	float fTurnrateMin;
	float fTurnrateMax;

	float fDragTimeMax;
	float fTurningDelay;

	int iMaxRockets;
	float fSpawnInterval;
	
	bool bDownspikes;
	float fBounceTime;
	int iMaxBounces;

	int iWavetype;
	float fWaveAmplitude;
	float fWaveOscillations;

	int iMaxSteals;
	bool bStolenRocketsDoDamage;
	
	float fDelayTime; // Delay time before rocket starts speeding up

	bool bPushPrevention;
	float fPushScale;
	float fAirblastDelay;

	bool bSpeedometer;
	bool bAirblastTeamRockets;
	bool bDisablePlayerCollisions;
	
	bool bFFAallowed;
	float fFFAvotingTimeout;
	bool bNeverEndingRoundsAllowed;
	float fNERvotingTimeout;

	// Prints the formula in RPN notation, use https://k144.github.io/tools/rpn/ to convert back, DEBUG
	void PrintFormulae()
	{
		PrintToServer("Damage formula (RPN): %s", this.strDamageFormula);
		PrintToServer("Speed formula (RPN): %s", this.strSpeedFormula);
		PrintToServer("Turnrate formula (RPN): %s", this.strTurnrateFormula);
	}
}

// ---- Sounds / other resources ---------------------------------------
#define SOUND_ALERT 		"weapons/sentry_spot.wav"
#define SOUND_SPAWN 		"weapons/sentry_rocket.wav"
#define SOUND_SPEEDUP   	"misc/doomsday_lift_warning.wav"
#define SOUND_NER_RESPAWNED	")ambient/alarms/doomsday_lift_alarm.wav"

// ---- Forwards ---------------------------------------

// NOTE:
// Using structs in forwards/natives could change in the future: https://github.com/alliedmodders/sourcepawn/issues/547

/**
 * Called whenever a rocket is created (not yet dispatched).
 * 
 * @param iIndex    Rocket index in ArrayList.
 * @param rocket    Rocket structure.
 */
forward void TFDB_OnRocketCreated(int iIndex, Rocket rocket);

/**
 * Called when a rocket has been deflected.
 * 
 * @param iIndex    Rocket index in ArrayList.
 * @param rocket    Rocket structure.
 */
forward void TFDB_OnRocketDeflect(int iIndex, Rocket rocket);

/**
 * Called when rocket has been stolen.
 * 
 * @note Called even when stealing is allowed, can not influence the stealcount of players.
 * 
 * @param iIndex        Rocket index in ArrayList.
 * @param rocket        Rocket structure, rocket.iOwner = stealer.
 * @param iStealCount   Number of rockets stolen.
 */
forward void TFDB_OnRocketSteal(int iIndex, Rocket rocket, int iStealCount);

/**
 * Called when rocket is being delayed.
 * 
 * @param iIndex    Rocket index in ArrayList.
 * @param rocket    Rocket structure.
 */
forward void TFDB_OnRocketDelay(int iIndex, Rocket rocket);

/**
 * Called when a new target is selected (before "alert" sound played).
 * 
 * @param iIndex    Rocket index in ArrayList.
 * @param rocket    Rocket structure, rocket.iTarget = new target.
 */
forward void TFDB_OnRocketNewTarget(int iIndex, Rocket rocket);

/**
 * Called when the rocket (is going to) hit a player.
 * 
 * @param iIndex    Rocket index in ArrayList.
 * @param rocket    Rocket structure.
 */
forward void TFDB_OnRocketHitPlayer(int iIndex, Rocket rocket);

/**
 * Called when the rocket has bounced.
 * 
 * @param iIndex    Rocket index in ArrayList.
 * @param rocket    Rocket structure.
 */
forward void TFDB_OnRocketBounce(int iIndex, Rocket rocket);

/**
 * Called when a TFDB configuration file has been successfully parsed.
 * 
 * @param strConfigFile     Path to configuration file
 * @param config            Config structure.
 */
forward void TFDB_OnRocketsConfigExecuted(const char[] strConfigFile, TFDBConfig config);

/**
 * Called when an unknown wavetype is encountered. (1, 2 & 3 are in use)
 * 
 * @param iIndex        	Rocket index in ArrayList.
 * @param rocket        	Rocket structure.
 * @param iWavetype     	Wavetype identifier.
 * @param fPhase			Current phase due to distance, number of oscillations already taken into account
 * @param fWaveAmplitude	Amplitude of the wave
 */
forward void TFDB_OnRocketOtherWavetype(int iIndex, Rocket rocket, int iWavetype, float fPhase, float fWaveAmplitude);

/**
 * Called on each game frame for each rocket. (After dragging/turning & before setting velocity)
 * 
 * @param iIndex      Rocket index in ArrayList.
 * @param rocket      Rocket structure.
 */
forward void TFDB_OnRocketGameFrame(int iIndex, Rocket rocket);

// ---- Natives ----------------------------------------

// NOTE:
// any rocket[sizeof(Rocket)] ~= Rocket rocket, workaround, as we cannot use structs directly.
// You can use Rocket rocket when using the function.

/**
 * Checks if the map is a dodgeball map, dodgeball is enabled on dodgeball map.
 * 
 * @return		True if dodgeball map, false otherwise.
 */
native bool TFDB_IsDodgeballEnabled();

/**
 * Checks if the rocket is valid.
 * 
 * @param iRef  Entity reference to rocket.
 * @return      True if valid, false otherwise
 */
native bool TFDB_IsValidRocket(int iRef);

/**
 * Find rocket index from entity.
 * 
 * @param iEntity   Rocket entity.
 * @return          Rocket index in ArrayList, -1 on failure.
 * @error           Invalid entity.
 */
native int TFDB_FindRocketByEntity(int iEntity);

/**
 * Gets rocket structure from index in ArrayList.
 * 
 * @param iIndex    Rocket index in Arraylist.
 * @param rocket    Buffer to store rocket structure in. (you can use Rocket structure!)
 * @return			Returns SP_ERROR_NONE on success, anything else on failure.
 * @error			Invalid index.
 */
native int TFDB_GetRocketByIndex(int iIndex, any rocket[sizeof(Rocket)]);

/**
 * Sets rocket structure using (existing) index in ArrayList.
 * 
 * @param iIndex	Rocket index in Arraylist.
 * @param rocket	Rocket struct to overwrite index in ArrayList with.
 * @return			Returns SP_ERROR_NONE on success, anything else on failure.
 * @error			Invalid index.
 */
native bool TFDB_SetRocketByIndex(int iIndex, any rocket[sizeof(Rocket)]);

/**
 * Gets config currently in use.
 * 
 * @param config    Buffer to store config structure in. (you can use TFDBConfig structure!)
 * @return			Returns SP_ERROR_NONE on success, anything else on failure.	
 */
native int TFDB_GetCurrentConfig(any config[sizeof(TFDBConfig)]);

/**
 * Replaces used config with supplied config.
 * 
 * @param config    TFDBConfig struct to replace config with.
 * @return			Returns SP_ERROR_NONE on success, anything else on failure.
 */
native int TFDB_SetCurrentConfig(any config[sizeof(TFDBConfig)]);

/**
 * Checks if FFA is currently enabled.
 * 
 * @return		True if enabled, false otherwise
 */
native bool TFDB_IsFFAenabled();

/**
 * Checks if NER is currently enabled.
 * 
 * @return		True if enabled, false otherwise
 */
native bool TFDB_IsNERenabled();

public SharedPlugin __pl_TFDB =
{
	name = "tfdb",
	file = "TF2DodgeballUnified.smx",
	
	#if defined REQUIRE_PLUGIN
		required=1,
	#else
		required=0,
	#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_TFDB_SetNTVOptional()
{
	MarkNativeAsOptional("TFDB_IsDodgeballEnabled");
	MarkNativeAsOptional("TFDB_IsValidRocket");
	MarkNativeAsOptional("TFDB_FindRocketByEntity");
	MarkNativeAsOptional("TFDB_GetRocketByIndex");
	MarkNativeAsOptional("TFDB_SetRocketByIndex");
	MarkNativeAsOptional("TFDB_GetCurrentConfig");
	MarkNativeAsOptional("TFDB_SetCurrentConfig");
	MarkNativeAsOptional("TFDB_IsFFAenabled");
	MarkNativeAsOptional("TFDB_IsNERenabled");
}
#endif
