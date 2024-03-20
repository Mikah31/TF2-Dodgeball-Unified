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
	int iTeam;	// You also have to set the entprop if you want to change the rocket's team!

	float fDamage;
	float fSpeed;
	float fTurnrate;

	int iDeflectionCount;
	int iBounces;
	
	float fTimeLastDeflect;
	float fTimeLastBounce;
	float fTimeLastTurn;
	float fTimeInOrbit;

	bool bHasTarget;
	bool bBeingDelayed;
	bool bStolen;
	bool bRecentlyReflected;
	bool bRecentlyBounced;	

	float fDirection[3];
	
	// Starting distance to target, used for calculating phase in wave
	float fWaveDistance;
	float fWaveAmplitude;
	float fWaveOscillations;

	// Used for checking if the rocket is within a certain range (orbitting, waving, etc..)
	// We shouldn't wave in a certain range to target for example
	float RangeToTarget()
	{
		if (!this.bHasTarget) return 0.0;

		static float fTargetPosition[3]; GetClientEyePosition(this.iTarget, fTargetPosition);
		static float fRocketPosition[3]; GetEntPropVector(this.iEntity, Prop_Data, "m_vecOrigin", fRocketPosition);

		return GetVectorDistance(fTargetPosition, fRocketPosition);
	}

	void EmitRocketSound(char[] strPathSound, int iEntitySource = 0)
	{
		if (iEntitySource)
			EmitSoundToAll(strPathSound, iEntitySource); // SOUND_SPAWN / SOUND_SPEEDUP
		else
			EmitSoundToClient(this.iTarget, strPathSound, _, _, _, _, 0.5); // SOUND_ALERT
	}

	// The speed cannot exceed the maximum velocity set in the config, we reflect this in speedometer (although this method is not 100% accurate)
	float SpeedMpH(float fMaxVelocity = 99999.9)
	{
		return this.fSpeed > fMaxVelocity ? fMaxVelocity * 0.042614 : this.fSpeed * 0.042614; // 0.042614 is the conversion factor to MpH in other plugins
	}
}

// ---- Config structure ---------------------------------------

enum struct TFDBConfig
{
	// Formula's
	char strDamageFormula[256]; // gives us an effective max equation length of worst case max ~128 characters due to added spacers
	char strSpeedFormula[256];
	char strTurnrateFormula[256];
	// Waving
	char strWaveAmplitudeFormula[256];
	char strWaveOscillationsFormula[256];
	int iWavetype;

	// Formula clamps
	float fWaveOscillationsMin;
	float fWaveOscillationsMax;
	float fWaveAmplitudeMin;
	float fWaveAmplitudeMax;

	// Special variables a & b, read config
	int iThresholdA;
	int iThresholdB;

	// Turnrate limit
	float fTurnrateLimit;

	// Max velocity;
	float fMaxVelocity;

	// Spiking
	int iSpikingDeflects
	float fSpikingStrength;
	float fSpikingTime;
	float fSpikingMaxTime;

	// Dragging
	float fDragTimeMax;
	float fTurningDelay;

	// Rocket spawning
	int iMaxRockets;
	float fSpawnInterval;
	
	// Bouncing
	bool bDownspikes;
	float fBounceTime;
	int iMaxBounces;

	// Stealing
	int iMaxSteals;
	bool bSoftAntiSteal;
	bool bStolenRocketsDoDamage;
	bool bAnnounceSteals;
	float fWallingDistance;
	
	
	// Orbitting
	float fDelayTime; // Delay time before rocket starts speeding up
	float fOrbitFactor;

	// Airblasting players
	bool bPushPrevention;
	float fPushScale;

	// Airblasting delay
	float fAirblastDelay;

	// Bools
	bool bSpeedometer;
	bool bAirblastTeamRockets;
	bool bDisablePlayerCollisions;
	bool bFFAallowed;
	bool bNeverEndingRoundsAllowed;
	bool bSoloAllowed;

	int iForceNER;

	// Voting timeouts
	float fFFAvotingTimeout;
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

// ---- Macros -----------------------------------------
// Rocket behaviour (can) change within these ranges to target
#define ORBIT_RANGE 	250.0	// We are in orbit inside of this range
#define WAVE_RANGE		300.0	// We wave outside of this range
#define SPIKING_RANGE	550.0	// Spiking outside of this range

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
 * @param iClient	Player hit.
 */
forward void TFDB_OnRocketHitPlayer(int iIndex, Rocket rocket, int iClient);

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
 * Creates a rocket targetting iTeam.
 * 
 * @param iTeam		Target team.
 * @noreturn
 */
native void TFDB_CreateRocket(int iTeam);

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
 * Checks how many rockets are targetting the player.
 * 
 * @return		Number of rockets targetting the client, 0 if error or not a rocket target.
 * @error		Target does not exist.
 */
native int TFDB_NumRocketsTargetting(int iClient);

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
 * Toggles FFA mode.
 * 
 * @noreturn
 */
native void TFDB_ToggleFFA();

/**
 * Checks if NER is currently enabled.
 * 
 * @return		True if enabled, false otherwise
 */
native bool TFDB_IsNERenabled();

/**
 * Toggles NER mode.
 * 
 * @noreturn
 */
native void TFDB_ToggleNER();

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
	MarkNativeAsOptional("TFDB_CreateRocket");
	MarkNativeAsOptional("TFDB_IsValidRocket");
	MarkNativeAsOptional("TFDB_FindRocketByEntity");
	MarkNativeAsOptional("TFDB_GetRocketByIndex");
	MarkNativeAsOptional("TFDB_SetRocketByIndex");
	MarkNativeAsOptional("TFDB_NumRocketsTargetting");
	MarkNativeAsOptional("TFDB_GetCurrentConfig");
	MarkNativeAsOptional("TFDB_SetCurrentConfig");
	MarkNativeAsOptional("TFDB_IsFFAenabled");
	MarkNativeAsOptional("TFDB_ToggleFFA");
	MarkNativeAsOptional("TFDB_IsNERenabled");
	MarkNativeAsOptional("TFDB_ToggleNER");
}
#endif
