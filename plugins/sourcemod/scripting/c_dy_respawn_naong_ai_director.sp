#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <insurgencydy>
#include <insurgency_ad>
#include <smlib>
#undef REQUIRE_EXTENSIONS
#include <cstrike>
#include <tf2>
#include <tf2_stocks>
#define REQUIRE_EXTENSIONS

//Maximum safe entity count
#define MAX_ENTITIES_SAFE 4096

//LUA Healing define values
#define Healthkit_Timer_Tickrate			0.5		// Basic Sound has 0.8 loop
#define Healthkit_Timer_Timeout				360.0 //6 minutes
#define Healthkit_Radius					120.0
#define Revive_Indicator_Radius				100.0

//Lua Healing Variables
int
	g_iBeaconBeam,
	g_iBeaconHalo,
	g_iTimeCheckHeight[MAX_ENTITIES_SAFE] = {0, ...},
	g_healthPack_Amount[MAX_ENTITIES_SAFE] = {0, ...};
float
	g_fLastHeight[2048] = {0.0, ...},
	g_fTimeCheck[2048] = {0.0, ...};

//Intel radio
int RadioGearID = 4;
int g_iPlayerEquipGear;

// This will be used for checking which team the player is on before repsawning them
#define SPECTATOR_TEAM	0
#define TEAM_SPEC	1
#define TEAM_1_SEC	2
#define TEAM_2_INS	3

// Navmesh Init 
#define MAX_OBJECTIVES 13
#define MAX_ENTITIES 2048

//gameme forwards
GlobalForward MedicRevivedForward;

// Handle for revive
Handle g_hForceRespawn;
Handle g_hGameConfig;

// AI Director Variables
int
	g_AIDir_TeamStatus = 50,
	g_AIDir_TeamStatus_min = 0,
	g_AIDir_TeamStatus_max = 100,
	g_AIDir_BotsKilledReq_mult = 4, 
	g_AIDir_BotsKilledCount = 0,
	g_AIDir_ChangeCond_Counter = 0,
	g_AIDir_ChangeCond_Min = 60,
	g_AIDir_ChangeCond_Max = 180,
	g_AIDir_ChangeCond_Rand = 180,
	g_AIDir_ReinforceTimer_Orig,
	g_AIDir_ReinforceTimer_SubOrig,
	g_AIDir_DiffChanceBase = 0;
bool g_AIDir_BotReinforceTriggered = false;

// Player respawn
int
	g_iEnableRevive = 0,
	g_iRespawnTimeRemaining[MAXPLAYERS+1],
	g_iReviveRemainingTime[MAXPLAYERS+1],
	g_iReviveNonMedicRemainingTime[MAXPLAYERS+1],
	g_iPlayerRespawnTimerActive[MAXPLAYERS+1],
	g_iSpawnTokens[MAXPLAYERS+1],
	g_iHurtFatal[MAXPLAYERS+1],
	g_iClientRagdolls[MAXPLAYERS+1],
	g_iNearestBody[MAXPLAYERS+1],
	g_botStaticGlobal[MAXPLAYERS+1],
	g_resupplyCounter[MAXPLAYERS+1],
	g_ammoResupplyAmt[MAX_ENTITIES_SAFE],
	g_iRespawnCount[4],
	g_iPlayerBGroups[MAXPLAYERS+1],
	g_spawnFrandom[MAXPLAYERS+1];

float
	g_fDeadPosition[MAXPLAYERS+1][3],
	g_fDeadAngle[MAXPLAYERS+1][3],
	g_fRagdollPosition[MAXPLAYERS+1][3],
	g_vecOrigin[MAXPLAYERS+1][3],
	g_fRespawnPosition[3];

bool g_playersReady = false;


bool InProgressReviveByMedic[MAXPLAYERS+1] = {false, ...};
int LastTimeCheckedReviveProgress[MAXPLAYERS + 1] = {-1, ...};


//Ammo Amounts
int
	playerClip[MAXPLAYERS + 1][2], // Track primary and secondary ammo
	playerAmmo[MAXPLAYERS + 1][4], // track player ammo based on weapon slot 0 - 4
	playerPrimary[MAXPLAYERS + 1],
	playerSecondary[MAXPLAYERS + 1];

// These steam ids remove from having a donor tag on request
//[1] = 1 STRING, [64] = 40 character limit per string
Handle g_playerArrayList;

//Bot Spawning 
float m_vCPPositions[MAX_OBJECTIVES][3];

// Status
int
	g_isMapInit,
	g_iRoundStatus = 0, //0 is over, 1 is active
	g_clientDamageDone[MAXPLAYERS+1],
	playerPickSquad[MAXPLAYERS + 1],
	g_plyrGrenScreamCoolDown[MAXPLAYERS+1],
	g_plyrFireScreamCoolDown[MAXPLAYERS+1],
	g_playerMedicHealsAccumulated[MAXPLAYERS+1],
	g_playerMedicRevivessAccumulated[MAXPLAYERS+1],
	g_playerNonMedicHealsAccumulated[MAXPLAYERS+1],
	g_playerNonMedicRevive[MAXPLAYERS+1],
	g_playerWoundType[MAXPLAYERS+1],
	g_playerWoundTime[MAXPLAYERS+1];

char g_client_last_classstring[MAXPLAYERS+1][64];
char g_client_org_nickname[MAXPLAYERS+1][64];

float
	g_enemyTimerPos[MAXPLAYERS+1][3],	// Kill Stray Enemy Bots Globals
	g_enemyTimerAwayPos[MAXPLAYERS+1][3];	// Kill Stray Enemy Bots Globals

bool
	g_bIsCounterAttackTimerActive = false,
	playerRevived[MAXPLAYERS + 1],
	playerInRevivedState[MAXPLAYERS + 1],
	g_preRoundInitial = false;

g_playerFirstJoin[MAXPLAYERS+1];

// Player Distance Plugin //Credits to author = "Popoklopsi", url = "http://popoklopsi.de"
// unit to use 1 = feet, 0 = meters
int g_iUnitMetric;

// Handle for config
Handle
	sm_respawn_enabled = null,
	sm_revive_enabled = null,
	
	//AI Director Specific
	sm_ai_director_setdiff_chance_base = null,

	// Respawn delay time
	sm_respawn_delay_team_ins = null,
	sm_respawn_delay_team_ins_special = null,
	sm_respawn_delay_team_sec = null,
	sm_respawn_delay_team_sec_player_count_01 = null,
	sm_respawn_delay_team_sec_player_count_02 = null,
	sm_respawn_delay_team_sec_player_count_03 = null,
	sm_respawn_delay_team_sec_player_count_04 = null,
	sm_respawn_delay_team_sec_player_count_05 = null,
	sm_respawn_delay_team_sec_player_count_06 = null,
	sm_respawn_delay_team_sec_player_count_07 = null,
	sm_respawn_delay_team_sec_player_count_08 = null,
	sm_respawn_delay_team_sec_player_count_09 = null,
	sm_respawn_delay_team_sec_player_count_10 = null,
	sm_respawn_delay_team_sec_player_count_11 = null,
	sm_respawn_delay_team_sec_player_count_12 = null,
	sm_respawn_delay_team_sec_player_count_13 = null,
	sm_respawn_delay_team_sec_player_count_14 = null,
	sm_respawn_delay_team_sec_player_count_15 = null,
	sm_respawn_delay_team_sec_player_count_16 = null,
	sm_respawn_delay_team_sec_player_count_17 = null,
	sm_respawn_delay_team_sec_player_count_18 = null,
	sm_respawn_delay_team_sec_player_count_19 = null,
	sm_respawn_delay_team_sec_player_count_20 = null,

	// Respawn type
	sm_respawn_type_team_ins = null,
	sm_respawn_type_team_sec = null,
	
	// Respawn lives
	sm_respawn_lives_team_sec = null,
	sm_respawn_lives_team_ins = null,
	sm_respawn_lives_team_ins_player_count_01 = null,
	sm_respawn_lives_team_ins_player_count_02 = null,
	sm_respawn_lives_team_ins_player_count_03 = null,
	sm_respawn_lives_team_ins_player_count_04 = null,
	sm_respawn_lives_team_ins_player_count_05 = null,
	sm_respawn_lives_team_ins_player_count_06 = null,
	sm_respawn_lives_team_ins_player_count_07 = null,
	sm_respawn_lives_team_ins_player_count_08 = null,
	sm_respawn_lives_team_ins_player_count_09 = null,
	sm_respawn_lives_team_ins_player_count_10 = null,
	sm_respawn_lives_team_ins_player_count_11 = null,
	sm_respawn_lives_team_ins_player_count_12 = null,
	sm_respawn_lives_team_ins_player_count_13 = null,
	sm_respawn_lives_team_ins_player_count_14 = null,
	sm_respawn_lives_team_ins_player_count_15 = null,
	sm_respawn_lives_team_ins_player_count_16 = null,
	sm_respawn_lives_team_ins_player_count_17 = null,
	sm_respawn_lives_team_ins_player_count_18 = null,
	sm_respawn_lives_team_ins_player_count_19 = null,
	sm_respawn_lives_team_ins_player_count_20 = null,
	
	// Fatal dead
	sm_respawn_fatal_chance = null,
	sm_respawn_fatal_head_chance = null,
	sm_respawn_fatal_limb_dmg = null,
	sm_respawn_fatal_head_dmg = null,
	sm_respawn_fatal_burn_dmg = null,
	sm_respawn_fatal_explosive_dmg = null,
	sm_respawn_fatal_chest_stomach = null,
	
	// Counter-attack
	sm_respawn_counterattack_type = null,
	sm_respawn_counterattack_vanilla = null,
	sm_respawn_final_counterattack_type = null,
	sm_respawn_security_on_counter = null,
	sm_respawn_counter_chance = null,
	sm_respawn_min_counter_dur_sec = null,
	sm_respawn_max_counter_dur_sec = null,
	sm_respawn_final_counter_dur_sec = null,
	
	//Dynamic Respawn Mechanics
	sm_respawn_dynamic_distance_multiplier = null,
	sm_respawn_dynamic_spawn_counter_percent = null,
	sm_respawn_dynamic_spawn_percent = null,

	// Misc
	sm_respawn_reset_type = null,
	sm_respawn_enable_track_ammo = null,
	
	// Reinforcements
	sm_respawn_reinforce_time = null,
	sm_respawn_reinforce_time_subsequent = null,
	sm_respawn_reinforce_multiplier = null,
	sm_respawn_reinforce_multiplier_base = null,
	
	// Monitor static enemy
	sm_respawn_check_static_enemy = null,
	sm_respawn_check_static_enemy_counter = null,
	
	// Donor tag
	sm_respawn_enable_donor_tag = null,

	// Medic specific
	sm_revive_distance_metric = null,
	sm_heal_cap_for_bonus = null,
	sm_revive_cap_for_bonus = null,
	sm_reward_medics_enabled = null,
	sm_heal_amount_medpack = null,
	sm_heal_amount_paddles = null,
	sm_non_medic_heal_amt = null,
	sm_non_medic_revive_hp = null,
	sm_medic_minor_revive_hp = null,
	sm_medic_moderate_revive_hp = null,
	sm_medic_critical_revive_hp = null,
	sm_minor_wound_dmg = null,
	sm_moderate_wound_dmg = null,
	sm_medic_heal_self_max = null,
	sm_non_medic_max_heal_other = null,
	sm_minor_revive_time = null,
	sm_moderate_revive_time = null,
	sm_critical_revive_time = null,
	sm_non_medic_revive_time = null,
	sm_medpack_health_amount = null,
	sm_non_medic_heal_self_max = null,
	sm_elite_counter_attacks = null,
	sm_finale_counter_spec_enabled = null,
	sm_finale_counter_spec_percent = null,
	sm_cqc_map_enabled = null,

	// NAV MESH SPECIFIC CVARS
	cvarMinPlayerDistance = null, //Min/max distance from players to spawn
	cvarBackSpawnIncrease = null, //Adds to the minplayerdistance cvar when spawning behind player.
	cvarSpawnAttackDelay = null, //Attack delay for spawning bots
	cvarMinObjectiveDistance = null, //Min/max distance from next objective to spawn
	cvarCanSeeVectorMultiplier = null, //CanSeeVector Multiplier divide this by cvarMaxPlayerDistance
	sm_ammo_resupply_range = null, //Range of ammo resupply
	sm_resupply_delay = null, //Delay to resupply
	cvarMaxPlayerDistance = null; //Min/max distance from players to spawn


// Init global variables
new
	g_iCvar_respawn_enable,
	g_elite_counter_attacks,
	g_finale_counter_spec_enabled,
	g_finale_counter_spec_percent,
	g_cqc_map_enabled,
	g_iCvar_revive_enable,
	Float:g_respawn_counter_chance,
	g_counterAttack_min_dur_sec,
	g_counterAttack_max_dur_sec,
	g_iCvar_respawn_type_team_ins,
	g_iCvar_respawn_type_team_sec,
	g_iCvar_respawn_reset_type,
	Float:g_fCvar_respawn_delay_team_ins,
	Float:g_fCvar_respawn_delay_team_ins_spec,
	g_iCvar_enable_track_ammo,
	g_iCvar_counterattack_type,
	g_iCvar_counterattack_vanilla,
	g_iCvar_final_counterattack_type;
	
	//Dynamic Respawn cvars 
	float g_DynamicRespawn_Distance_mult;
int
	g_dynamicSpawnCounter_Perc,
	g_dynamicSpawn_Perc;

	// Fatal dead
	float g_fCvar_fatal_chance;
	float g_fCvar_fatal_head_chance;
int
	g_iCvar_fatal_limb_dmg,
	g_iCvar_fatal_head_dmg,
	g_iCvar_fatal_burn_dmg,
	g_iCvar_fatal_explosive_dmg,
	g_iCvar_fatal_chest_stomach,

	//Template of bots AI Director uses
	g_cacheObjActive = 0,
	g_checkStaticAmt,
	g_checkStaticAmtCntr,
	g_checkStaticAmtAway,
	g_checkStaticAmtCntrAway,
	g_iReinforceTime,
	// g_iReinforceTimeSubsequent,
	g_iReinforceTime_AD_Temp,
	g_iReinforceTimeSubsequent_AD_Temp,
	g_iReinforce_Mult,
	g_iReinforce_Mult_Base,
	g_iRemaining_lives_team_sec,
	g_iRemaining_lives_team_ins,
	g_iRespawn_lives_team_sec,
	g_iRespawn_lives_team_ins,
	g_iRespawnSeconds,
	g_secWave_Timer,
	g_iHeal_amount_paddles,
	g_iHeal_amount_medPack,
	g_nonMedicHeal_amount,
	g_nonMedicRevive_hp,
	g_minorWoundRevive_hp,
	g_modWoundRevive_hp,
	g_critWoundRevive_hp,
	g_minorWound_dmg,
	g_moderateWound_dmg,
	g_medicHealSelf_max,
	g_nonMedicHealSelf_max,
	g_nonMedic_maxHealOther,
	g_minorRevive_time,
	g_modRevive_time,
	g_critRevive_time,
	g_nonMedRevive_time,
	g_medpack_health_amt,
	g_botsReady,
	g_isConquer,
	g_isOutpost,
	g_isCheckpoint,
	g_isHunt;
float
	g_flMinPlayerDistance,
	g_flBackSpawnIncrease,
	g_flMaxPlayerDistance,
	g_flCanSeeVectorMultiplier, 
	g_flMinObjectiveDistance,
	g_flSpawnAttackDelay;

	//Elite bots Counters
int
	g_ins_bot_count_checkpoint_max_org,
	g_mp_player_resupply_coop_delay_max_org,
	g_mp_player_resupply_coop_delay_penalty_org,
	g_mp_player_resupply_coop_delay_base_org,
	g_bot_attack_aimpenalty_amt_close_org,
	g_bot_attack_aimpenalty_amt_far_org,
	g_bot_attack_aimpenalty_amt_close_mult,
	g_bot_attack_aimpenalty_amt_far_mult,
	g_coop_delay_penalty_base,
	g_isEliteCounter;
float 
	g_bot_attack_aimpenalty_time_close_org,
	g_bot_attack_aimpenalty_time_far_org,
	g_bot_aim_aimtracking_base_org,
	g_bot_aim_aimtracking_frac_impossible_org,
	g_bot_aim_angularvelocity_frac_impossible_org,
	g_bot_aim_angularvelocity_frac_sprinting_target_org,
	g_bot_aim_attack_aimtolerance_frac_impossible_org,
	g_bot_attackdelay_frac_difficulty_impossible_mult,
	g_bot_attack_aimpenalty_time_close_mult,
	g_bot_attack_aimpenalty_time_far_mult,
	g_bot_aim_aimtracking_base,
	g_bot_aim_aimtracking_frac_impossible,
	g_bot_aim_angularvelocity_frac_impossible,
	g_bot_aim_angularvelocity_frac_sprinting_target,
	g_bot_aim_attack_aimtolerance_frac_impossible,
	g_bot_attackdelay_frac_difficulty_impossible_org,
	g_bot_attack_aimtolerance_newthreat_amt_org,
	g_bot_attack_aimtolerance_newthreat_amt_mult;

enum SpawnModes
{
	SpawnMode_Normal = 0,
	SpawnMode_HidingSpots,
	SpawnMode_SpawnPoints,
};


new m_hMyWeapons, m_flNextPrimaryAttack, m_flNextSecondaryAttack;
/////////////////////////////////////
// Rank System (Based on graczu's Simple CS:S Rank - https://forums.alliedmods.net/showthread.php?p=523601)
//
/*
MySQL Query:

CREATE TABLE `ins_rank`(
`rank_id` int(64) NOT NULL auto_increment,
`steamId` varchar(32) NOT NULL default '',
`nick` varchar(128) NOT NULL default '',
`score` int(12) NOT NULL default '0',
`kills` int(12) NOT NULL default '0',
`deaths` int(12) NOT NULL default '0',
`headshots` int(12) NOT NULL default '0',
`sucsides` int(12) NOT NULL default '0',
`revives` int(12) NOT NULL default '0',
`heals` int(12) NOT NULL default '0',
`last_active` int(12) NOT NULL default '0',
`played_time` int(12) NOT NULL default '0',
PRIMARY KEY	 (`rank_id`)) ENGINE=INNODB	 DEFAULT CHARSET=utf8;

database.cfg

	"insrank"
	{
		"driver"			"default"
		"host"				"127.0.0.1"
		"database"			"database_name"
		"user"				"database_user"
		"pass"				"PASSWORD"
		//"timeout"			"0"
		"port"			"3306"
	}
*/

// KOLOROWE KREDKI 
#define YELLOW 0x01
#define GREEN 0x04


// SOME DEFINES
#define MAX_LINE_WIDTH 60

// STATS TIME (SET DAYS AFTER STATS ARE DELETE OF NONACTIVE PLAYERS)
#define PLAYER_STATSOLD 30

// STATS DEFINATION FOR PLAYERS
new g_iStatRevives[MAXPLAYERS+1];
new g_iStatHeals[MAXPLAYERS+1];

/////////////////////////////////////

#define PLUGIN_VERSION "1.7.1.5"
#define PLUGIN_DESCRIPTION "Respawn dead players via admincommand or by queues"
//#define UPDATE_URL	"http://ins.jballou.com/sourcemod/update-respawn.txt"

// Plugin info
public Plugin:myinfo =
{
	name = "[INS] Player Respawn",
	author = "Jared Ballou (Contributor: Daimyo, naong, and community members)",
	version = PLUGIN_VERSION,
	description = PLUGIN_DESCRIPTION,
	url = "http://jballou.com"
};

// Start plugin
public OnPluginStart()
{
	//gameme stats
	MedicRevivedForward = new GlobalForward("Medic_Revived", ET_Event, Param_Cell, Param_Cell);

	//Total bot count
	RegAdminCmd("totalb", Check_Total_Enemies, ADMFLAG_BAN, "Show the total alive enemies");

	//Find player gear offset
	g_iPlayerEquipGear = FindSendPropInfo("CINSPlayer", "m_EquippedGear");

	//RegConsoleCmd("sm_serverhelp", serverhelp); 
	//Create player array list
	g_playerArrayList = CreateArray();
	//g_badSpawnPos_Array = CreateArray();
	//RegConsoleCmd("kill", cmd_kill);

	RegConsoleCmd("fatal", fatal_cmd, "Set your death to fatal");

	CreateConVar("sm_respawn_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_NOTIFY | FCVAR_DONTRECORD);
	sm_respawn_enabled = CreateConVar("sm_respawn_enabled", "1", "Automatically respawn players when they die; 0 - disabled, 1 - enabled");
	sm_revive_enabled = CreateConVar("sm_revive_enabled", "1", "Reviving enabled from medics?  This creates revivable ragdoll after death; 0 - disabled, 1 - enabled");
	// Nav Mesh Botspawn specific START
	cvarMinPlayerDistance = CreateConVar("sm_botspawns_min_player_distance", "240.0", "Min distance from players to spawn", FCVAR_NOTIFY);
	cvarMaxPlayerDistance = CreateConVar("sm_botspawns_max_player_distance", "16000.0", "Max distance from players to spawn", FCVAR_NOTIFY);
	cvarCanSeeVectorMultiplier = CreateConVar("sm_botpawns_can_see_vect_mult", "1.5", "Divide this with sm_botspawns_max_player_distance to get CanSeeVector allowed distance for bot spawning in LOS", FCVAR_NOTIFY);
	cvarMinObjectiveDistance = CreateConVar("sm_botspawns_min_objective_distance", "240", "Min distance from next objective to spawn", FCVAR_NOTIFY);
	cvarBackSpawnIncrease = CreateConVar("sm_botspawns_backspawn_increase", "1400.0", "Whenever bot spawn on last point, this is added to minimum player respawn distance to avoid spawning too close to player.", FCVAR_NOTIFY);	
	cvarSpawnAttackDelay = CreateConVar("sm_botspawns_spawn_attack_delay", "2", "Delay in seconds for spawning bots to wait before firing.", FCVAR_NOTIFY);

	// Nav Mesh Botspawn specific END

	// Respawn delay time
	sm_respawn_delay_team_ins = CreateConVar("sm_respawn_delay_team_ins", 
		"1.0", "How many seconds to delay the respawn (bots)");
	sm_respawn_delay_team_ins_special = CreateConVar("sm_respawn_delay_team_ins_special", 
		"20.0", "How many seconds to delay the respawn (special bots)");

	sm_respawn_delay_team_sec = CreateConVar("sm_respawn_delay_team_sec", 
		"30.0", "How many seconds to delay the respawn (If not set 'sm_respawn_delay_team_sec_player_count_XX' uses this value)");
	sm_respawn_delay_team_sec_player_count_01 = CreateConVar("sm_respawn_delay_team_sec_player_count_01", 
		"5.0", "How many seconds to delay the respawn (when player count is 1)");
	sm_respawn_delay_team_sec_player_count_02 = CreateConVar("sm_respawn_delay_team_sec_player_count_02", 
		"10.0", "How many seconds to delay the respawn (when player count is 2)");
	sm_respawn_delay_team_sec_player_count_03 = CreateConVar("sm_respawn_delay_team_sec_player_count_03", 
		"20.0", "How many seconds to delay the respawn (when player count is 3)");
	sm_respawn_delay_team_sec_player_count_04 = CreateConVar("sm_respawn_delay_team_sec_player_count_04", 
		"30.0", "How many seconds to delay the respawn (when player count is 4)");
	sm_respawn_delay_team_sec_player_count_05 = CreateConVar("sm_respawn_delay_team_sec_player_count_05", 
		"60.0", "How many seconds to delay the respawn (when player count is 5)");
	sm_respawn_delay_team_sec_player_count_06 = CreateConVar("sm_respawn_delay_team_sec_player_count_06",
		"60.0", "How many seconds to delay the respawn (when player count is 6)");
	sm_respawn_delay_team_sec_player_count_07 = CreateConVar("sm_respawn_delay_team_sec_player_count_07", 
		"70.0", "How many seconds to delay the respawn (when player count is 7)");
	sm_respawn_delay_team_sec_player_count_08 = CreateConVar("sm_respawn_delay_team_sec_player_count_08", 
		"70.0", "How many seconds to delay the respawn (when player count is 8)");
	sm_respawn_delay_team_sec_player_count_09 = CreateConVar("sm_respawn_delay_team_sec_player_count_09", 
		"80.0", "How many seconds to delay the respawn (when player count is 9)");
	sm_respawn_delay_team_sec_player_count_10 = CreateConVar("sm_respawn_delay_team_sec_player_count_10", 
		"80.0", "How many seconds to delay the respawn (when player count is 10)");
	sm_respawn_delay_team_sec_player_count_11 = CreateConVar("sm_respawn_delay_team_sec_player_count_11", 
		"90.0", "How many seconds to delay the respawn (when player count is 11)");
	sm_respawn_delay_team_sec_player_count_12 = CreateConVar("sm_respawn_delay_team_sec_player_count_12", 
		"90.0", "How many seconds to delay the respawn (when player count is 12)");
	sm_respawn_delay_team_sec_player_count_13 = CreateConVar("sm_respawn_delay_team_sec_player_count_13", 
		"100.0", "How many seconds to delay the respawn (when player count is 13)");
	sm_respawn_delay_team_sec_player_count_14 = CreateConVar("sm_respawn_delay_team_sec_player_count_14", 
		"100.0", "How many seconds to delay the respawn (when player count is 14)");
	sm_respawn_delay_team_sec_player_count_15 = CreateConVar("sm_respawn_delay_team_sec_player_count_15", 
		"110.0", "How many seconds to delay the respawn (when player count is 15)");
	sm_respawn_delay_team_sec_player_count_16 = CreateConVar("sm_respawn_delay_team_sec_player_count_16", 
		"110.0", "How many seconds to delay the respawn (when player count is 16)");
	sm_respawn_delay_team_sec_player_count_17 = CreateConVar("sm_respawn_delay_team_sec_player_count_17", 
		"120.0", "How many seconds to delay the respawn (when player count is 17)");
	sm_respawn_delay_team_sec_player_count_18 = CreateConVar("sm_respawn_delay_team_sec_player_count_18", 
		"120.0", "How many seconds to delay the respawn (when player count is 18)");
	sm_respawn_delay_team_sec_player_count_19 = CreateConVar("sm_respawn_delay_team_sec_player_count_19", 
		"130.0", "How many seconds to delay the respawn (when player count is 19)");
	sm_respawn_delay_team_sec_player_count_20 = CreateConVar("sm_respawn_delay_team_sec_player_count_20", 
		"130.0", "How many seconds to delay the respawn (when player count is 20)");
	
	// Respawn type
	sm_respawn_type_team_sec = CreateConVar("sm_respawn_type_team_sec", 
		"1", "1 - individual lives, 2 - each team gets a pool of lives used by everyone, sm_respawn_lives_team_sec must be > 0");
	sm_respawn_type_team_ins = CreateConVar("sm_respawn_type_team_ins", 
		"2", "1 - individual lives, 2 - each team gets a pool of lives used by everyone, sm_respawn_lives_team_ins must be > 0");
	
	// Respawn lives
	sm_respawn_lives_team_sec = CreateConVar("sm_respawn_lives_team_sec", 
		"-1", "Respawn players this many times (-1: Disables player respawn)");
	sm_respawn_lives_team_ins = CreateConVar("sm_respawn_lives_team_ins", 
		"10", "If 'sm_respawn_type_team_ins' set 1, respawn bots this many times. If 'sm_respawn_type_team_ins' set 2, total bot count (If not set 'sm_respawn_lives_team_ins_player_count_XX' uses this value)");
	sm_respawn_lives_team_ins_player_count_01 = CreateConVar("sm_respawn_lives_team_ins_player_count_01", 
		"5", "Total bot count (when player count is 1)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_02 = CreateConVar("sm_respawn_lives_team_ins_player_count_02", 
		"10", "Total bot count (when player count is 2)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_03 = CreateConVar("sm_respawn_lives_team_ins_player_count_03", 
		"15", "Total bot count (when player count is 3)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_04 = CreateConVar("sm_respawn_lives_team_ins_player_count_04", 
		"20", "Total bot count (when player count is 4)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_05 = CreateConVar("sm_respawn_lives_team_ins_player_count_05", 
		"25", "Total bot count (when player count is 5)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_06 = CreateConVar("sm_respawn_lives_team_ins_player_count_06", 
		"30", "Total bot count (when player count is 6)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_07 = CreateConVar("sm_respawn_lives_team_ins_player_count_07", 
		"35", "Total bot count (when player count is 7)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_08 = CreateConVar("sm_respawn_lives_team_ins_player_count_08", 
		"40", "Total bot count (when player count is 8)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_09 = CreateConVar("sm_respawn_lives_team_ins_player_count_09", 
		"45", "Total bot count (when player count is 9)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_10 = CreateConVar("sm_respawn_lives_team_ins_player_count_10", 
		"50", "Total bot count (when player count is 10)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_11 = CreateConVar("sm_respawn_lives_team_ins_player_count_11", 
		"55", "Total bot count (when player count is 11)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_12 = CreateConVar("sm_respawn_lives_team_ins_player_count_12", 
		"60", "Total bot count (when player count is 12)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_13 = CreateConVar("sm_respawn_lives_team_ins_player_count_13", 
		"65", "Total bot count (when player count is 13)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_14 = CreateConVar("sm_respawn_lives_team_ins_player_count_14", 
		"70", "Total bot count (when player count is 14)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_15 = CreateConVar("sm_respawn_lives_team_ins_player_count_15", 
		"75", "Total bot count (when player count is 15)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_16 = CreateConVar("sm_respawn_lives_team_ins_player_count_16", 
		"80", "Total bot count (when player count is 16)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_17 = CreateConVar("sm_respawn_lives_team_ins_player_count_17", 
		"85", "Total bot count (when player count is 17)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_18 = CreateConVar("sm_respawn_lives_team_ins_player_count_18", 
		"90", "Total bot count (when player count is 18)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_19 = CreateConVar("sm_respawn_lives_team_ins_player_count_19", 
		"95", "Total bot count (when player count is 19)(sm_respawn_type_team_ins must be 2)");
	sm_respawn_lives_team_ins_player_count_20 = CreateConVar("sm_respawn_lives_team_ins_player_count_20", 
		"100", "Total bot count (when player count is 20)(sm_respawn_type_team_ins must be 2)");
	
	// Fatally death
	sm_respawn_fatal_chance = CreateConVar("sm_respawn_fatal_chance", "0.20", "Chance for a kill to be fatal, 0.6 default = 60% chance to be fatal (To disable set 0.0)");
	sm_respawn_fatal_head_chance = CreateConVar("sm_respawn_fatal_head_chance", "0.30", "Chance for a headshot kill to be fatal, 0.6 default = 60% chance to be fatal");
	sm_respawn_fatal_limb_dmg = CreateConVar("sm_respawn_fatal_limb_dmg", "80", "Amount of damage to fatally kill player in limb");
	sm_respawn_fatal_head_dmg = CreateConVar("sm_respawn_fatal_head_dmg", "100", "Amount of damage to fatally kill player in head");
	sm_respawn_fatal_burn_dmg = CreateConVar("sm_respawn_fatal_burn_dmg", "50", "Amount of damage to fatally kill player in burn");
	sm_respawn_fatal_explosive_dmg = CreateConVar("sm_respawn_fatal_explosive_dmg", "200", "Amount of damage to fatally kill player in explosive");
	sm_respawn_fatal_chest_stomach = CreateConVar("sm_respawn_fatal_chest_stomach", "100", "Amount of damage to fatally kill player in chest/stomach");
	
	// Counter attack
	sm_respawn_counter_chance = CreateConVar("sm_respawn_counter_chance", "0.5", "Percent chance that a counter attack will happen def: 50%");
	sm_respawn_counterattack_type = CreateConVar("sm_respawn_counterattack_type", "2", "Respawn during counterattack? (0: no, 1: yes, 2: infinite)");
	sm_respawn_final_counterattack_type = CreateConVar("sm_respawn_final_counterattack_type", "2", "Respawn during final counterattack? (0: no, 1: yes, 2: infinite)");
	sm_respawn_security_on_counter = CreateConVar("sm_respawn_security_on_counter", "1", "0/1 When a counter attack starts, spawn all dead players and teleport them to point to defend");
	sm_respawn_min_counter_dur_sec = CreateConVar("sm_respawn_min_counter_dur_sec", "66", "Minimum randomized counter attack duration");
	sm_respawn_max_counter_dur_sec = CreateConVar("sm_respawn_max_counter_dur_sec", "126", "Maximum randomized counter attack duration");
	sm_respawn_final_counter_dur_sec = CreateConVar("sm_respawn_final_counter_dur_sec", "180", "Final counter attack duration");
	sm_respawn_counterattack_vanilla = CreateConVar("sm_respawn_counterattack_vanilla", "0", "Use vanilla counter attack mechanics? (0: no, 1: yes)");
	
	//Dynamic respawn mechanicss
	sm_respawn_dynamic_distance_multiplier = CreateConVar("sm_respawn_dynamic_distance_multiplier", "2.0", "This multiplier is used to make bot distance from points on/off counter attacks more dynamic by making distance closer/farther when bots respawn");
	sm_respawn_dynamic_spawn_counter_percent = CreateConVar("sm_respawn_dynamic_spawn_counter_percent", "40", "Percent of bots that will spawn farther away on a counter attack (basically their more ideal normal spawns)");
	sm_respawn_dynamic_spawn_percent = CreateConVar("sm_respawn_dynamic_spawn_percent", "5", "Percent of bots that will spawn farther away NOT on a counter (basically their more ideal normal spawns)");
	
	// Misc
	sm_respawn_reset_type = CreateConVar("sm_respawn_reset_type", "0", "Set type of resetting player respawn counts: each round or each objective (0: each round, 1: each objective)");
	sm_respawn_enable_track_ammo = CreateConVar("sm_respawn_enable_track_ammo", "1", "0/1 Track ammo on death to revive (may be buggy if using a different theatre that modifies ammo)");
	
	// Reinforcements
	sm_respawn_reinforce_time = CreateConVar("sm_respawn_reinforce_time", "200", "When enemy forces are low on lives, how much time til they get reinforcements?");
	sm_respawn_reinforce_time_subsequent = CreateConVar("sm_respawn_reinforce_time_subsequent", "140", "When enemy forces are low on lives and already reinforced, how much time til they get reinforcements on subsequent reinforcement?");
	sm_respawn_reinforce_multiplier = CreateConVar("sm_respawn_reinforce_multiplier", "4", "Division multiplier to determine when to start reinforce timer for bots based on team pool lives left over");
	sm_respawn_reinforce_multiplier_base = CreateConVar("sm_respawn_reinforce_multiplier_base", "10", "This is the base int number added to the division multiplier, so (10 * reinforce_mult + base_mult)");

	// Control static enemy
	sm_respawn_check_static_enemy = CreateConVar("sm_respawn_check_static_enemy", "120", "Seconds amount to check if an AI has moved probably stuck");
	sm_respawn_check_static_enemy_counter = CreateConVar("sm_respawn_check_static_enemy_counter", "10", "Seconds amount to check if an AI has moved during counter");
	
	// Donor tag
	sm_respawn_enable_donor_tag = CreateConVar("sm_respawn_enable_donor_tag", "1", "If player has an access to reserved slot, add [DONOR] tag.");
	
	// Medic Revive
	sm_revive_distance_metric = CreateConVar("sm_revive_distance_metric", "1", "Distance metric (0: meters / 1: feet)");
	sm_heal_cap_for_bonus = CreateConVar("sm_heal_cap_for_bonus", "5000", "Amount of health given to other players to gain a life");
	sm_revive_cap_for_bonus = CreateConVar("sm_revive_cap_for_bonus", "50", "Amount of revives before medic gains a life");
	sm_reward_medics_enabled = CreateConVar("sm_reward_medics_enabled", "1", "Enabled rewarding medics with lives? 0 = no, 1 = yes");
	sm_heal_amount_medpack = CreateConVar("sm_heal_amount_medpack", "5", "Heal amount per 0.5 seconds when using medpack");
	sm_heal_amount_paddles = CreateConVar("sm_heal_amount_paddles", "3", "Heal amount per 0.5 seconds when using paddles");
	
	sm_non_medic_heal_amt = CreateConVar("sm_non_medic_heal_amt", "2", "Heal amount per 0.5 seconds when non-medic");
	sm_non_medic_revive_hp = CreateConVar("sm_non_medic_revive_hp", "10", "Health given to target revive when non-medic reviving");
	sm_medic_minor_revive_hp = CreateConVar("sm_medic_minor_revive_hp", "75", "Health given to target revive when medic reviving minor wound");
	sm_medic_moderate_revive_hp = CreateConVar("sm_medic_moderate_revive_hp", "50", "Health given to target revive when medic reviving moderate wound");
	sm_medic_critical_revive_hp = CreateConVar("sm_medic_critical_revive_hp", "25", "Health given to target revive when medic reviving critical wound");
	sm_minor_wound_dmg = CreateConVar("sm_minor_wound_dmg", "100", "Any amount of damage <= to this is considered a minor wound when killed");
	sm_moderate_wound_dmg = CreateConVar("sm_moderate_wound_dmg", "200", "Any amount of damage <= to this is considered a minor wound when killed.	Anything greater is CRITICAL");
	sm_medic_heal_self_max = CreateConVar("sm_medic_heal_self_max", "75", "Max medic can heal self to with med pack");
	sm_non_medic_heal_self_max = CreateConVar("sm_non_medic_heal_self_max", "25", "Max non-medic can heal self to with med pack");
	sm_non_medic_max_heal_other = CreateConVar("sm_non_medic_max_heal_other", "25", "Heal amount per 0.5 seconds when using paddles");
	sm_minor_revive_time = CreateConVar("sm_minor_revive_time", "4", "Seconds it takes medic to revive minor wounded");
	sm_moderate_revive_time = CreateConVar("sm_moderate_revive_time", "7", "Seconds it takes medic to revive moderate wounded");
	sm_critical_revive_time = CreateConVar("sm_critical_revive_time", "10", "Seconds it takes medic to revive critical wounded");
	sm_non_medic_revive_time = CreateConVar("sm_non_medic_revive_time", "30", "Seconds it takes non-medic to revive minor wounded, requires medpack");
	sm_medpack_health_amount = CreateConVar("sm_medpack_health_amount", "500", "Amount of health a deployed healthpack has");
	sm_ammo_resupply_range = CreateConVar("sm_ammo_resupply_range", "80", "Range to resupply near ammo cache");
	sm_resupply_delay = CreateConVar("sm_resupply_delay", "5", "Delay loop for resupply ammo");
	sm_elite_counter_attacks = CreateConVar("sm_elite_counter_attacks", "1", "Enable increased bot skills, numbers on counters?");

	//Specialized Counter
	sm_finale_counter_spec_enabled = CreateConVar("sm_finale_counter_spec_enabled", "0", "Enable specialized finale spawn percent? 1|0");
	sm_finale_counter_spec_percent = CreateConVar("sm_finale_counter_spec_percent", "40", "What specialized finale counter percent for this map?");
	sm_cqc_map_enabled = CreateConVar("sm_cqc_map_enabled", "0", "Is this a cqc map? 0|1 no|yes");

	//AI Director cvars
	sm_ai_director_setdiff_chance_base = CreateConVar("sm_ai_director_setdiff_chance_base", "10", "Base AI Director Set Hard Difficulty Chance");

	CreateConVar("Lua_Ins_Healthkit", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_NOTIFY | FCVAR_DONTRECORD);
	

	if ((m_hMyWeapons = FindSendPropInfo("CBasePlayer", "m_hMyWeapons")) == -1) {
		SetFailState("Fatal Error: Unable to find property offset \"CBasePlayer::m_hMyWeapons\" !");
	}

	if ((m_flNextPrimaryAttack = FindSendPropInfo("CBaseCombatWeapon", "m_flNextPrimaryAttack")) == -1) {
		SetFailState("Fatal Error: Unable to find property offset \"CBaseCombatWeapon::m_flNextPrimaryAttack\" !");
	}

	if ((m_flNextSecondaryAttack = FindSendPropInfo("CBaseCombatWeapon", "m_flNextSecondaryAttack")) == -1) {
		SetFailState("Fatal Error: Unable to find property offset \"CBaseCombatWeapon::m_flNextSecondaryAttack\" !");
	}

	// Add admin respawn console command
	RegAdminCmd("sm_respawn", Command_Respawn, ADMFLAG_SLAY, "sm_respawn <#userid|name>");
	
	// Add reload config console command for admin
	RegAdminCmd("sm_respawn_reload", Command_Reload, ADMFLAG_SLAY, "sm_respawn_reload");
	
	// Event hooking
	//Lua Specific
	HookEvent("grenade_thrown", Event_GrenadeThrown);

	// //For ins_spawnpoint spawning
	HookEvent("player_spawn", Event_Spawn);
	HookEvent("player_spawn", Event_SpawnPost, EventHookMode_Post);

	HookEvent("player_hurt", Event_PlayerHurt_Pre, EventHookMode_Pre);
	HookEvent("player_death", Event_PlayerDeath_Pre, EventHookMode_Pre);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("round_end", Event_RoundEnd_Pre, EventHookMode_Pre);
	HookEvent("player_pick_squad", Event_PlayerPickSquad_Post, EventHookMode_Post);
	HookEvent("object_destroyed", Event_ObjectDestroyed_Pre, EventHookMode_Pre);
	HookEvent("object_destroyed", Event_ObjectDestroyed);
	HookEvent("object_destroyed", Event_ObjectDestroyed_Post, EventHookMode_Post);
	HookEvent("controlpoint_captured", Event_ControlPointCaptured_Pre, EventHookMode_Pre);
	HookEvent("controlpoint_captured", Event_ControlPointCaptured);
	HookEvent("controlpoint_captured", Event_ControlPointCaptured_Post, EventHookMode_Post);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
	HookEvent("player_connect", Event_PlayerConnect);
	HookEvent("game_end", Event_GameEnd, EventHookMode_PostNoCopy);
	HookEvent("player_team", Event_PlayerTeam);
	
	// Revive/Heal specific
	HookConVarChange(sm_heal_amount_medpack, CvarChange);

	HookConVarChange(sm_non_medic_heal_amt, CvarChange);
	HookConVarChange(sm_non_medic_revive_hp, CvarChange);
	HookConVarChange(sm_medic_minor_revive_hp, CvarChange);
	HookConVarChange(sm_medic_moderate_revive_hp, CvarChange);
	HookConVarChange(sm_medic_critical_revive_hp, CvarChange);
	HookConVarChange(sm_minor_wound_dmg, CvarChange);
	HookConVarChange(sm_moderate_wound_dmg, CvarChange);
	HookConVarChange(sm_medic_heal_self_max, CvarChange);
	HookConVarChange(sm_non_medic_heal_self_max, CvarChange);
	HookConVarChange(sm_non_medic_max_heal_other, CvarChange);
	HookConVarChange(sm_minor_revive_time, CvarChange);
	HookConVarChange(sm_moderate_revive_time, CvarChange);
	HookConVarChange(sm_critical_revive_time, CvarChange);
	HookConVarChange(sm_non_medic_revive_time, CvarChange);
	HookConVarChange(sm_medpack_health_amount, CvarChange);
	// Respawn specific
	HookConVarChange(sm_respawn_enabled, EnableChanged);
	HookConVarChange(sm_revive_enabled, EnableChanged);
	HookConVarChange(sm_respawn_delay_team_sec, CvarChange);
	HookConVarChange(sm_respawn_delay_team_ins, CvarChange);
	HookConVarChange(sm_respawn_delay_team_ins_special, CvarChange);
	HookConVarChange(sm_respawn_lives_team_sec, CvarChange);
	HookConVarChange(sm_respawn_lives_team_ins, CvarChange);
	HookConVarChange(sm_respawn_reset_type, CvarChange);
	HookConVarChange(sm_respawn_type_team_sec, CvarChange);
	HookConVarChange(sm_respawn_type_team_ins, CvarChange);
	HookConVarChange(cvarMinPlayerDistance,CvarChange);
	HookConVarChange(cvarBackSpawnIncrease,CvarChange);
	HookConVarChange(cvarMaxPlayerDistance,CvarChange);
	HookConVarChange(cvarCanSeeVectorMultiplier,CvarChange);
	HookConVarChange(cvarMinObjectiveDistance,CvarChange);
	//Dynamic respawning
	HookConVarChange(sm_respawn_dynamic_distance_multiplier,CvarChange);
	HookConVarChange(sm_respawn_dynamic_spawn_counter_percent,CvarChange);
	HookConVarChange(sm_respawn_dynamic_spawn_percent,CvarChange);

	 //Reinforce Timer
	HookConVarChange(sm_respawn_reinforce_multiplier,CvarChange);
	HookConVarChange(sm_respawn_reinforce_multiplier_base,CvarChange);
	
	// Tags
	HookConVarChange(FindConVar("sv_tags"), TagsChanged);
	
	//Other
	HookConVarChange(sm_elite_counter_attacks, CvarChange);
	HookConVarChange(sm_finale_counter_spec_enabled, CvarChange);
	HookConVarChange(sm_ai_director_setdiff_chance_base, CvarChange);
	HookConVarChange(sm_finale_counter_spec_percent, CvarChange);
	// Init respawn function
	// Next 14 lines of text are taken from Andersso's DoDs respawn plugin. Thanks :)
	g_hGameConfig = LoadGameConfigFile("insurgency.games");
	
	if (g_hGameConfig == INVALID_HANDLE)
		SetFailState("Fatal Error: Missing File \"insurgency.games\"!");

	StartPrepSDKCall(SDKCall_Player);
	decl String:game[40];
	GetGameFolderName(game, sizeof(game));
	if (StrEqual(game, "insurgency")) {
		//PrintToServer("[RESPAWN] ForceRespawn for Insurgency");
		PrepSDKCall_SetFromConf(g_hGameConfig, SDKConf_Signature, "ForceRespawn");
	}
	if (StrEqual(game, "doi")) {
		//PrintToServer("[RESPAWN] ForceRespawn for DoI");
		PrepSDKCall_SetFromConf(g_hGameConfig, SDKConf_Virtual, "ForceRespawn");
	}
	g_hForceRespawn = EndPrepSDKCall();
	if (g_hForceRespawn == INVALID_HANDLE) {
		SetFailState("Fatal Error: Unable to find signature for \"ForceRespawn\"!");
	}
	//Load localization file
	LoadTranslations("common.phrases");
	LoadTranslations("respawn.phrases");
	LoadTranslations("nearest_player.phrases.txt");
	
	//Uncomment this code and SQL code below to utilize rank system (youll need to setup yourself.)
	/////////////////////////
	// Rank System
	//("say", Command_Say);			// Monitor say 
	//SQL_TConnect(LoadMySQLBase, "insrank");		// Connect to DB
	//
	/////////////////////////
	
	AutoExecConfig(true, "plugin.respawn");
}

//End Plugin
public OnPluginEnd()
{
	new ent = -1;
	while ((ent = FindEntityByClassname(ent, "healthkit")) > MaxClients && IsValidEntity(ent))
	{
		StopSound(ent, SNDCHAN_VOICE, "Lua_sounds/healthkit_healing.wav");
		AcceptEntityInput(ent, "Kill");
	}
}

// Init config
public OnConfigsExecuted()
{
	if (GetConVarBool(sm_respawn_enabled))
		TagsCheck("respawntimes");
	else
		TagsCheck("respawntimes", true);
}

// When cvar changed
public EnableChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	new intNewValue = StringToInt(newValue);
	new intOldValue = StringToInt(oldValue);

	if(intNewValue == 1 && intOldValue == 0)
	{
		TagsCheck("respawntimes");
		//HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	}
	else if(intNewValue == 0 && intOldValue == 1)
	{
		TagsCheck("respawntimes", true);
		//UnhookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	}
}

// When cvar changed
public CvarChange(Handle:cvar, const String:oldvalue[], const String:newvalue[])
{
	UpdateRespawnCvars();
}

// Update cvars
void UpdateRespawnCvars()
{
	//Counter attack chance based on number of points
	g_respawn_counter_chance = GetConVarFloat(sm_respawn_counter_chance);

	g_counterAttack_min_dur_sec = GetConVarInt(sm_respawn_min_counter_dur_sec);
	g_counterAttack_max_dur_sec = GetConVarInt(sm_respawn_max_counter_dur_sec);
	// The number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");

	if (ncp < 6)
	{
		//Add to minimum dur as well.
		new fRandomInt = GetRandomInt(15, 30);
		new fRandomInt2 = GetRandomInt(6, 12);
		g_counterAttack_min_dur_sec += fRandomInt;
		g_counterAttack_max_dur_sec += fRandomInt2;
		g_respawn_counter_chance += 0.2;
	}
	else if (ncp >= 6 && ncp <= 8)
	{
		//Add to minimum dur as well.
		new fRandomInt = GetRandomInt(10, 20);
		new fRandomInt2 = GetRandomInt(4, 8);
		g_counterAttack_min_dur_sec += fRandomInt;
		g_counterAttack_max_dur_sec += fRandomInt2;
		g_respawn_counter_chance += 0.1;
	}

	g_elite_counter_attacks = GetConVarInt(sm_elite_counter_attacks);
	g_finale_counter_spec_enabled = GetConVarInt(sm_finale_counter_spec_enabled);
	g_finale_counter_spec_percent = GetConVarInt(sm_finale_counter_spec_percent);

	//Ai Director UpdateCvar
	g_AIDir_DiffChanceBase = GetConVarInt(sm_ai_director_setdiff_chance_base);
	
	// Respawn type 1 //TEAM_1_SEC == Index 2 and TEAM_2_INS == Index 3
	g_iRespawnCount[2] = GetConVarInt(sm_respawn_lives_team_sec);
	g_iRespawnCount[3] = GetConVarInt(sm_respawn_lives_team_ins);

	// Type of resetting respawn token, Non-checkpoint modes get set to 0 automatically
	g_iCvar_respawn_reset_type = GetConVarInt(sm_respawn_reset_type);

	if(g_isCheckpoint == 0)
		g_iCvar_respawn_reset_type = 0;

	// Update Cvars
	g_iCvar_respawn_enable = GetConVarInt(sm_respawn_enabled);
	g_iCvar_revive_enable = GetConVarInt(sm_revive_enabled);

	// Bot spawn mode
	g_iReinforce_Mult = GetConVarInt(sm_respawn_reinforce_multiplier);
	g_iReinforce_Mult_Base = GetConVarInt(sm_respawn_reinforce_multiplier_base);
	
	// Tracking ammo
	g_iCvar_enable_track_ammo = GetConVarInt(sm_respawn_enable_track_ammo);
	
	// Respawn type
	g_iCvar_respawn_type_team_ins = GetConVarInt(sm_respawn_type_team_ins);
	g_iCvar_respawn_type_team_sec = GetConVarInt(sm_respawn_type_team_sec);
	
	
	//Dynamic Respawns
	g_DynamicRespawn_Distance_mult = GetConVarFloat(sm_respawn_dynamic_distance_multiplier);
	g_dynamicSpawnCounter_Perc = GetConVarInt(sm_respawn_dynamic_spawn_counter_percent);
	g_dynamicSpawn_Perc = GetConVarInt(sm_respawn_dynamic_spawn_percent);
	
	// Heal Amount
	g_iHeal_amount_medPack = GetConVarInt(sm_heal_amount_medpack);
	g_iHeal_amount_paddles = GetConVarInt(sm_heal_amount_paddles);
	g_nonMedicHeal_amount = GetConVarInt(sm_non_medic_heal_amt);
	
	//HP when revived from wound
	g_nonMedicRevive_hp = GetConVarInt(sm_non_medic_revive_hp);
	g_minorWoundRevive_hp = GetConVarInt(sm_medic_minor_revive_hp);
	g_modWoundRevive_hp = GetConVarInt(sm_medic_moderate_revive_hp);
	g_critWoundRevive_hp = GetConVarInt(sm_medic_critical_revive_hp);

	//New Revive Mechanics
	g_minorWound_dmg = GetConVarInt(sm_minor_wound_dmg);
	g_moderateWound_dmg = GetConVarInt(sm_moderate_wound_dmg);
	g_medicHealSelf_max = GetConVarInt(sm_medic_heal_self_max);
	g_nonMedicHealSelf_max = GetConVarInt(sm_non_medic_heal_self_max);
	g_nonMedic_maxHealOther = GetConVarInt(sm_non_medic_max_heal_other);
	g_minorRevive_time = GetConVarInt(sm_minor_revive_time);
	g_modRevive_time = GetConVarInt(sm_moderate_revive_time);
	g_critRevive_time = GetConVarInt(sm_critical_revive_time);
	g_nonMedRevive_time = GetConVarInt(sm_non_medic_revive_time);
	g_medpack_health_amt = GetConVarInt(sm_medpack_health_amount);
	// Fatal dead
	g_fCvar_fatal_chance = GetConVarFloat(sm_respawn_fatal_chance);
	g_fCvar_fatal_head_chance = GetConVarFloat(sm_respawn_fatal_head_chance);
	g_iCvar_fatal_limb_dmg = GetConVarInt(sm_respawn_fatal_limb_dmg);
	g_iCvar_fatal_head_dmg = GetConVarInt(sm_respawn_fatal_head_dmg);
	g_iCvar_fatal_burn_dmg = GetConVarInt(sm_respawn_fatal_burn_dmg);
	g_iCvar_fatal_explosive_dmg = GetConVarInt(sm_respawn_fatal_explosive_dmg);
	g_iCvar_fatal_chest_stomach = GetConVarInt(sm_respawn_fatal_chest_stomach);

	// Nearest body distance metric
	g_iUnitMetric = GetConVarInt(sm_revive_distance_metric);
	
	// Set respawn delay time
	g_iRespawnSeconds = -1;
	switch (GetTeamSecCount())
	{
		case 0: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_01);
		case 1: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_01);
		case 2: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_02);
		case 3: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_03);
		case 4: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_04);
		case 5: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_05);
		case 6: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_06);
		case 7: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_07);
		case 8: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_08);
		case 9: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_09);
		case 10: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_10);
		case 11: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_11);
		case 12: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_12);
		case 13: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_13);
		case 14: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_14);
		case 15: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_15);
		case 16: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_16);
		case 17: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_17);
		case 18: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_18);
		case 19: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_19);
		case 20: g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec_player_count_20);
	}
	// If not set use default
	if (g_iRespawnSeconds == -1)
		g_iRespawnSeconds = GetConVarInt(sm_respawn_delay_team_sec);

	// Respawn type 2 for players
	if (g_iCvar_respawn_type_team_sec == 2)
		g_iRespawn_lives_team_sec = GetConVarInt(sm_respawn_lives_team_sec);

	// Respawn type 2 for bots
	else if (g_iCvar_respawn_type_team_ins == 2)
	{
		// Set base value of remaining lives for team insurgent
		g_iRespawn_lives_team_ins = -1;
		switch (GetTeamSecCount())
		{
			case 0: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_01);
			case 1: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_01);
			case 2: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_02);
			case 3: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_03);
			case 4: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_04);
			case 5: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_05);
			case 6: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_06);
			case 7: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_07);
			case 8: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_08);
			case 9: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_09);
			case 10: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_10);
			case 11: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_11);
			case 12: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_12);
			case 13: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_13);
			case 14: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_14);
			case 15: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_15);
			case 16: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_16);
			case 17: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_17);
			case 18: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_18);
			case 19: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_19);
			case 20: g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins_player_count_20);
		}
		
		// If not set, use default
		if (g_iRespawn_lives_team_ins == -1)
			g_iRespawn_lives_team_ins = GetConVarInt(sm_respawn_lives_team_ins);
	}
	
	// Counter attack
	g_flCanSeeVectorMultiplier = GetConVarFloat(cvarCanSeeVectorMultiplier);
	g_iCvar_counterattack_type = GetConVarInt(sm_respawn_counterattack_type);
	g_iCvar_counterattack_vanilla = GetConVarInt(sm_respawn_counterattack_vanilla);
	g_iCvar_final_counterattack_type = GetConVarInt(sm_respawn_final_counterattack_type);
	g_flMinPlayerDistance = GetConVarFloat(cvarMinPlayerDistance);
	g_flBackSpawnIncrease = GetConVarFloat(cvarBackSpawnIncrease);
	g_flMaxPlayerDistance = GetConVarFloat(cvarMaxPlayerDistance);

	g_flMinObjectiveDistance = GetConVarFloat(cvarMinObjectiveDistance);
	g_flSpawnAttackDelay = GetConVarFloat(cvarSpawnAttackDelay);

	//Hunt specific
	if (g_isHunt == 1)
	{
		
		new secTeamCount = GetTeamSecCount();
		//Increase reinforcements
		g_iRespawn_lives_team_ins = ((g_iRespawn_lives_team_ins * secTeamCount) / 4);
	}
}

// When tags changed
public TagsChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (GetConVarBool(sm_respawn_enabled))
		TagsCheck("respawntimes");
	else
		TagsCheck("respawntimes", true);
}

// On map starts, call initalizing function
public OnMapStart()
{	
	//Supply points based on control points
	//int tsupply_base = 2;
	//new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	//tsupply_base += (ncp * 2);
	//tsupply_base = (22);
	//new Handle:hSupplyBase = FindConVar("mp_supply_token_base");
	//SetConVarInt(hSupplyBase, tsupply_base, true, false);

	ServerCommand("exec betterbots.cfg");
	//Clear player array
	ClearArray(g_playerArrayList);


	//Wait until players ready to enable spawn checking
	g_playersReady = false;
	g_botsReady = 0;
	//Lua onmap start
	g_iBeaconBeam = PrecacheModel("sprites/laserbeam.vmt");
	g_iBeaconHalo = PrecacheModel("sprites/halo01.vmt");

	// Destory, Flip sounds
	PrecacheSound("soundscape/emitters/oneshot/radio_explode.ogg");
	PrecacheSound("ui/sfx/cl_click.wav");
	// Deploying sounds
	PrecacheSound("player/voice/radial/security/leader/unsuppressed/need_backup1.ogg");
	PrecacheSound("player/voice/radial/security/leader/unsuppressed/need_backup2.ogg");
	PrecacheSound("player/voice/radial/security/leader/unsuppressed/need_backup3.ogg");
	PrecacheSound("player/voice/radial/security/leader/unsuppressed/holdposition2.ogg");
	PrecacheSound("player/voice/radial/security/leader/unsuppressed/holdposition3.ogg");
	PrecacheSound("player/voice/radial/security/leader/unsuppressed/moving2.ogg");
	PrecacheSound("player/voice/radial/security/leader/suppressed/backup3.ogg");
	PrecacheSound("player/voice/radial/security/leader/suppressed/holdposition1.ogg");
	PrecacheSound("player/voice/radial/security/leader/suppressed/holdposition2.ogg");
	PrecacheSound("player/voice/radial/security/leader/suppressed/holdposition3.ogg");
	PrecacheSound("player/voice/radial/security/leader/suppressed/holdposition4.ogg");
	PrecacheSound("player/voice/radial/security/leader/suppressed/moving3.ogg");
	PrecacheSound("player/voice/radial/security/leader/suppressed/ontheway1.ogg");
	PrecacheSound("player/voice/security/command/leader/located4.ogg");
	PrecacheSound("player/voice/security/command/leader/setwaypoint1.ogg");
	PrecacheSound("player/voice/security/command/leader/setwaypoint2.ogg");
	PrecacheSound("player/voice/security/command/leader/setwaypoint3.ogg");
	PrecacheSound("player/voice/security/command/leader/setwaypoint4.ogg");

	PrecacheSound("weapons/universal/uni_crawl_l_01.wav");
	PrecacheSound("weapons/universal/uni_crawl_l_04.wav");
	PrecacheSound("weapons/universal/uni_crawl_l_02.wav");
	PrecacheSound("weapons/universal/uni_crawl_r_03.wav");
	PrecacheSound("weapons/universal/uni_crawl_r_05.wav");
	PrecacheSound("weapons/universal/uni_crawl_r_06.wav");

	//Grenade Call Out
	PrecacheSound("player/voice/botsurvival/leader/incominggrenade9.ogg");
	PrecacheSound("player/voice/botsurvival/subordinate/incominggrenade9.ogg");
	PrecacheSound("player/voice/botsurvival/leader/incominggrenade4.ogg");
	PrecacheSound("player/voice/botsurvival/subordinate/incominggrenade4.ogg");
	PrecacheSound("player/voice/botsurvival/subordinate/incominggrenade35.ogg");
	PrecacheSound("player/voice/botsurvival/subordinate/incominggrenade34.ogg");
	PrecacheSound("player/voice/botsurvival/subordinate/incominggrenade33.ogg");
	PrecacheSound("player/voice/botsurvival/subordinate/incominggrenade23.ogg");
	PrecacheSound("player/voice/botsurvival/leader/incominggrenade2.ogg");
	PrecacheSound("player/voice/botsurvival/leader/incominggrenade13.ogg");
	PrecacheSound("player/voice/botsurvival/leader/incominggrenade12.ogg");
	PrecacheSound("player/voice/botsurvival/leader/incominggrenade11.ogg");
	PrecacheSound("player/voice/botsurvival/leader/incominggrenade10.ogg");
	PrecacheSound("player/voice/botsurvival/leader/incominggrenade18.ogg");

	//Molotov/Incen Callout
	PrecacheSound("player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated7.ogg");
	PrecacheSound("player/voice/responses/security/leader/damage/molotov_incendiary_detonated6.ogg");
	PrecacheSound("player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated6.ogg");
	PrecacheSound("player/voice/responses/security/leader/damage/molotov_incendiary_detonated5.ogg");
	PrecacheSound("player/voice/responses/security/leader/damage/molotov_incendiary_detonated4.ogg");

	//PrecacheSound("sernx_lua_sounds/radio/radio1.ogg");
	//PrecacheSound("sernx_lua_sounds/radio/radio2.ogg");
	//PrecacheSound("sernx_lua_sounds/radio/radio3.ogg");
	//PrecacheSound("sernx_lua_sounds/radio/radio4.ogg");
	//PrecacheSound("sernx_lua_sounds/radio/radio5.ogg");
	//PrecacheSound("sernx_lua_sounds/radio/radio6.ogg");
	//PrecacheSound("sernx_lua_sounds/radio/radio7.ogg");
	//PrecacheSound("sernx_lua_sounds/radio/radio8.ogg");

	//L4D2 defibrillator revive sound
	PrecacheSound("weapons/defibrillator/defibrillator_revive.wav");

    //revive gasp sounds
    /*PrecacheSound("player/focus_gasp.wav");
    PrecacheSound("player/focus_gasp_01.wav");
    PrecacheSound("player/focus_gasp_02.wav");
    PrecacheSound("player/focus_gasp_03.wav");
    PrecacheSound("player/focus_gasp_04.wav");
    PrecacheSound("player/focus_gasp_05.wav");*/

	//Lua sounds
	PrecacheSound("lua_sounds/medic/thx/medic_thanks1.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks2.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks3.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks4.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks5.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks6.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks7.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks8.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks9.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks10.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks11.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks12.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks13.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks14.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks15.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks16.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks17.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks18.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks19.ogg");
	PrecacheSound("lua_sounds/medic/thx/medic_thanks20.ogg");

	/*PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage1.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage2.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage3.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage4.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage5.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage6.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage7.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage8.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage9.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage10.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage11.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage12.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage13.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage14.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage15.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage16.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage17.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage18.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage19.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage20.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage21.ogg");
	PrecacheSound("lua_sounds/medic/letme/medic_letme_bandage22.ogg");*/

	/*PrecacheSound("lua_sounds/medic/healed/medic_healed1.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed2.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed3.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed4.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed5.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed6.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed7.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed8.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed9.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed10.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed11.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed12.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed13.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed14.ogg");*/
	//PrecacheSound("lua_sounds/medic/healed/medic_healed15.ogg");
	/*PrecacheSound("lua_sounds/medic/healed/medic_healed16.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed17.ogg");*/
	//PrecacheSound("lua_sounds/medic/healed/medic_healed18.ogg");
	//PrecacheSound("lua_sounds/medic/healed/medic_healed19.ogg");
	//PrecacheSound("lua_sounds/medic/healed/medic_healed20.ogg");
	/*PrecacheSound("lua_sounds/medic/healed/medic_healed21.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed22.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed23.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed24.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed25.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed26.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed27.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed28.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed29.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed30.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed31.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed32.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed33.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed34.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed35.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed36.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed37.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed38.ogg");
	PrecacheSound("lua_sounds/medic/healed/medic_healed39.ogg");*/

	// Wait for navmesh
	CreateTimer(2.0, Timer_MapStart);
	g_preRoundInitial = true;
}

public Action:Event_GameEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_iRoundStatus = 0;
	g_botsReady = 0;
	g_iEnableRevive = 0;
}
// Initializing
public Action:Timer_MapStart(Handle:Timer)
{
	// Check is map initialized
	if (g_isMapInit == 1) 
	{
		//PrintToServer("[RESPPAWN] Prevented repetitive call");
		return;
	}
	g_isMapInit = 1;

	//AI Directory Reset
	g_AIDir_ReinforceTimer_Orig = GetConVarInt(sm_respawn_reinforce_time);
	g_AIDir_ReinforceTimer_SubOrig = GetConVarInt(sm_respawn_reinforce_time_subsequent);

	// Bot Reinforce Times
	g_iReinforceTime = GetConVarInt(sm_respawn_reinforce_time);
	// g_iReinforceTimeSubsequent = GetConVarInt(sm_respawn_reinforce_time_subsequent);

	g_cqc_map_enabled = GetConVarInt(sm_cqc_map_enabled);

	// Update cvars
	UpdateRespawnCvars();
	
	g_isConquer = 0;
	g_isHunt = 0;
	g_isCheckpoint = 0;
	g_isOutpost = 0;
	
	// Check gamemode
	decl String:sGameMode[32];
	GetConVarString(FindConVar("mp_gamemode"), sGameMode, sizeof(sGameMode));
	if (StrEqual(sGameMode,"hunt")) // if Hunt?
	{
		g_isHunt = 1;

		//Lives given at beginning, change respawn type.
		//SetConVarFloat(sm_respawn_fatal_chance, 0.1, true, false);
		//SetConVarFloat(sm_respawn_fatal_head_chance, 0.2, true, false);
	}
	if (StrEqual(sGameMode,"conquer")) // if conquer?
	{
		g_isConquer = 1;

		//Lives given at beginning, change respawn type.
		//SetConVarFloat(sm_respawn_fatal_chance, 0.4, true, false);
		//SetConVarFloat(sm_respawn_fatal_head_chance, 0.4, true, false);
	}
	if (StrEqual(sGameMode,"outpost")) // if conquer?
	{
		g_isOutpost = 1;

		//Lives given at beginning, change respawn type.
		//SetConVarFloat(sm_respawn_fatal_chance, 0.4, true, false);
		//SetConVarFloat(sm_respawn_fatal_head_chance, 0.4, true, false);
	}
	if (StrEqual(sGameMode,"checkpoint")) // if Hunt?
	{
		g_isCheckpoint = 1;
	}
	
	g_iEnableRevive = 0;
	// BotSpawn Nav Mesh initialize #################### END
	
	// Reset respawn token
	ResetSecurityLives();
	ResetInsurgencyLives();
	
	// Ammo tracking timer
	 //if (GetConVarInt(sm_respawn_enable_track_ammo) == 1)
		//CreateTimer(1.0, Timer_GearMonitor,_ , TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
	// Enemy reinforcement announce timer
	if (g_isConquer != 1 && g_isOutpost != 1) 
		CreateTimer(1.0, Timer_EnemyReinforce,_ , TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
	// Enemy remaining announce timer
	if (g_isConquer != 1 && g_isOutpost != 1) 
	CreateTimer(30.0, Timer_Enemies_Remaining, _ , TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	// Player status check timer
	CreateTimer(1.0, Timer_PlayerStatus,_ , TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
	// Revive monitor
	CreateTimer(1.0, Timer_ReviveMonitor, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
	// Heal monitor
	CreateTimer(0.5, Timer_MedicMonitor, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	// Display nearest body for medics
	CreateTimer(0.1, Timer_NearestBody, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	// Monitor ammo resupply
	CreateTimer(1.0, Timer_AmmoResupply, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	// AI Director Tick
	if (g_isCheckpoint)
		CreateTimer(1.0, Timer_AIDirector_Main, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	// Elite Period
	//CreateTimer(1.0, Timer_ElitePeriodTick, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
	// Static enemy check timer
	g_checkStaticAmt = GetConVarInt(sm_respawn_check_static_enemy);
	g_checkStaticAmtCntr = GetConVarInt(sm_respawn_check_static_enemy_counter);
	//Temp testing
	g_checkStaticAmtAway = 30;
	g_checkStaticAmtCntrAway = 12;
	//Elite Bot cvar multipliers (used to minus off top of original cvars)
	g_bot_attack_aimtolerance_newthreat_amt_mult = 0.8;
	g_bot_attack_aimpenalty_amt_close_mult = 15;
	g_bot_attack_aimpenalty_amt_far_mult = 40;
	g_bot_attackdelay_frac_difficulty_impossible_mult = 0.03;
	g_bot_attack_aimpenalty_time_close_mult = 0.15;
	g_bot_attack_aimpenalty_time_far_mult = 2.0;
	g_coop_delay_penalty_base = 180;
	g_bot_aim_aimtracking_base = 0.05;
	g_bot_aim_aimtracking_frac_impossible =	 0.05;
	g_bot_aim_angularvelocity_frac_impossible =	 0.05;
	g_bot_aim_angularvelocity_frac_sprinting_target =  0.05;
	g_bot_aim_attack_aimtolerance_frac_impossible =	 0.05;

	//Get Originals
	g_ins_bot_count_checkpoint_max_org = GetConVarInt(FindConVar("ins_bot_count_checkpoint_max"));
	g_mp_player_resupply_coop_delay_max_org = GetConVarInt(FindConVar("mp_player_resupply_coop_delay_max"));
	g_mp_player_resupply_coop_delay_penalty_org = GetConVarInt(FindConVar("mp_player_resupply_coop_delay_penalty"));
	g_mp_player_resupply_coop_delay_base_org = GetConVarInt(FindConVar("mp_player_resupply_coop_delay_base"));
	g_bot_attack_aimpenalty_amt_close_org = GetConVarInt(FindConVar("bot_attack_aimpenalty_amt_close"));
	g_bot_attack_aimpenalty_amt_far_org = GetConVarInt(FindConVar("bot_attack_aimpenalty_amt_far"));
	g_bot_attack_aimpenalty_time_close_org = GetConVarFloat(FindConVar("bot_attack_aimpenalty_time_close"));
	g_bot_attack_aimpenalty_time_far_org = GetConVarFloat(FindConVar("bot_attack_aimpenalty_time_far"));
	g_bot_attack_aimtolerance_newthreat_amt_org = GetConVarFloat(FindConVar("bot_attack_aimtolerance_newthreat_amt"));
	g_bot_attackdelay_frac_difficulty_impossible_org = GetConVarFloat(FindConVar("bot_attackdelay_frac_difficulty_impossible"));
	g_bot_aim_aimtracking_base_org = GetConVarFloat(FindConVar("bot_aim_aimtracking_base"));
	g_bot_aim_aimtracking_frac_impossible_org = GetConVarFloat(FindConVar("bot_aim_aimtracking_frac_impossible"));
	g_bot_aim_angularvelocity_frac_impossible_org = GetConVarFloat(FindConVar("bot_aim_angularvelocity_frac_impossible"));
	g_bot_aim_angularvelocity_frac_sprinting_target_org = GetConVarFloat(FindConVar("bot_aim_angularvelocity_frac_sprinting_target"));
	g_bot_aim_attack_aimtolerance_frac_impossible_org = GetConVarFloat(FindConVar("bot_aim_attack_aimtolerance_frac_impossible"));

	CreateTimer(1.0, Timer_CheckEnemyStatic,_ , TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	if (g_isCheckpoint)
		CreateTimer(1.0, Timer_CheckEnemyAway,_ , TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	
}

public OnMapEnd()
{
	// Reset variable
	//PrintToServer("[REVIVE_DEBUG] MAP ENDED");	
	
	// Reset respawn token
	ResetSecurityLives();
	ResetInsurgencyLives();
	
	g_isMapInit = 0;
	g_botsReady = 0;
	g_iRoundStatus = 0;
	g_iEnableRevive = 0;
}

// Console command for reload config
public Action:Command_Reload(client, args)
{
	ServerCommand("exec sourcemod/respawn.cfg");
	
	//Reset respawn token
	ResetSecurityLives();
	ResetInsurgencyLives();
	
	//PrintToServer("[RESPAWN] %N reloaded respawn config.", client);
	ReplyToCommand(client, "[SM] Reloaded 'sourcemod/respawn.cfg' file.");
}

// Respawn function for console command
public Action:Command_Respawn(client, args)
{
	// Check argument
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_player_respawn <#userid|name>");
		return Plugin_Handled;
	}

	// Retrive argument
	new String:arg[65];
	GetCmdArg(1, arg, sizeof(arg));
	new String:target_name[MAX_TARGET_LENGTH];
	new target_list[MaxClients], target_count, bool:tn_is_ml;
	
	// Get target count
	target_count = ProcessTargetString(
					arg,
					client,
					target_list,
					MaxClients,
					COMMAND_FILTER_DEAD,
					target_name,
					sizeof(target_name),
					tn_is_ml);
					
	// Check target count
	if(target_count <= COMMAND_TARGET_NONE)		// If we don't have dead players
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}

	// Team filter dead players, re-order target_list array with new_target_count
	new target, team, new_target_count;

	// Check team
	for (new i = 0; i < target_count; i++)
	{
		target = target_list[i];
		team = GetClientTeam(target);

		if(team >= 2)
		{
			target_list[new_target_count] = target; // re-order
			new_target_count++;
		}
	}

	// Check target count
	if(new_target_count == COMMAND_TARGET_NONE) // No dead players from	 team 2 and 3
	{
		ReplyToTargetError(client, new_target_count);
		return Plugin_Handled;
	}
	target_count = new_target_count; // re-set new value.

	// If target exists
	if (tn_is_ml)
		ShowActivity2(client, "[SM] ", "%t", "Toggled respawn on target", target_name);
	else
		ShowActivity2(client, "[SM] ", "%t", "Toggled respawn on target", "_s", target_name);
	
	// Process respawn
	for (new i = 0; i < target_count; i++)
		RespawnPlayer(client, target_list[i]);

	return Plugin_Handled;
}

public Action:Timer_EliteBots(Handle:Timer)
{
	// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	//new counterAlwaysCvar = GetConVarInt(FindConVar("mp_checkpoint_counterattack_always"));
	if (Ins_InCounterAttack())
	{
		if ((acp+1) == ncp)
		{
			PrintToServer("ENABLE ELITE FINALE");
			g_isEliteCounter = 1;
			//EnableDisableEliteBotCvars(1, 1);
		}
		else
		{
			PrintToServer("ENABLE ELITE NORMAL");
			g_isEliteCounter = 1;
			//EnableDisableEliteBotCvars(1, 0);
		}
	}
}
// Respawn player
void RespawnPlayer(client, target)
{
	new team = GetClientTeam(target);
	if(IsClientInGame(target) && !IsClientTimingOut(target) && g_client_last_classstring[target][0] && playerPickSquad[target] == 1 && !IsPlayerAlive(target) && team == TEAM_1_SEC)
	{
		// Write a log
		LogAction(client, target, "\"%L\" respawned \"%L\"", client, target);
		
		// Call forcerespawn fucntion
		SDKCall(g_hForceRespawn, target);
	}
}
// ForceRespawnPlayer player
void ForceRespawnPlayer(client, target)
{
	new team = GetClientTeam(target);
	if(IsClientInGame(target) && !IsClientTimingOut(target) && g_client_last_classstring[target][0] && playerPickSquad[target] == 1 && team == TEAM_1_SEC)
	{
		// Write a log
		LogAction(client, target, "\"%L\" respawned \"%L\"", client, target);
		
		// Call forcerespawn fucntion
		SDKCall(g_hForceRespawn, target);
	}
}

// Check and inform player status
public Action:Timer_PlayerStatus(Handle:Timer)
{
	if (g_iRoundStatus == 0) return Plugin_Continue;
	
	for (new client = 1; client <= MaxClients; client++)
	{
		// Validate client first
		if (!IsClientInGame(client))
			continue;
		if (!IsClientConnected(client))
			continue;
		if (IsFakeClient(client))
			continue;
		if (playerPickSquad[client] != 1)
			continue;

			new team = GetClientTeam(client);
			g_plyrGrenScreamCoolDown[client]--;
			if (g_plyrGrenScreamCoolDown[client] <= 0)
				g_plyrGrenScreamCoolDown[client] = 0;

			g_plyrFireScreamCoolDown[client]--;
			if (g_plyrFireScreamCoolDown[client] <= 0)
				g_plyrFireScreamCoolDown[client] = 0;

			if (g_iPlayerRespawnTimerActive[client] == 0 && !IsPlayerAlive(client) && !IsClientTimingOut(client) && IsClientObserver(client) && team == TEAM_1_SEC && g_iEnableRevive == 1 && g_iRoundStatus == 1) //
			{

				new String:woundType[128];
				woundType = "WOUNDED";
				if (g_playerWoundType[client] == 0)
					woundType = "MINORLY WOUNDED";
				else if (g_playerWoundType[client] == 1)
					woundType = "MODERATELY WOUNDED";
				else if (g_playerWoundType[client] == 2)
					woundType = "CRITCALLY WOUNDED";

				if (!g_iCvar_respawn_enable || g_iRespawnCount[2] == -1 || g_iSpawnTokens[client] <= 0)
				{
					// Player was killed fatally
					if (g_iHurtFatal[client] == 1)
					{
						decl String:fatal_hint[255];
						Format(fatal_hint, 255,"You were fatally killed for %i damage and must wait til next objective to spawn", g_clientDamageDone[client]);
						PrintCenterText(client, "%s", fatal_hint);
					}
					// Player was killed
					else if (g_iHurtFatal[client] == 0 && !Ins_InCounterAttack())
					{
						decl String:wound_hint[255];
						Format(wound_hint, 255,"[You're %s for %d damage]..wait patiently for a medic..do NOT mic/chat spam!", woundType, g_clientDamageDone[client]);
						PrintCenterText(client, "%s", wound_hint);
					}
					// Player was killed during counter attack
					else if (g_iHurtFatal[client] == 0 && Ins_InCounterAttack())
					{
						decl String:wound_hint[255];
						Format(wound_hint, 255,"You're %s during a Counter-Attack for %d damage..if its close to ending..dont bother asking for a medic!", woundType, g_clientDamageDone[client]);
						PrintCenterText(client, "%s", wound_hint);
				}
			}
		}
	}
	return Plugin_Continue;
}

// Announce enemies remaining
public Action Timer_Enemies_Remaining(Handle timer)
{
	char textToPrint[64];
	ReportTotalEnemies(textToPrint, sizeof(textToPrint));
	PrintHintTextToAll(textToPrint);

	// For debugging also send the message to all players' chat
	// TODO TEMP
	PrintToChatAll(textToPrint);

	return Plugin_Continue;
}

public Action Check_Total_Enemies(int client, int args)
{
	char textToPrint[64];
	ReportTotalEnemies(textToPrint, sizeof(textToPrint));
	PrintHintText(client, "%s", textToPrint);

	return Plugin_Handled;
}

stock void ReportTotalEnemies(char[] enemyMessage, int maxlength) 
{
	// Check round state
	if (g_iRoundStatus == 0) return;
	
	// Check enemy count
	int alive_insurgents;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientConnected(i) && IsClientInGame(i) && IsPlayerAlive(i) && IsFakeClient(i))
			alive_insurgents++;

	// Announce
	Format(enemyMessage, maxlength, "Enemies alive: %d | Enemy reinforcements left: %d", alive_insurgents, g_iRemaining_lives_team_ins);
}

// This timer reinforces bot team if you do not capture point
public Action Timer_EnemyReinforce(Handle timer)
{
	// Check round state
	if (g_iRoundStatus == 0) return Plugin_Continue;
	
	// Check enemy remaining
	if (g_iRemaining_lives_team_ins <= (g_iRespawn_lives_team_ins / g_iReinforce_Mult) + g_iReinforce_Mult_Base)
	{
		g_iReinforceTime--;
		decl String:textToPrint[64];

		if (g_iReinforceTime == 140)
		{
			Format(textToPrint, sizeof(textToPrint), "[INTEL]Enemies reinforce in %d seconds | Capture point soon!", g_iReinforceTime);
			PrintHintTextToAll(textToPrint);
		}
		if (g_iReinforceTime == 70)
		{
			Format(textToPrint, sizeof(textToPrint), "[INTEL]Enemies reinforce in %d seconds | Capture point soon!", g_iReinforceTime);
			PrintHintTextToAll(textToPrint);
		}
		// Anncount every 1 second
		if (g_iReinforceTime <=10 && g_iReinforceTime >=0)
		{
			//Format(textToPrintChat, sizeof(textToPrintChat), "[INTEL]Friendlies spawn on Counter-Attacks, Capture the Point!");
			Format(textToPrint, sizeof(textToPrint), "[INTEL]Enemies reinforce in %d seconds | Capture point soon!", g_iReinforceTime);
			PrintHintTextToAll(textToPrint);
			//PrintToChatAll(textToPrintChat);
		}

		// Process reinforcement
		if (g_iReinforceTime <= 0)
		{
			// If enemy reinforcement is not over, add it
			if (g_iRemaining_lives_team_ins > 0)
			{

				//Only add more reinforcements if under certain amount so its not endless.
				if (g_iRemaining_lives_team_ins < (g_iRespawn_lives_team_ins / g_iReinforce_Mult) + g_iReinforce_Mult_Base)
				{
					// Get bot count
					new minBotCount = (g_iRespawn_lives_team_ins / 4);
					g_iRemaining_lives_team_ins = g_iRemaining_lives_team_ins + minBotCount;
					//Format(textToPrint, sizeof(textToPrint), "[INTEL]Enemy Reinforcements Added to Existing Reinforcements!");
					//Format(textToPrintChat, sizeof(textToPrintChat), "[INTEL]Enemy Reinforcements Added to Existing Reinforcements!");
					
					//AI Director Reinforcement START
					g_AIDir_BotReinforceTriggered = true;
					g_AIDir_TeamStatus -= 5;
					g_AIDir_TeamStatus = AI_Director_SetMinMax(g_AIDir_TeamStatus, g_AIDir_TeamStatus_min, g_AIDir_TeamStatus_max);

					//AI Director Reinforcement END
/*					if (validAntenna != -1 || g_jammerRequired == 0)
					{
						//PrintHintTextToAll(textToPrint);
						//PrintToChatAll(textToPrintChat);
					}
					else
					{
						new fCommsChance = GetRandomInt(1, 100);
						if (fCommsChance > 50)
						{
							Format(textToPrintChat, sizeof(textToPrintChat), "[INTEL]Comms are down, build jammer to get enemy reports.");
							Format(textToPrint, sizeof(textToPrintChat), "[INTEL]Comms are down, build jammer to get enemy reports.");
							//PrintHintTextToAll(textToPrint);
							//PrintToChatAll(textToPrintChat);
						}
					}
*/		
					g_iReinforceTime = g_iReinforceTimeSubsequent_AD_Temp;
					//PrintToServer("g_iReinforceTime %d, Reinforcements added to existing!",g_iReinforceTime);
					if (g_isHunt == 1)
						 g_iReinforceTime = g_iReinforceTimeSubsequent_AD_Temp * g_iReinforce_Mult;

					//Lower Bot Flank spawning on reinforcements
					g_dynamicSpawn_Perc = 0;

					// Add bots
					for (new client = 1; client <= MaxClients; client++)
					{
						if (client > 0 && IsClientInGame(client))
						{
							new m_iTeam = GetClientTeam(client);
							if (IsFakeClient(client) && !IsPlayerAlive(client) && m_iTeam == TEAM_2_INS)
							{
								g_iRemaining_lives_team_ins++;
								CreateBotRespawnTimer(client);
							}
						}
					}
					
					//Reset bot back spawning to default
					CreateTimer(45.0, Timer_ResetBotFlankSpawning, _);
				}
			}
			// Respawn enemies
			else
			{
				// Get bot count
				new minBotCount = (g_iRespawn_lives_team_ins / 4);
				g_iRemaining_lives_team_ins = g_iRemaining_lives_team_ins + minBotCount;
				
				//Lower Bot Flank spawning on reinforcements
				g_dynamicSpawn_Perc = 0;

				// Add bots
				for (new client = 1; client <= MaxClients; client++)
				{
					if (client > 0 && IsClientInGame(client))
					{
						new m_iTeam = GetClientTeam(client);
						if (IsFakeClient(client) && !IsPlayerAlive(client) && m_iTeam == TEAM_2_INS)
						{
							g_iRemaining_lives_team_ins++;
							CreateBotRespawnTimer(client);
						}
					}
				}
				g_iReinforceTime = g_iReinforceTimeSubsequent_AD_Temp;
				//PrintToServer("g_iReinforceTime %d, Reinforcements Arrived Normally!",g_iReinforceTime);


				//Reset bot back spawning to default
				CreateTimer(45.0, Timer_ResetBotFlankSpawning, _);

				// Get random duration
				//new fRandomInt = GetRandomInt(1, 4);
				
				Format(textToPrint, sizeof(textToPrint), "[INTEL]Enemy Reinforcements Have Arrived!");
				PrintHintTextToAll(textToPrint);
				//Format(textToPrintChat, sizeof(textToPrintChat), "[INTEL]Enemy Reinforcements Have Arrived!");
				
				//AI Director Reinforcement START
				g_AIDir_BotReinforceTriggered = true;
				g_AIDir_TeamStatus -= 5;
				g_AIDir_TeamStatus = AI_Director_SetMinMax(g_AIDir_TeamStatus, g_AIDir_TeamStatus_min, g_AIDir_TeamStatus_max);

				//AI Director Reinforcement END


/*				if (validAntenna != -1 || g_jammerRequired == 0)
				{
					//PrintHintTextToAll(textToPrint);
					//PrintToChatAll(textToPrintChat);
				}
				else
				{
					new fCommsChance = GetRandomInt(1, 100);
					if (fCommsChance > 50)
					{
						//Format(textToPrintChat, sizeof(textToPrintChat), "[INTEL]Comms are down, build jammer to get enemy reports.");
						//Format(textToPrint, sizeof(textToPrintChat), "[INTEL]Comms are down, build jammer to get enemy reports.");
						//PrintHintTextToAll(textToPrint);
						//PrintToChatAll(textToPrintChat);
					}
				}
*/
			}
		}
	}
	return Plugin_Continue;
}

//Reset bot flank spawning X seconds after reinforcement
public Action:Timer_ResetBotFlankSpawning(Handle:Timer)
{
	//Reset bot back spawning to default
	g_dynamicSpawn_Perc = GetConVarInt(sm_respawn_dynamic_spawn_percent);
	return Plugin_Continue;
}

// Check enemy is stuck
public Action:Timer_CheckEnemyStatic(Handle:Timer)
{
	//Remove bot weapons when static killed to reduce server performance on dropped items.
	new primaryRemove = 1, secondaryRemove = 1, grenadesRemove = 1;

	// Check round state
	if (g_iRoundStatus == 0) return Plugin_Continue;
	
	if (Ins_InCounterAttack())
	{
		g_checkStaticAmtCntr = g_checkStaticAmtCntr - 1;
		if (g_checkStaticAmtCntr <= 0)
		{
			for (new enemyBot = 1; enemyBot <= MaxClients; enemyBot++)
			{	
				if (IsClientInGame(enemyBot) && IsFakeClient(enemyBot))
				{
					new m_iTeam = GetClientTeam(enemyBot);
					if (IsPlayerAlive(enemyBot) && m_iTeam == TEAM_2_INS)
					{
						// Get current position
						decl Float:enemyPos[3];
						GetClientAbsOrigin(enemyBot, Float:enemyPos);
						
						// Get distance
						new Float:tDistance;
						new Float:capDistance;
						tDistance = GetVectorDistance(enemyPos, g_enemyTimerPos[enemyBot]);
						if (g_isCheckpoint == 1)
						{
							new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
							Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);
							capDistance = GetVectorDistance(enemyPos,m_vCPPositions[m_nActivePushPointIndex]);
						}
						else 
							capDistance = 801.0;
						// If enemy position is static, kill him
						if (tDistance <= 150 && Check_NearbyPlayers(enemyBot) && (capDistance > 800.0 || g_botStaticGlobal[enemyBot] > 120)) 
						{
							RemoveWeapons(enemyBot, primaryRemove, secondaryRemove, grenadesRemove);
							ForcePlayerSuicide(enemyBot);
							AddLifeForStaticKilling(enemyBot);
							PrintToServer("ENEMY STATIC - KILLING");
							//PrintToServer("Add to g_badSpawnPos_Array | enemyPos: (%f, %f, %f) | g_badSpawnPos_Array Size: %d", enemyPos[0],enemyPos[1],enemyPos[2], GetArraySize(g_badSpawnPos_Array));
							//PushArrayArray(g_badSpawnPos_Array, enemyPos, sizeof(enemyPos));
						}
						// Update current position
						else
						{
							g_enemyTimerPos[enemyBot] = enemyPos;
							g_botStaticGlobal[enemyBot]++;
						}
					}
				}
			}
			g_checkStaticAmtCntr = GetConVarInt(sm_respawn_check_static_enemy_counter);
		}
	}
	else
	{
		g_checkStaticAmt = g_checkStaticAmt - 1;
		if (g_checkStaticAmt <= 0)
		{
			for (new enemyBot = 1; enemyBot <= MaxClients; enemyBot++)
			{	
				if (IsClientInGame(enemyBot) && IsFakeClient(enemyBot))
				{
					new m_iTeam = GetClientTeam(enemyBot);
					if (IsPlayerAlive(enemyBot) && m_iTeam == TEAM_2_INS)
					{
						// Get current position
						decl Float:enemyPos[3];
						GetClientAbsOrigin(enemyBot, Float:enemyPos);
						
						// Get distance
						new Float:tDistance;
						new Float:capDistance;
						tDistance = GetVectorDistance(enemyPos, g_enemyTimerPos[enemyBot]);
						//Check point distance
						if (g_isCheckpoint == 1)
						{
							new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
							Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);
							capDistance = GetVectorDistance(enemyPos,m_vCPPositions[m_nActivePushPointIndex]);
						}
						else 
							capDistance = 801.0;
						// If enemy position is static, kill him
						if (tDistance <= 150 && (capDistance > 800.0) && Check_NearbyPlayers(enemyBot))// || g_botStaticGlobal[enemyBot] > 120)) 
						{
							//PrintToServer("ENEMY STATIC - KILLING");
							RemoveWeapons(enemyBot, primaryRemove, secondaryRemove, grenadesRemove);
							ForcePlayerSuicide(enemyBot);
							AddLifeForStaticKilling(enemyBot);
						}
						// Update current position
						else
						{ 
							g_enemyTimerPos[enemyBot] = enemyPos;
							//g_botStaticGlobal[enemyBot]++;
						}
					}
				}
			}
			g_checkStaticAmt = GetConVarInt(sm_respawn_check_static_enemy); 
		}
	}
	
	return Plugin_Continue;
}
// Check enemy is stuck
public Action:Timer_CheckEnemyAway(Handle:Timer)
{
	//Remove bot weapons when static killed to reduce server performance on dropped items.
	new primaryRemove = 1, secondaryRemove = 1, grenadesRemove = 1;
	// Check round state
	if (g_iRoundStatus == 0) return Plugin_Continue;
	
	if (Ins_InCounterAttack())
	{
		g_checkStaticAmtCntrAway = g_checkStaticAmtCntrAway - 1;
		if (g_checkStaticAmtCntrAway <= 0)
		{
			for (new enemyBot = 1; enemyBot <= MaxClients; enemyBot++)
			{	
				if (IsClientInGame(enemyBot) && IsFakeClient(enemyBot))
				{
					new m_iTeam = GetClientTeam(enemyBot);
					if (IsPlayerAlive(enemyBot) && m_iTeam == TEAM_2_INS)
					{
						// Get current position
						decl Float:enemyPos[3];
						GetClientAbsOrigin(enemyBot, Float:enemyPos);
						
						// Get distance
						new Float:tDistance;
						new Float:capDistance;
						tDistance = GetVectorDistance(enemyPos, g_enemyTimerAwayPos[enemyBot]);
						if (g_isCheckpoint == 1)
						{
							new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
							Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);
							capDistance = GetVectorDistance(enemyPos,m_vCPPositions[m_nActivePushPointIndex]);
						}
						else 
							capDistance = 801.0;
						// If enemy position is static, kill him
						if (tDistance <= 150.0 && capDistance > 2500.0) 
						{
							//PrintToServer("ENEMY STATIC - KILLING");
							RemoveWeapons(enemyBot, primaryRemove, secondaryRemove, grenadesRemove);
							ForcePlayerSuicide(enemyBot);
							AddLifeForStaticKilling(enemyBot);
						}
						// Update current position
						else
						{
							g_enemyTimerAwayPos[enemyBot] = enemyPos;
						}
					}
				}
			}
			g_checkStaticAmtCntrAway = 12;
		}
	}
	else
	{
		g_checkStaticAmtAway = g_checkStaticAmtAway - 1;
		if (g_checkStaticAmtAway <= 0)
		{
			for (new enemyBot = 1; enemyBot <= MaxClients; enemyBot++)
			{	
				if (IsClientInGame(enemyBot) && IsFakeClient(enemyBot))
				{
					new m_iTeam = GetClientTeam(enemyBot);
					if (IsPlayerAlive(enemyBot) && m_iTeam == TEAM_2_INS)
					{
						// Get current position
						decl Float:enemyPos[3];
						GetClientAbsOrigin(enemyBot, Float:enemyPos);
						
						// Get distance
						new Float:tDistance;
						new Float:capDistance;
						tDistance = GetVectorDistance(enemyPos, g_enemyTimerAwayPos[enemyBot]);
						//Check point distance
						if (g_isCheckpoint == 1)
						{
							new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
							Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);
							capDistance = GetVectorDistance(enemyPos,m_vCPPositions[m_nActivePushPointIndex]);
						}
						// If enemy position is static, kill him
						if (tDistance <= 150 && capDistance > 1200) 
						{
							//PrintToServer("ENEMY STATIC - KILLING");
							RemoveWeapons(enemyBot, primaryRemove, secondaryRemove, grenadesRemove);
							ForcePlayerSuicide(enemyBot);
							AddLifeForStaticKilling(enemyBot);
						}
						// Update current position
						else
						{ 
							g_enemyTimerAwayPos[enemyBot] = enemyPos;
						}
					}
				}
			}
			g_checkStaticAmtAway = 30; 
		}
	}
	
	return Plugin_Continue;
}
void AddLifeForStaticKilling(client)
{
	// Respawn type 1
	new team = GetClientTeam(client);
	if (g_iCvar_respawn_type_team_ins == 1 && team == TEAM_2_INS && g_iRespawn_lives_team_ins > 0)
	{
		g_iSpawnTokens[client]++;
	}
	else if (g_iCvar_respawn_type_team_ins == 2 && team == TEAM_2_INS && g_iRespawn_lives_team_ins > 0)
	{
		g_iRemaining_lives_team_ins++;
	}
}

/*
#####################################################################
#####################################################################
#####################################################################
# Jballous INS_SPAWNPOINT SPAWNING START ############################
# Jballous INS_SPAWNPOINT SPAWNING START ############################
#####################################################################
#####################################################################
#####################################################################
*/
stock void GetInsSpawnGround(int spawnPoint, float vecSpawn[3])
{
	float fGround[3];
	vecSpawn[2] += 15.0;
	
	TR_TraceRayFilter(vecSpawn, view_as<float>({90.0, 0.0, 0.0}), MASK_PLAYERSOLID, RayType_Infinite, TRDontHitSelf, spawnPoint);
	if (!TR_DidHit())
		return;

	TR_GetEndPosition(fGround);
	vecSpawn = fGround;
}

stock float GetClientGround(client)
{
	
	float fOrigin[3], fGround[3];
	GetClientAbsOrigin(client, fOrigin);

	fOrigin[2] += 15.0;
	
	TR_TraceRayFilter(fOrigin, view_as<float>({90.0,0.0,0.0}), MASK_PLAYERSOLID, RayType_Infinite, TRDontHitSelf, client);
	if (TR_DidHit())
	{
		TR_GetEndPosition(fGround);
		fOrigin[2] -= 15.0;
		return fGround[2];
	}
	return 0.0;
}
 
CheckSpawnPoint(Float:vecSpawn[3],client,Float:tObjectiveDistance,m_nActivePushPointIndex) {
//Ins_InCounterAttack
	new m_iTeam = GetClientTeam(client);
	new Float:distance,Float:furthest,Float:closest=-1.0;
	new Float:vecOrigin[3];

	GetClientAbsOrigin(client,vecOrigin);
	new Float:tMinPlayerDistMult = 0.0;

	new acp = (Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex") - 1);
	new acp2 = m_nActivePushPointIndex;
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	if (acp == acp2 && !Ins_InCounterAttack())
	{
		tMinPlayerDistMult = g_flBackSpawnIncrease;
		//PrintToServer("INCREASE SPAWN DISTANCE | acp: %d acp2 %d", acp, acp2);
	}

	//Update player spawns before we check against them
	UpdatePlayerOrigins();
	//Lets go through checks to find a valid spawn point
	for (new iTarget = 1; iTarget <= MaxClients; iTarget++) {
		if (!IsValidClient(iTarget))
			continue;
		if (!IsPlayerAlive(iTarget)) 
			continue;
		new tTeam = GetClientTeam(iTarget);
		if (tTeam != TEAM_1_SEC)
			continue;
		////InsLog(DEBUG, "Distance from %N to iSpot %d is %f",iTarget,iSpot,distance);
		distance = GetVectorDistance(vecSpawn,g_vecOrigin[iTarget]);
		if (distance > furthest)
			furthest = distance;
		if ((distance < closest) || (closest < 0))
			closest = distance;
		
		if (GetClientTeam(iTarget) != m_iTeam) {
			// If we are too close
			if (distance < (g_flMinPlayerDistance + tMinPlayerDistMult)) {
				 return 0;
			}
			// If the player can see the spawn point (divided CanSeeVector to slightly reduce strictness)
			//(IsVectorInSightRange(iTarget, vecSpawn, 120.0)) ||  / g_flCanSeeVectorMultiplier
			if (ClientCanSeeVector(iTarget, vecSpawn, (g_flMinPlayerDistance * g_flCanSeeVectorMultiplier))) {
				return 0; 
			}
			//If any player is too far
			if (closest > g_flMaxPlayerDistance) {
				return 0; 
			}
			else if (closest > 2000 && g_cacheObjActive == 1 && Ins_InCounterAttack())
			{
				return 0; 
			}
		}
	}

	
		

	Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);
	distance = GetVectorDistance(vecSpawn,m_vCPPositions[m_nActivePushPointIndex]);
	if (distance > (tObjectiveDistance) && (((acp+1) != ncp) || !Ins_InCounterAttack())) {// && (fRandomFloat <= g_dynamicSpawn_Perc)) {
		 return 0;
	} 
	else if (distance > (tObjectiveDistance * g_DynamicRespawn_Distance_mult) && (((acp+1) != ncp) || !Ins_InCounterAttack())) {
		 return 0;
	}


	new fRandomInt = GetRandomInt(1, 100);
	//If final point respawn around last point, not final point
	if ((((acp+1) == ncp) || Ins_InCounterAttack()) && fRandomInt <= 10)
	{
		new m_nActivePushPointIndexFinal = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
		if (m_nActivePushPointIndexFinal > 0) m_nActivePushPointIndexFinal -= 1;
		distance = GetVectorDistance(vecSpawn,m_vCPPositions[m_nActivePushPointIndexFinal]);
		if (distance > (tObjectiveDistance)) {// && (fRandomFloat <= g_dynamicSpawn_Perc)) {
			 return 0;
		} 
		else if (distance > (tObjectiveDistance * g_DynamicRespawn_Distance_mult)) {
			 return 0;
		}
	}
	return 1;
}

int CheckSpawnPointPlayers(float vecSpawn[3], int client, float tObjectiveDistance) {
//Ins_InCounterAttack
	int m_iTeam = GetClientTeam(client);
	float distance, furthest, closest=-1.0;
	float vecOrigin[3];
	GetClientAbsOrigin(client, vecOrigin);
	//Update player spawns before we check against them
	UpdatePlayerOrigins();

	int m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	float objDistance;
	
	//Lets go through checks to find a valid spawn point
	for (new iTarget = 1; iTarget <= MaxClients; iTarget++) {
		if (!IsValidClient(iTarget))
			continue;
		if (!IsPlayerAlive(iTarget)) 
			continue;
		int tTeam = GetClientTeam(iTarget);
		if (tTeam != TEAM_1_SEC)
			continue;

		m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");

		//If in counter 
		if (Ins_InCounterAttack() && m_nActivePushPointIndex > 0)
			m_nActivePushPointIndex -= 1;

		Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);

		objDistance = GetVectorDistance(g_vecOrigin[iTarget],m_vCPPositions[m_nActivePushPointIndex]);
		distance = GetVectorDistance(vecSpawn,g_vecOrigin[iTarget]);
		if (distance > furthest)
			furthest = distance;
		if ((distance < closest) || (closest < 0))
			closest = distance;
		
		if (GetClientTeam(iTarget) != m_iTeam) {
			// If we are too close
			if (distance < g_flMinPlayerDistance) return 0;
			int fRandomInt = GetRandomInt(1, 100);

			// If the player can see the spawn point (divided CanSeeVector to slightly reduce strictness)
			//(IsVectorInSightRange(iTarget, vecSpawn, 120.0)) ||  / g_flCanSeeVectorMultiplier
			if (ClientCanSeeVector(iTarget, vecSpawn, (g_flMinPlayerDistance * g_flCanSeeVectorMultiplier))) return 0; 

			//Check if players are getting close to point when assaulting
			if (objDistance < 2500 && fRandomInt < 30 && !Ins_InCounterAttack()) return 0;
		}
	}

	// Get the number of control points
	int ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	
	// Get active push point
	int acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");

	//If any player is too far
	if (closest > g_flMaxPlayerDistance) return 0; 
	if (closest > 2000 && g_cacheObjActive == 1 && Ins_InCounterAttack()) return 0; 

	m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");

	int fRandomInt = GetRandomInt(1, 100);
	//Check against back spawn if in counter
	if (Ins_InCounterAttack() && m_nActivePushPointIndex > 0)
		m_nActivePushPointIndex -= 1;

	Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);
	objDistance = GetVectorDistance(vecSpawn,m_vCPPositions[m_nActivePushPointIndex]);
	if (objDistance > (tObjectiveDistance) && (((acp+1) != ncp) || !Ins_InCounterAttack()) && fRandomInt < 25) return 0;
	if (objDistance > (tObjectiveDistance * g_DynamicRespawn_Distance_mult) &&  (((acp+1) != ncp) || !Ins_InCounterAttack()) && fRandomInt < 25) return 0;
	fRandomInt = GetRandomInt(1, 100);
	//If final point respawn around last point, not final point
	if ((((acp+1) == ncp) || Ins_InCounterAttack()) && fRandomInt < 25)
	{
		int m_nActivePushPointIndexFinal = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
		if (m_nActivePushPointIndexFinal > 0) m_nActivePushPointIndexFinal -= 1;
		objDistance = GetVectorDistance(vecSpawn,m_vCPPositions[m_nActivePushPointIndexFinal]);
		if (objDistance > (tObjectiveDistance)) return 0;
		if (objDistance > (tObjectiveDistance * g_DynamicRespawn_Distance_mult)) return 0;
	}

	return 1;
}

public GetPushPointIndex(Float:fRandomFloat, client)
{
	// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	
	new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	//Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);
	//new Float:distance = GetVectorDistance(vecSpawn,m_vCPPositions[m_nActivePushPointIndex]);
	//Check last point	
		
	if (((acp+1) == ncp && Ins_InCounterAttack()) || g_spawnFrandom[client] < g_dynamicSpawnCounter_Perc || (Ins_InCounterAttack()) || (m_nActivePushPointIndex > 1))
	{
		//PrintToServer("###POINT_MOD### | fRandomFloat: %f | g_dynamicSpawnCounter_Perc %f ",fRandomFloat, g_dynamicSpawnCounter_Perc);
		if ((acp+1) == ncp && Ins_InCounterAttack())
		{
			if (g_spawnFrandom[client] < g_dynamicSpawnCounter_Perc)
				m_nActivePushPointIndex--;
		}
		else
		{
			if (Ins_InCounterAttack() && (acp+1) != ncp)
			{
				if (fRandomFloat <= 0.5 && m_nActivePushPointIndex > 0)
					m_nActivePushPointIndex--;
				else
					m_nActivePushPointIndex++;
			}
			else if (!Ins_InCounterAttack())
			{
				if (m_nActivePushPointIndex > 0)
				{
					if (g_spawnFrandom[client] < g_dynamicSpawn_Perc)
						m_nActivePushPointIndex--;
				}
			}
		}

	}
	return m_nActivePushPointIndex;
	
}

void GetSpawnPoint_SpawnPoint(int client, float spawnpoint[3])
{
	float vecSpawn[3];
	float vecOrigin[3];
	GetClientAbsOrigin(client, vecOrigin);
	float fRandomFloat = GetRandomFloat(0.0, 1.0);

	//PrintToServer("GetSpawnPoint_SpawnPoint Call");
	// Get the number of control points
	int ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	
	// Get active push point
	int acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");

	int m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	if (((acp+1) == ncp) || (Ins_InCounterAttack() && g_spawnFrandom[client] < g_dynamicSpawnCounter_Perc) || (!Ins_InCounterAttack() && g_spawnFrandom[client] < g_dynamicSpawn_Perc && acp > 1))
		m_nActivePushPointIndex = GetPushPointIndex(fRandomFloat, client);

				
	int point = FindEntityByClassname(-1, "ins_spawnpoint");
	float tObjectiveDistance = g_flMinObjectiveDistance;
	while (point != -1)
	{
			GetEntPropVector(point, Prop_Send, "m_vecOrigin", vecSpawn);
			Ins_ObjectiveResource_GetPropVector("m_vCPPositions", m_vCPPositions[m_nActivePushPointIndex], m_nActivePushPointIndex);
			if (CheckSpawnPoint(vecSpawn, client, tObjectiveDistance, m_nActivePushPointIndex)) {
				GetInsSpawnGround(point, vecSpawn);
				//new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
				//PrintToServer("FOUND! m_nActivePushPointIndex: %d %N (%d) spawnpoint %d Distance: %f tObjectiveDistance: %f g_flMinObjectiveDistance %f RAW ACP: %d",m_nActivePushPointIndex, client, client, point, distance, tObjectiveDistance, g_flMinObjectiveDistance, acp);
				spawnpoint[0] = vecSpawn[0];
				spawnpoint[1] = vecSpawn[1];
				spawnpoint[2] = vecSpawn[2];
				return;
			}

			tObjectiveDistance += 4.0;
			point = FindEntityByClassname(point, "ins_spawnpoint");
	}

	//PrintToServer("1st Pass: Could not find acceptable ins_spawnzone for %N (%d)", client, client);
	//Lets try again but wider range
	int point2 = FindEntityByClassname(-1, "ins_spawnpoint");
	tObjectiveDistance = ((g_flMinObjectiveDistance + 100) * 4);
	while (point2 != -1) {
			GetEntPropVector(point2, Prop_Send, "m_vecOrigin", vecSpawn);

			Ins_ObjectiveResource_GetPropVector("m_vCPPositions", m_vCPPositions[m_nActivePushPointIndex], m_nActivePushPointIndex);
			if (CheckSpawnPoint(vecSpawn, client, tObjectiveDistance, m_nActivePushPointIndex)) {
				GetInsSpawnGround(point2, vecSpawn);
				//new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
				//PrintToServer("FOUND! m_nActivePushPointIndex: %d %N (%d) spawnpoint %d Distance: %f tObjectiveDistance: %f g_flMinObjectiveDistance %f RAW ACP: %d",m_nActivePushPointIndex, client, client, point2, distance, tObjectiveDistance, g_flMinObjectiveDistance, acp);
				spawnpoint[0] = vecSpawn[0];
				spawnpoint[1] = vecSpawn[1];
				spawnpoint[2] = vecSpawn[2];
				return;
			}

			tObjectiveDistance += 4.0;
			point2 = FindEntityByClassname(point2, "ins_spawnpoint");
	}

	//PrintToServer("2nd Pass: Could not find acceptable ins_spawnzone for %N (%d)", client, client);
	//Lets try again but wider range
	new point3 = FindEntityByClassname(-1, "ins_spawnpoint");
	tObjectiveDistance = ((g_flMinObjectiveDistance + 100) * 10);
	while (point3 != -1) {
		//m_iTeamNum = GetEntProp(point3, Prop_Send, "m_iTeamNum");
		//if (m_iTeamNum == m_iTeam) {
			GetEntPropVector(point3, Prop_Send, "m_vecOrigin", vecSpawn);
			Ins_ObjectiveResource_GetPropVector("m_vCPPositions", m_vCPPositions[m_nActivePushPointIndex], m_nActivePushPointIndex);
			if (CheckSpawnPoint(vecSpawn, client, tObjectiveDistance, m_nActivePushPointIndex)) {
				GetInsSpawnGround(point3, vecSpawn);
				//new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
				//PrintToServer("FOUND! m_nActivePushPointIndex: %d %N (%d) spawnpoint %d Distance: %f tObjectiveDistance: %f g_flMinObjectiveDistance %f RAW ACP: %d",m_nActivePushPointIndex, client, client, point3, distance, tObjectiveDistance, g_flMinObjectiveDistance, acp);
				spawnpoint[0] = vecSpawn[0];
				spawnpoint[1] = vecSpawn[1];
				spawnpoint[2] = vecSpawn[2];
				return;
			}
		//}

			tObjectiveDistance += 4.0;
			point3 = FindEntityByClassname(point3, "ins_spawnpoint");
	}

	//PrintToServer("3rd Pass: Could not find acceptable ins_spawnzone for %N (%d)", client, client);
	int pointFinal = FindEntityByClassname(-1, "ins_spawnpoint");
	tObjectiveDistance = ((g_flMinObjectiveDistance + 100) * 4);
	m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	//m_nActivePushPointIndex = GetPushPointIndex(fRandomFloat);
	if (m_nActivePushPointIndex > 1)
	{	
		if ((acp+1) >= ncp)
			m_nActivePushPointIndex--;
		else
			m_nActivePushPointIndex++;
	}

	while (pointFinal != -1) {
		//m_iTeamNum = GetEntProp(pointFinal, Prop_Send, "m_iTeamNum");
		//if (m_iTeamNum == m_iTeam) {
			GetEntPropVector(pointFinal, Prop_Send, "m_vecOrigin", vecSpawn);
			
			Ins_ObjectiveResource_GetPropVector("m_vCPPositions",m_vCPPositions[m_nActivePushPointIndex],m_nActivePushPointIndex);
			if (CheckSpawnPoint(vecSpawn,client,tObjectiveDistance,m_nActivePushPointIndex)) {
				GetInsSpawnGround(pointFinal, vecSpawn);
				//new m_nActivePushPointIndex = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
				//PrintToServer("FINAL PASS FOUND! m_nActivePushPointIndex: %d %N (%d) spawnpoint %d Distance: %f tObjectiveDistance: %f g_flMinObjectiveDistance: %f RAW ACP: %d",m_nActivePushPointIndex, client, client, pointFinal, distance, tObjectiveDistance, g_flMinObjectiveDistance, acp);
				spawnpoint[0] = vecSpawn[0];
				spawnpoint[1] = vecSpawn[1];
				spawnpoint[2] = vecSpawn[2];
				return;
			}
		//}

			tObjectiveDistance += 4.0;
			pointFinal = FindEntityByClassname(pointFinal, "ins_spawnpoint");
	}
	//PrintToServer("Final Pass: Could not find acceptable ins_spawnzone for %N (%d)", client, client);

	spawnpoint[0] = vecOrigin[0];
	spawnpoint[1] = vecOrigin[1];
	spawnpoint[2] = vecOrigin[2];
	return;
}

void GetSpawnPoint(int client, float vecSpawn[3]) {
	GetSpawnPoint_SpawnPoint(client, vecSpawn);
/*
	if ((g_iHidingSpotCount) && (g_iSpawnMode == _:SpawnMode_HidingSpots)) {
		vecSpawn = GetSpawnPoint_HidingSpot(client);
	} else {
*/
//	}
	//InsLog(DEBUG, "Could not find spawn point for %N (%d)", client, client);
}

//Lets begin to find a valid spawnpoint after spawned
public TeleportClient(int client) {
	float vecSpawn[3];
	GetSpawnPoint(client, vecSpawn);

	//decl FLoat:ClientGroundPos;
	//ClientGroundPos = GetClientGround(client);
	//vecSpawn[2] = ClientGroundPos;
	TeleportEntity(client, vecSpawn, NULL_VECTOR, NULL_VECTOR);
	SetNextAttack(client);
}

public Action:Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	//Redirect all bot spawns
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	// Validate client index first
	if (client < 1 || client > MaxClients)
		return Plugin_Continue;
	if (!IsClientInGame(client))
		return Plugin_Continue;
	// new String:sNewNickname[64];
	// Format(sNewNickname, sizeof(sNewNickname), "%N", client);
	// if (StrEqual(sNewNickname, "[INS] RoundEnd Protector"))
	//	return Plugin_Continue;
	
	if (client > 0 && IsClientInGame(client))
	{
		if (!IsFakeClient(client))
		{
			g_iPlayerRespawnTimerActive[client] = 0;
			
			//remove network ragdoll associated with player
			new playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
			if(playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
				RemoveRagdoll(client);
			
			g_iHurtFatal[client] = 0;
			InProgressReviveByMedic[client] = false;
			LastTimeCheckedReviveProgress[client] = -1;
		}
	}

	g_resupplyCounter[client] = GetConVarInt(sm_resupply_delay);
	//For first joining players 
	if (g_playerFirstJoin[client] == 1 && !IsFakeClient(client))
	{
		g_playerFirstJoin[client] = 0;
		// Get SteamID to verify is player has connected before.
		decl String:steamId[64];
		//GetClientAuthString(client, steamId, sizeof(steamId));
		GetClientAuthId(client, AuthId_Steam3, steamId, sizeof(steamId));
		new isPlayerNew = FindStringInArray(g_playerArrayList, steamId);

		if (isPlayerNew == -1)
		{
			PushArrayString(g_playerArrayList, steamId);
			//PrintToServer("SPAWN: Player %N is new! | SteamID: %s | PlayerArrayList Size: %d", client, steamId, GetArraySize(g_playerArrayList));
		}
	}
	if (!g_iCvar_respawn_enable) {
		return Plugin_Continue;
	}
	if (!IsValidClient(client)) {
		return Plugin_Continue;
	}
	if (!IsFakeClient(client)) {
		return Plugin_Continue;
	}
	if (g_isCheckpoint == 0) {
		return Plugin_Continue;
	}
	
	if ((StrContains(g_client_last_classstring[client], "tank") > -1) && !Ins_InCounterAttack()) {
		 return Plugin_Handled;
	}
	
	//PrintToServer("Eventspawn Call");
	//Reset this global timer everytime a bot spawns
	g_botStaticGlobal[client] = 0;
	
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");

	float vecOrigin[3];
	GetClientAbsOrigin(client,vecOrigin);

	if	(g_playersReady && g_botsReady == 1)
	{
		float vecSpawn[3];
		GetClientAbsOrigin(client,vecOrigin);
					
		new point = FindEntityByClassname(-1, "ins_spawnpoint");
		new Float:tObjectiveDistance = g_flMinObjectiveDistance;
		int iCanSpawn = CheckSpawnPointPlayers(vecOrigin,client, tObjectiveDistance);
		while (point != -1) {
				GetEntPropVector(point, Prop_Send, "m_vecOrigin", vecSpawn);
				iCanSpawn = CheckSpawnPointPlayers(vecOrigin,client, tObjectiveDistance);
				if (iCanSpawn == 1) {
					break;
				}
				else
				{
					tObjectiveDistance += 6.0;
				}
				point = FindEntityByClassname(point, "ins_spawnpoint");
		}
		//Global random for spawning
		g_spawnFrandom[client] = GetRandomInt(0, 100);
		//InsLog(DEBUG, "Event_Spawn iCanSpawn %d", iCanSpawn);
		if (iCanSpawn == 0 || (Ins_InCounterAttack() && g_spawnFrandom[client] < g_dynamicSpawnCounter_Perc) || 
			(!Ins_InCounterAttack() && g_spawnFrandom[client] < g_dynamicSpawn_Perc && acp > 1)) {
			//PrintToServer("TeleportClient Call");
			TeleportClient(client);
			if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client) && IsClientConnected(client))
			{
				StuckCheck[client] = 0;
				StartStuckDetection(client);
			}
		}
	}

	return Plugin_Continue;
}

public Action:Event_SpawnPost(Handle:event, const String:name[], bool:dontBroadcast) {
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	// Validate client index first
	if (client < 1 || client > MaxClients)
		return Plugin_Continue;
	if (!IsClientInGame(client))
		return Plugin_Continue;
	
	////InsLog(DEBUG, "Event_Spawn called");
	// new String:sNewNickname[64];
	// Format(sNewNickname, sizeof(sNewNickname), "%N", client);
	// if (StrEqual(sNewNickname, "[INS] RoundEnd Protector"))
	//	return Plugin_Continue;


	//Bots only below this
	if (!IsFakeClient(client)) {
		return Plugin_Continue;
	}
	SetNextAttack(client);
	//new Float:fRandom = GetRandomFloat(0.0, 1.0);
	/*new fRandom = GetRandomInt(1, 100);
	//Check grenades
	if (fRandom < g_removeBotGrenadeChance && !Ins_InCounterAttack())
	{
		new botGrenades = GetPlayerWeaponSlot(client, 3);
		if (botGrenades != -1 && IsValidEntity(botGrenades)) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 13
		{
			while (botGrenades != -1 && IsValidEntity(botGrenades)) // since we only have 3 slots in current theate
			{
				botGrenades = GetPlayerWeaponSlot(client, 3);
				if (botGrenades != -1 && IsValidEntity(botGrenades)) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 1
				{
					// Remove grenades but not pistols
					decl String:weapon[32];
					GetEntityClassname(botGrenades, weapon, sizeof(weapon));
					RemovePlayerItem(client,botGrenades);
					AcceptEntityInput(botGrenades, "kill");
				}
			}
		}
	}*/
	if (!g_iCvar_respawn_enable) {
		return Plugin_Continue;
	}
	return Plugin_Continue;
}

public UpdatePlayerOrigins() {
	for (new i = 1; i <= MaxClients; i++) {
		if (IsValidClient(i)) {
			GetClientAbsOrigin(i,g_vecOrigin[i]);
		}
	}
}
//This delays bot from attacking once spawned
SetNextAttack(client) {
	float flTime = GetGameTime();
	float flDelay = g_flSpawnAttackDelay;

// Loop through entries in m_hMyWeapons.
	for(new offset = 0; offset < 128; offset += 4) {
		new weapon = GetEntDataEnt2(client, m_hMyWeapons + offset);
		if (weapon < 0) {
			continue;
		}
//		//InsLog(DEBUG, "SetNextAttack weapon %d", weapon);
		SetEntDataFloat(weapon, m_flNextPrimaryAttack, flTime + flDelay);
		SetEntDataFloat(weapon, m_flNextSecondaryAttack, flTime + flDelay);
	}
}

// When player connected server, intialize variable
public OnClientPutInServer(client)
{
	playerPickSquad[client] = 0;
	g_iHurtFatal[client] = -1;
	g_playerFirstJoin[client] = 1;
	g_iPlayerRespawnTimerActive[client] = 0;
	
	//SDKHook(client, SDKHook_PreThinkPost, SHook_OnPreThink);
	new String:sNickname[64];
	Format(sNickname, sizeof(sNickname), "%N", client);
	g_client_org_nickname[client] = sNickname;
}

public OnClientPostAdminCheck(client) 
{
    if(!IsFakeClient(client))
	{
		SDKHook(client, SDKHook_OnTakeDamageAlive, OnTakeDamage); 
	}
}

// When player connected server, intialize variables
public Action:Event_PlayerConnect(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	// Validate client index first
	if (client < 1 || client > MaxClients)
		return Plugin_Continue;
	
	playerPickSquad[client] = 0;
	g_iHurtFatal[client] = -1;
	g_playerFirstJoin[client] = 1;
	g_iPlayerRespawnTimerActive[client] = 0;
		
	
	//g_fPlayerLastChat[client] = GetGameTime();
	
	//Update RespawnCvars when players join
	UpdateRespawnCvars();
}

// When player disconnected server, intialize variables
public Action:Event_PlayerDisconnect(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0)
	{
		playerPickSquad[client] = 0;
		
		// Reset respawn timer flag
		g_iPlayerRespawnTimerActive[client] = 0;
		
		// Reset player status
		g_client_last_classstring[client] = ""; //reset his class model
		// Remove network ragdoll associated with player
		new playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
		if (playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
			RemoveRagdoll(client);
		
		// Update cvar
		UpdateRespawnCvars();
	}
	return Plugin_Continue;
}

// When round starts, intialize variables
public Action:Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{

	/*for(new i=0; i<=MaxClients; i++)
	{
		//PlayerCooldownHealing[i] = true;
		PlayerCooldownHealed[i] = true;
	}*/

	// Respawn delay for team ins
	g_fCvar_respawn_delay_team_ins = GetConVarFloat(sm_respawn_delay_team_ins);
	g_fCvar_respawn_delay_team_ins_spec = GetConVarFloat(sm_respawn_delay_team_ins_special);

	g_AIDir_TeamStatus = 50;
	g_AIDir_BotReinforceTriggered = false;

	g_iReinforceTime = GetConVarInt(sm_respawn_reinforce_time);

	g_checkStaticAmt = GetConVarInt(sm_respawn_check_static_enemy);
	g_checkStaticAmtCntr = GetConVarInt(sm_respawn_check_static_enemy_counter);

	g_secWave_Timer = g_iRespawnSeconds;
	//Round_Start CVAR Sets ------------------ END -- vs using HookConVarChange



	//Elite Bots Reset
	if (g_elite_counter_attacks == 1)
	{
		g_isEliteCounter = 0;
		EnableDisableEliteBotCvars(0, 0);
	}

	// Reset respawn position
	g_fRespawnPosition[0] = 0.0;
	g_fRespawnPosition[1] = 0.0;
	g_fRespawnPosition[2] = 0.0;
	
	// Reset respawn token
	ResetInsurgencyLives();
	ResetSecurityLives();
	
	//Hunt specific
	if (g_isHunt == 1)
	{
		g_iReinforceTime = (g_iReinforceTime * g_iReinforce_Mult) + g_iReinforce_Mult_Base;
	}

	// Check gamemode
	decl String:sGameMode[32];
	GetConVarString(FindConVar("mp_gamemode"), sGameMode, sizeof(sGameMode));
	//PrintToServer("[REVIVE_DEBUG] ROUND STARTED");
	
	// Warming up revive
	g_iEnableRevive = 0;
	new iPreRoundFirst = GetConVarInt(FindConVar("mp_timer_preround_first"));
	new iPreRound = GetConVarInt(FindConVar("mp_timer_preround"));
	if (g_preRoundInitial == true)
	{
		CreateTimer(float(iPreRoundFirst), PreReviveTimer);
		iPreRoundFirst = iPreRoundFirst + 5;
		CreateTimer(float(iPreRoundFirst), BotsReady_Timer);
		g_preRoundInitial = false;
	}
	else
	{
		CreateTimer(float(iPreRound), PreReviveTimer);
		iPreRoundFirst = iPreRound + 5;
		CreateTimer(float(iPreRound), BotsReady_Timer);
	}
	return Plugin_Continue;
}

/*public Action:YellOutHealing(client) 
{
	switch(GetRandomInt(1, 22))
	{
		case 1: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 2: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage2.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 3: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 4: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage4.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 5: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage5.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 6: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage6.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 7: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage7.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 8: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage8.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 9: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage9.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 10: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage10.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 11: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage11.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 12: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage12.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 13: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage13.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 14: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage14.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 15: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage15.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 16: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage16.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 17: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage17.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 18: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage18.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 19: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage19.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 20: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage20.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 21: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage21.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 22: EmitSoundToAll("lua_sounds/medic/letme/medic_letme_bandage22.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
	}
	return Plugin_Continue;
}*/

/*
* Cooldown for yell
*/
/*public Action:SetCooldownHealing(client) 
{
	RemoveCooldownHealing(client);

	//new Float:timedone = GetGameTime() + GetConVarFloat(CooldownPeriod);
	new Float:timedone = GetGameTime() + 15;
	PlayerTimedoneHealing[client] = timedone;
	PlayerCooldownHealing[client] = true;
}
*/
/*
* Remove cooldown for yell
*/
/*public Action:RemoveCooldownHealing(client) 
{
	PlayerCooldownHealing[client] = false;
	PlayerTimedoneHealing[client] = 0.0;
}
*/
/*public Action:YellOutHealed(client) 
{
	switch(GetRandomInt(1, 3))
	{
		case 1: EmitSoundToAll("lua_sounds/medic/healed/medic_healed15.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 2: EmitSoundToAll("lua_sounds/medic/healed/medic_healed18.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		case 3: EmitSoundToAll("lua_sounds/medic/healed/medic_healed20.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
	}
	return Plugin_Continue;
}*/

/*
* Cooldown for yell
*/
/*public Action:SetCooldownHealed(client) 
{
	RemoveCooldownHealed(client);

	//new Float:timedone = GetGameTime() + GetConVarFloat(CooldownPeriod);
	new Float:timedone = GetGameTime() + 10;
	PlayerTimedoneHealed[client] = timedone;
	PlayerCooldownHealed[client] = true;
}*/

/*
* Remove cooldown for yell
*/
/*public Action:RemoveCooldownHealed(client) 
{
	PlayerCooldownHealed[client] = false;
	PlayerTimedoneHealed[client] = 0.0;
}*/

//Adjust Lives Per Point Based On Players
void SecDynLivesPerPoint()
{
	new secTeamCount = GetTeamSecCount();
	if (secTeamCount <= 6)
	{
		g_iRespawnCount[2] += 1;
	}
}

// Round starts
public Action:PreReviveTimer(Handle:Timer)
{
	//h_PreReviveTimer = INVALID_HANDLE;
	//PrintToServer("ROUND STATUS AND REVIVE ENABLED********************");
	g_iRoundStatus = 1;
	g_iEnableRevive = 1;
}
// Botspawn trigger
public Action:BotsReady_Timer(Handle:Timer)
{
	//h_PreReviveTimer = INVALID_HANDLE;
	//PrintToServer("ROUND STATUS AND REVIVE ENABLED********************");
	g_botsReady = 1;
}
// When round ends, intialize variables
public Action:Event_RoundEnd_Pre(Handle:event, const String:name[], bool:dontBroadcast)
{
	//Show scoreboard when dead ENABLED
	//new cvar_scoreboard = FindConVar("sv_hud_scoreboard_show_score_dead");
	//SetConVarInt(cvar_scoreboard, 1, true, false);


	for (new client = 1; client <= MaxClients; client++)
	{
		if (!IsValidClient(client))
			continue;
		if (IsFakeClient(client))
			continue;
		new tTeam = GetClientTeam(client);
		if (tTeam != TEAM_1_SEC)
			continue;
		if ((g_iStatRevives[client] > 0 || g_iStatHeals[client] > 0) && StrContains(g_client_last_classstring[client], "medic") > -1)
		{
			decl String:sBuf[255];
			// Hint to iMedic
			Format(sBuf, 255,"[MEDIC STATS] for %N: HEALS: %d | REVIVES: %d", client, g_iStatHeals[client], g_iStatRevives[client]);
			PrintHintText(client, "%s", sBuf);
			PrintToChatAll("%s", sBuf);
		}

		playerInRevivedState[client] = false;
	}
	// Stop counter-attack music
	//StopCounterAttackMusic();

	//Reset Variables
	//g_removeBotGrenadeChance = 50;
}

// When round ends, intialize variables
public Action:Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Set client command for round end music
	// int iWinner = GetEventInt(event, "winner");
	// decl String:sMusicCommand[128];
	// if (iWinner == TEAM_1_SEC)
	//	Format(sMusicCommand, sizeof(sMusicCommand), "playgamesound Music.WonGame_Security");
	// else
	//	Format(sMusicCommand, sizeof(sMusicCommand), "playgamesound Music.LostGame_Insurgents");
	
	// // Play round end music
	// for (int i = 1; i <= MaxClients; i++)
	// {
	//	if (IsClientInGame(i) && IsClientConnected(i) && !IsFakeClient(i))
	//	{
	//		ClientCommand(i, "%s", sMusicCommand);
	//	}
	// }
	//Elite Bots Reset
	if (g_elite_counter_attacks == 1)
	{
		g_isEliteCounter = 0;
		EnableDisableEliteBotCvars(0, 0);
	}
	
	// Reset respawn position
	g_fRespawnPosition[0] = 0.0;
	g_fRespawnPosition[1] = 0.0;
	g_fRespawnPosition[2] = 0.0;
	
	//PrintToServer("[REVIVE_DEBUG] ROUND ENDED");	
	// Cooldown revive
	g_iEnableRevive = 0;
	g_iRoundStatus = 0;
	g_botsReady = 0;
	
	// Reset respawn token
	ResetInsurgencyLives();
	ResetSecurityLives();

	////////////////////////
	// Rank System
	// if (g_hDB != INVALID_HANDLE)
	// {
	//	for (new client=1; client<=MaxClients; client++)
	//	{
	//		if (IsClientInGame(client))
	//		{
	//			saveUser(client);
	//			CreateTimer(0.5, Timer_GetMyRank, client);
	//		}
	//	}
	// }
	////////////////////////

	//Lua Healing kill sound
	new ent = -1;
	while ((ent = FindEntityByClassname(ent, "healthkit")) > MaxClients && IsValidEntity(ent))
	{
		//StopSound(ent, SNDCHAN_STATIC, "Lua_sounds/healthkit_healing.wav");
		//PrintToServer("KILL HEALTHKITS");
		AcceptEntityInput(ent, "Kill");
	}

}

// Check occouring counter attack when control point captured
public Action:Event_ControlPointCaptured_Pre(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_checkStaticAmt = GetConVarInt(sm_respawn_check_static_enemy);
	g_checkStaticAmtCntr = GetConVarInt(sm_respawn_check_static_enemy_counter);
	// Return if conquer
	if (g_isConquer == 1 || g_isHunt == 1 || g_isOutpost) return Plugin_Continue;

	
	// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");

	//AI Director Status ###START###
	new secTeamCount = GetTeamSecCount();
	new secTeamAliveCount = Team_CountAlivePlayers(TEAM_1_SEC);

	if (g_iRespawn_lives_team_ins > 0)
		g_AIDir_TeamStatus += 10;

	if (secTeamAliveCount >= (secTeamCount * 0.8)) // If Alive Security >= 80%
		g_AIDir_TeamStatus += 10;
	else if (secTeamAliveCount >= (secTeamCount * 0.5)) // If Alive Security >= 50%
		g_AIDir_TeamStatus += 5;
	else if (secTeamAliveCount <= (secTeamCount * 0.2)) // If Dead Security <= 20%
		g_AIDir_TeamStatus -= 10;
	else if (secTeamAliveCount <= (secTeamCount * 0.5)) // If Dead Security <= 50%
		g_AIDir_TeamStatus -= 5;

	if (g_AIDir_BotReinforceTriggered)
		g_AIDir_TeamStatus -= 5;
	else
		g_AIDir_TeamStatus += 10;

	g_AIDir_BotReinforceTriggered = false;
	//AI Director Status ###END###


	// Get gamemode
	decl String:sGameMode[32];
	GetConVarString(FindConVar("mp_gamemode"), sGameMode, sizeof(sGameMode));
	
	// Init variables
	new Handle:cvar;
	
	// Set minimum and maximum counter attack duration tim
	g_counterAttack_min_dur_sec = GetConVarInt(sm_respawn_min_counter_dur_sec);
	g_counterAttack_max_dur_sec = GetConVarInt(sm_respawn_max_counter_dur_sec);
	new final_ca_dur = GetConVarInt(sm_respawn_final_counter_dur_sec);

	// Get random duration
	new fRandomInt = GetRandomInt(g_counterAttack_min_dur_sec, g_counterAttack_max_dur_sec);
	/*new fRandomIntCounterLarge = GetRandomInt(1, 100);
	new largeCounterEnabled = false;
	if (fRandomIntCounterLarge <= 15)
	{
		fRandomInt = (fRandomInt * 2);
		new fRandomInt2 = GetRandomInt(60, 90);
		final_ca_dur = (final_ca_dur + fRandomInt2);
		largeCounterEnabled = true;
		
	}*/
	// Set counter attack duration to server
	new Handle:cvar_ca_dur;
	


	// Final counter attack
	if ((acp+1) == ncp)
	{
		g_iRemaining_lives_team_ins = 0;
		
		// Use timer to break recursion and prevent stack overflow
		CreateTimer(0.1, Timer_KillBotsOnFinalPoint, _, TIMER_FLAG_NO_MAPCHANGE);
		
		//g_AIDir_TeamStatus -= 10;

		cvar_ca_dur = FindConVar("mp_checkpoint_counterattack_duration_finale");
		SetConVarInt(cvar_ca_dur, final_ca_dur, true, false);
		g_dynamicSpawnCounter_Perc += 10;

		if (g_finale_counter_spec_enabled == 1)
			g_dynamicSpawnCounter_Perc = g_finale_counter_spec_percent;

		//If endless spawning on final counter attack, add lives on finale counter on a delay
		if (g_iCvar_final_counterattack_type == 2)
		{
			int tCvar_CounterDelayValue = GetConVarInt(FindConVar("mp_checkpoint_counterattack_delay_finale"));
			CreateTimer(view_as<float>(tCvar_CounterDelayValue), Timer_FinaleCounterAssignLives, _);
		}
	}
	// Normal counter attack
	else
	{
		g_AIDir_TeamStatus -= 5;

		cvar_ca_dur = FindConVar("mp_checkpoint_counterattack_duration");
		SetConVarInt(cvar_ca_dur, fRandomInt, true, false);
	}
	
	
	// Get ramdom value for occuring counter attack
	float fRandom = GetRandomFloat(0.0, 1.0);
	//PrintToServer("Counter Chance = %f", g_respawn_counter_chance);
	// Occurs counter attack
	if (fRandom < g_respawn_counter_chance && g_isCheckpoint == 1 && ((acp+1) != ncp))
	{
		cvar = INVALID_HANDLE;
		//PrintToServer("COUNTER YES");
		cvar = FindConVar("mp_checkpoint_counterattack_disable");
		SetConVarInt(cvar, 0, true, false);
		cvar = FindConVar("mp_checkpoint_counterattack_always");
		SetConVarInt(cvar, 1, true, false);
		/*if (largeCounterEnabled)
		{
			PrintHintTextToAll("[INTEL]: Enemy forces are sending a large counter-attack your way!	Get ready to defend!");
			PrintToChatAll("[INTEL]: Enemy forces are sending a large counter-attack your way!	Get ready to defend!");
		}*/


		g_AIDir_TeamStatus -= 5;
		// Call music timer
		//CreateTimer(COUNTER_ATTACK_MUSIC_DURATION, Timer_CounterAttackSound);
		
		//Create Counter End Timer
		g_isEliteCounter = 1;
		//CreateTimer(cvar_ca_dur + 1.0, Timer_CounterAttackEnd);
		g_bIsCounterAttackTimerActive = true;
		CreateTimer(1.0, Timer_CounterAttackEnd, _, TIMER_REPEAT);

		if (g_elite_counter_attacks == 1)
		{
			EnableDisableEliteBotCvars(1, 0);
			ConVar tCvar = FindConVar("ins_bot_count_checkpoint_max");
			int tCvarIntValue = GetConVarInt(FindConVar("ins_bot_count_checkpoint_max"));
			tCvarIntValue += 3;
			SetConVarInt(tCvar, tCvarIntValue, true, false);
		}
	}
	// If last capture point
	else if (g_isCheckpoint == 1 && ((acp+1) == ncp))
	{
		cvar = INVALID_HANDLE;
		cvar = FindConVar("mp_checkpoint_counterattack_disable");
		SetConVarInt(cvar, 0, true, false);
		cvar = FindConVar("mp_checkpoint_counterattack_always");
		SetConVarInt(cvar, 1, true, false);
		
		// Call music timer
		//CreateTimer(COUNTER_ATTACK_MUSIC_DURATION, Timer_CounterAttackSound);
		
		//Create Counter End Timer
		g_isEliteCounter = 1;
		//CreateTimer(cvar_ca_dur + 1.0, Timer_CounterAttackEnd);
		g_bIsCounterAttackTimerActive = true;
		CreateTimer(1.0, Timer_CounterAttackEnd, _, TIMER_REPEAT);

		if (g_elite_counter_attacks == 1)
		{
			EnableDisableEliteBotCvars(1, 1);
			ConVar tCvar = FindConVar("ins_bot_count_checkpoint_max");
			int tCvarIntValue = GetConVarInt(FindConVar("ins_bot_count_checkpoint_max"));
			tCvarIntValue += 3;
			SetConVarInt(tCvar, tCvarIntValue, true, false);
		}
	}
	// Not occurs counter attack
	else
	{
		cvar = INVALID_HANDLE;
		//PrintToServer("COUNTER NO");
		cvar = FindConVar("mp_checkpoint_counterattack_disable");
		SetConVarInt(cvar, 1, true, false);
	}
	
	g_AIDir_TeamStatus = AI_Director_SetMinMax(g_AIDir_TeamStatus, g_AIDir_TeamStatus_min, g_AIDir_TeamStatus_max);

	return Plugin_Continue;
}

// Play music during counter-attack
public Action:Timer_CounterAttackSound(Handle:event)
{
	if (g_iRoundStatus == 0 || !Ins_InCounterAttack())
		return;
	
	// Play music
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsClientConnected(i) && !IsFakeClient(i))
		{
			//ClientCommand(i, "playgamesound Music.StartCounterAttack");
			//ClientCommand(i, "play *cues/INS_GameMusic_AboutToAttack_A.ogg");
		}
	}
	
	// Loop
	//CreateTimer(COUNTER_ATTACK_MUSIC_DURATION, Timer_CounterAttackSound);
}

// When control point captured, reset variables
// NEW FUNCTION - Kills all bots on final point capture (prevents stack overflow)
public Action:Timer_KillBotsOnFinalPoint(Handle:timer)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (i > 0 && IsClientInGame(i) && IsClientConnected(i) && IsFakeClient(i))
			ForcePlayerSuicide(i);
	}
	return Plugin_Stop;
}

public Action:Event_ControlPointCaptured(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Return if conquer
	if (g_isConquer == 1 || g_isHunt == 1 || g_isOutpost == 1) return Plugin_Continue;

	// Reset reinforcement time
	g_iReinforceTime = g_iReinforceTime_AD_Temp;
	
	// Reset respawn tokens
	ResetInsurgencyLives();
	if (g_iCvar_respawn_reset_type && g_isCheckpoint)
		ResetSecurityLives();

	//PrintToServer("CONTROL POINT CAPTURED");
	
	return Plugin_Continue;
}

// When control point captured, update respawn point and respawn all players
public Action:Event_ControlPointCaptured_Post(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Return if conquer
	if (g_isConquer == 1 || g_isHunt == 1 || g_isOutpost == 1) return Plugin_Continue; 
	
	if (GetConVarInt(sm_respawn_security_on_counter) == 1) //Test with Ins_InCounterAttack() later
	{
		// Get client who captured control point.
		new String:cappers[512];
		GetEventString(event, "cappers", cappers, sizeof(cappers));
		new cappersLength = strlen(cappers);
		
		// Find first valid human player who captured
		new clientCapper = 0;
		for (new i = 0; i < cappersLength; i++)
		{
			new client = cappers[i];  // Get byte value as potential client index
			
			// Validate before using
			if (client < 1 || client > MaxClients)
				continue;
			if (!IsClientInGame(client))
				continue;
			if (!IsPlayerAlive(client))
				continue;
			if (IsFakeClient(client))
				continue;
				
			// Found valid capper
			clientCapper = client;
			break;
		}
		
		if (clientCapper > 0)
		{
			// Get player's position
			new Float:capperPos[3];
			GetClientAbsOrigin(clientCapper, Float:capperPos);
			
			// Update respawn position
			g_fRespawnPosition = capperPos;
		}

		// Respawn all players
		for (new client = 1; client <= MaxClients; client++)
		{
			if (IsClientInGame(client) && IsClientConnected(client))
			{
				new team = GetClientTeam(client);
				new Float:clientPos[3];
				GetClientAbsOrigin(client, Float:clientPos);
				if (playerPickSquad[client] == 1 && !IsPlayerAlive(client) && team == TEAM_1_SEC)
				{
					if (!IsFakeClient(client))
					{
						if (!IsClientTimingOut(client))
							CreateCounterRespawnTimer(client);
					}
					else
					{
						CreateCounterRespawnTimer(client);
					}
				}
			}
		}
	}
	// //Elite Bots Reset
	// if (g_elite_counter_attacks == 1)
	//	CreateTimer(5.0, Timer_EliteBots);

	
	// Update cvars
	UpdateRespawnCvars();


	//Reset security team wave counter
	g_secWave_Timer = g_iRespawnSeconds;
	// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	// If last capture point
	if (g_isCheckpoint == 1 && ((acp+1) == ncp))
	{
		g_secWave_Timer = g_iRespawnSeconds;
		g_secWave_Timer += (GetTeamSecCount() * 4);
	}
	else if (Ins_InCounterAttack())
		g_secWave_Timer += (GetTeamSecCount() * 3);
	
	return Plugin_Continue;
}


// When ammo cache destroyed, update respawn position and reset variables
public Action:Event_ObjectDestroyed_Pre(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_checkStaticAmt = GetConVarInt(sm_respawn_check_static_enemy);
	g_checkStaticAmtCntr = GetConVarInt(sm_respawn_check_static_enemy_counter);
	// Return if conquer
	if (g_isConquer == 1 || g_isHunt == 1 || g_isOutpost == 1) return Plugin_Continue;


	// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");

	//AI Director Status ###START###
	new secTeamCount = GetTeamSecCount();
	new secTeamAliveCount = Team_CountAlivePlayers(TEAM_1_SEC);

	if (g_iRespawn_lives_team_ins > 0)
		g_AIDir_TeamStatus += 10;

	if (secTeamAliveCount >= (secTeamCount * 0.8)) // If Alive Security >= 80%
		g_AIDir_TeamStatus += 10;
	else if (secTeamAliveCount >= (secTeamCount * 0.5)) // If Alive Security >= 50%
		g_AIDir_TeamStatus += 5;
	else if (secTeamAliveCount <= (secTeamCount * 0.2)) // If Dead Security <= 20%
		g_AIDir_TeamStatus -= 10;
	else if (secTeamAliveCount <= (secTeamCount * 0.5)) // If Dead Security <= 50%
		g_AIDir_TeamStatus -= 5;

	if (g_AIDir_BotReinforceTriggered)
		g_AIDir_TeamStatus += 10;
	else
		g_AIDir_TeamStatus -= 5;

	g_AIDir_BotReinforceTriggered = false;

	//AI Director Status ###END###

	// Get gamemode
	decl String:sGameMode[32];
	GetConVarString(FindConVar("mp_gamemode"), sGameMode, sizeof(sGameMode));
	
	// Init variables
	new Handle:cvar;
	
	// Set minimum and maximum counter attack duration tim
	g_counterAttack_min_dur_sec = GetConVarInt(sm_respawn_min_counter_dur_sec);
	g_counterAttack_max_dur_sec = GetConVarInt(sm_respawn_max_counter_dur_sec);
	new final_ca_dur = GetConVarInt(sm_respawn_final_counter_dur_sec);

	// Get random duration
	new fRandomInt = GetRandomInt(g_counterAttack_min_dur_sec, g_counterAttack_max_dur_sec);
	/*new fRandomIntCounterLarge = GetRandomInt(1, 100);
	new largeCounterEnabled = false;
	if (fRandomIntCounterLarge <= 15)
	{
		fRandomInt = (fRandomInt * 2);
		new fRandomInt2 = GetRandomInt(90, 180);
		final_ca_dur = (final_ca_dur + fRandomInt2);
		largeCounterEnabled = true;
	}*/
	// Set counter attack duration to server
	new Handle:cvar_ca_dur;
	
	// Final counter attack
	if ((acp+1) == ncp)
	{
		cvar_ca_dur = FindConVar("mp_checkpoint_counterattack_duration_finale");
		SetConVarInt(cvar_ca_dur, final_ca_dur, true, false);
		g_dynamicSpawnCounter_Perc += 10;
		//g_AIDir_TeamStatus -= 10;

		if (g_finale_counter_spec_enabled == 1)
				g_dynamicSpawnCounter_Perc = g_finale_counter_spec_percent;
	}
	// Normal counter attack
	else
	{
		g_AIDir_TeamStatus -= 5;
		cvar_ca_dur = FindConVar("mp_checkpoint_counterattack_duration");
		SetConVarInt(cvar_ca_dur, fRandomInt, true, false);
	}
	
	//Are we using vanilla counter attack?
	if (g_iCvar_counterattack_vanilla == 1) return Plugin_Continue;

	// Get ramdom value for occuring counter attack
	new Float:fRandom = GetRandomFloat(0.0, 1.0);
	//PrintToServer("Counter Chance = %f", g_respawn_counter_chance);
	// Occurs counter attack
	if (fRandom < g_respawn_counter_chance && g_isCheckpoint && ((acp+1) != ncp))
	{
		cvar = INVALID_HANDLE;
		//PrintToServer("COUNTER YES");
		cvar = FindConVar("mp_checkpoint_counterattack_disable");
		SetConVarInt(cvar, 0, true, false);
		cvar = FindConVar("mp_checkpoint_counterattack_always");
		SetConVarInt(cvar, 1, true, false);
		/*if (largeCounterEnabled)
		{
			PrintHintTextToAll("[INTEL]: Enemy forces are sending a large counter-attack your way!	Get ready to defend!");
			PrintToChatAll("[INTEL]: Enemy forces are sending a large counter-attack your way!	Get ready to defend!");
		}*/
		g_AIDir_TeamStatus -= 5;
		// Call music timer
		//CreateTimer(COUNTER_ATTACK_MUSIC_DURATION, Timer_CounterAttackSound);

		//Create Counter End Timer
		g_isEliteCounter = 1;
		//CreateTimer(cvar_ca_dur + 1.0, Timer_CounterAttackEnd);
		g_bIsCounterAttackTimerActive = true;
		CreateTimer(1.0, Timer_CounterAttackEnd, _, TIMER_REPEAT);

		if (g_elite_counter_attacks == 1)
		{
			EnableDisableEliteBotCvars(1, 0);
			ConVar tCvar = FindConVar("ins_bot_count_checkpoint_max");
			int tCvarIntValue = GetConVarInt(FindConVar("ins_bot_count_checkpoint_max"));
			tCvarIntValue += 3;
			SetConVarInt(tCvar, tCvarIntValue, true, false);
		}
	}
	// If last capture point
	else if (g_isCheckpoint == 1 && ((acp+1) == ncp))
	{
		cvar = INVALID_HANDLE;
		cvar = FindConVar("mp_checkpoint_counterattack_disable");
		SetConVarInt(cvar, 0, true, false);
		cvar = FindConVar("mp_checkpoint_counterattack_always");
		SetConVarInt(cvar, 1, true, false);
		
		// Call music timer
		//CreateTimer(COUNTER_ATTACK_MUSIC_DURATION, Timer_CounterAttackSound);
		
		// Call counter-attack end timer
		if (!g_bIsCounterAttackTimerActive)
		{
		g_isEliteCounter = 1;
		//CreateTimer(cvar_ca_dur + 1.0, Timer_CounterAttackEnd);
		g_bIsCounterAttackTimerActive = true;
		CreateTimer(1.0, Timer_CounterAttackEnd, _, TIMER_REPEAT);
		}
		if (g_elite_counter_attacks == 1)
		{
			EnableDisableEliteBotCvars(1, 1);
			ConVar tCvar = FindConVar("ins_bot_count_checkpoint_max");
			int tCvarIntValue = GetConVarInt(FindConVar("ins_bot_count_checkpoint_max"));
			tCvarIntValue += 3;
			SetConVarInt(tCvar, tCvarIntValue, true, false);
		}
	}
	// Not occurs counter attack
	else
	{
		cvar = INVALID_HANDLE;
		//PrintToServer("COUNTER NO");
		cvar = FindConVar("mp_checkpoint_counterattack_disable");
		SetConVarInt(cvar, 1, true, false);
	}

	g_AIDir_TeamStatus = AI_Director_SetMinMax(g_AIDir_TeamStatus, g_AIDir_TeamStatus_min, g_AIDir_TeamStatus_max);

	return Plugin_Continue;
}

// When ammo cache destroyed, update respawn position and reset variables
public Action:Event_ObjectDestroyed(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Checkpoint
	if (g_isCheckpoint == 1)
	{
		g_cacheObjActive = 1;
		
		// Update respawn position
		new attacker = GetEventInt(event, "attacker");
		new assister = GetEventInt(event, "assister");

		if (attacker > 0 && IsClientInGame(attacker) && IsClientConnected(attacker) || assister > 0 && IsClientInGame(assister) && IsClientConnected(assister))
		{
			new Float:attackerPos[3];
			GetClientAbsOrigin(attacker, Float:attackerPos);
			g_fRespawnPosition = attackerPos;
		}
		
		// Reset reinforcement time
		g_iReinforceTime = g_iReinforceTime_AD_Temp;
		
		// Reset respawn token
		ResetInsurgencyLives();
		if (g_iCvar_respawn_reset_type && g_isCheckpoint)
			ResetSecurityLives();
	}
	
	// Conquer, Respawn all players
	else if (g_isConquer == 1 || g_isHunt == 1)
	{
		for (new client = 1; client <= MaxClients; client++)
		{	
			if (IsClientConnected(client) && !IsFakeClient(client) && IsClientConnected(client))
			{
				new team = GetClientTeam(client);
				if(IsClientInGame(client) && !IsClientTimingOut(client) && playerPickSquad[client] == 1 && !IsPlayerAlive(client) && team == TEAM_1_SEC)
				{
					CreateCounterRespawnTimer(client);
				}
			}
		}
	}
	
	return Plugin_Continue;
}
// When control point captured, update respawn point and respawn all players
public Action:Event_ObjectDestroyed_Post(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Return if conquer
	if (g_isConquer == 1 || g_isHunt == 1 || g_isOutpost == 1) return Plugin_Continue; 
	
	if (GetConVarInt(sm_respawn_security_on_counter) == 1)
	{
		// Get client who captured control point.
		new String:cappers[512];
		GetEventString(event, "cappers", cappers, sizeof(cappers));
		new cappersLength = strlen(cappers);
		
		// Find first valid human player who captured
		new clientCapper = 0;
		for (new i = 0; i < cappersLength; i++)
		{
			new client = cappers[i];  // Get byte value as potential client index
			
			// Validate before using
			if (client < 1 || client > MaxClients)
				continue;
			if (!IsClientInGame(client))
				continue;
			if (!IsPlayerAlive(client))
				continue;
			if (IsFakeClient(client))
				continue;
				
			// Found valid capper
			clientCapper = client;
			break;
		}
		
		if (clientCapper > 0)
		{
			// Get player's position
			new Float:capperPos[3];
			GetClientAbsOrigin(clientCapper, Float:capperPos);
			
			// Update respawn position
			g_fRespawnPosition = capperPos;
		}

		// Respawn all players
		for (new client = 1; client <= MaxClients; client++)
		{
			if (IsClientInGame(client) && IsClientConnected(client))
			{
				new team = GetClientTeam(client);
				new Float:clientPos[3];
				GetClientAbsOrigin(client, Float:clientPos);
				if (playerPickSquad[client] == 1 && !IsPlayerAlive(client) && team == TEAM_1_SEC)
				{
					if (!IsFakeClient(client))
					{
						if (!IsClientTimingOut(client))
							CreateCounterRespawnTimer(client);
					}
					else
					{
						CreateCounterRespawnTimer(client);
					}
				}
			}
		}
	}
	

	// //Elite Bots Reset
	// if (g_elite_counter_attacks == 1)
	//	CreateTimer(5.0, Timer_EliteBots);
	//PrintToServer("CONTROL POINT CAPTURED POST");

	// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	// If last capture point
	if (g_isCheckpoint == 1 && ((acp+1) == ncp))
	{
		g_secWave_Timer = g_iRespawnSeconds;
		g_secWave_Timer += (GetTeamSecCount() * 4);
	}
	else if (Ins_InCounterAttack())
		g_secWave_Timer += (GetTeamSecCount() * 3);

	return Plugin_Continue;
}

public OnWeaponReload(weapon, bool:bSuccessful)
{
	if (bSuccessful)
	{
	PrintToChatAll("reload success");
	}
}

//Enable/Disable Elite Bots
void EnableDisableEliteBotCvars(tEnabled, isFinale)
{
	float tCvarFloatValue;
	int tCvarIntValue;
	Handle tCvar;

	if (tEnabled == 1)
	{
		//PrintToServer("BOT_SETTINGS_APPLIED");
		if (isFinale == 1)
		{
			tCvar = FindConVar("mp_player_resupply_coop_delay_max");
			SetConVarInt(tCvar, g_coop_delay_penalty_base, true, false);
			tCvar = FindConVar("mp_player_resupply_coop_delay_penalty");
			SetConVarInt(tCvar, g_coop_delay_penalty_base, true, false);
			tCvar = FindConVar("mp_player_resupply_coop_delay_base");
			SetConVarInt(tCvar, g_coop_delay_penalty_base, true, false);
		}

		tCvar = FindConVar("bot_attackdelay_frac_difficulty_impossible");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_attackdelay_frac_difficulty_impossible"));
		tCvarFloatValue = tCvarFloatValue - g_bot_attackdelay_frac_difficulty_impossible_mult;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);

		tCvar = FindConVar("bot_attack_aimpenalty_amt_close");
		tCvarIntValue = GetConVarInt(FindConVar("bot_attack_aimpenalty_amt_close"));
		tCvarIntValue = tCvarIntValue - g_bot_attack_aimpenalty_amt_close_mult;
		SetConVarInt(tCvar, tCvarIntValue, true, false);

		tCvar = FindConVar("bot_attack_aimpenalty_amt_far");
		tCvarIntValue = GetConVarInt(FindConVar("bot_attack_aimpenalty_amt_far"));
		tCvarIntValue = tCvarIntValue - g_bot_attack_aimpenalty_amt_far_mult;
		SetConVarInt(tCvar, tCvarIntValue, true, false);

		tCvar = FindConVar("bot_attack_aimpenalty_time_close");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_attack_aimpenalty_time_close"));
		tCvarFloatValue = tCvarFloatValue - g_bot_attack_aimpenalty_time_close_mult;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);

		tCvar = FindConVar("bot_attack_aimpenalty_time_far");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_attack_aimpenalty_time_far"));
		tCvarFloatValue = tCvarFloatValue - g_bot_attack_aimpenalty_time_far_mult;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);

		tCvar = FindConVar("bot_attack_aimtolerance_newthreat_amt");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_attack_aimtolerance_newthreat_amt"));
		tCvarFloatValue = tCvarFloatValue - g_bot_attack_aimtolerance_newthreat_amt_mult;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);

		tCvar = FindConVar("bot_aim_aimtracking_base");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_aim_aimtracking_base"));
		tCvarFloatValue = tCvarFloatValue - g_bot_aim_aimtracking_base;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);

		tCvar = FindConVar("bot_aim_aimtracking_frac_impossible");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_aim_aimtracking_frac_impossible"));
		tCvarFloatValue = tCvarFloatValue - g_bot_aim_aimtracking_frac_impossible;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);

		tCvar = FindConVar("bot_aim_angularvelocity_frac_impossible");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_aim_angularvelocity_frac_impossible"));
		tCvarFloatValue = tCvarFloatValue + g_bot_aim_angularvelocity_frac_impossible;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);

		tCvar = FindConVar("bot_aim_angularvelocity_frac_sprinting_target");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_aim_angularvelocity_frac_sprinting_target"));
		tCvarFloatValue = tCvarFloatValue + g_bot_aim_angularvelocity_frac_sprinting_target;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);

		tCvar = FindConVar("bot_aim_attack_aimtolerance_frac_impossible");
		tCvarFloatValue = GetConVarFloat(FindConVar("bot_aim_attack_aimtolerance_frac_impossible"));
		tCvarFloatValue = tCvarFloatValue - g_bot_aim_attack_aimtolerance_frac_impossible;
		SetConVarFloat(tCvar, tCvarFloatValue, true, false);
		//Make sure to check for FLOATS vs INTS and +/-!
	}
	else
	{
		//PrintToServer("BOT_SETTINGS_APPLIED_2");

		tCvar = FindConVar("ins_bot_count_checkpoint_max");
		SetConVarInt(tCvar, g_ins_bot_count_checkpoint_max_org, true, false);
		tCvar = FindConVar("mp_player_resupply_coop_delay_max");
		SetConVarInt(tCvar, g_mp_player_resupply_coop_delay_max_org, true, false);
		tCvar = FindConVar("mp_player_resupply_coop_delay_penalty");
		SetConVarInt(tCvar, g_mp_player_resupply_coop_delay_penalty_org, true, false);
		tCvar = FindConVar("mp_player_resupply_coop_delay_base");
		SetConVarInt(tCvar, g_mp_player_resupply_coop_delay_base_org, true, false);
		tCvar = FindConVar("bot_attackdelay_frac_difficulty_impossible");
		SetConVarFloat(tCvar, g_bot_attackdelay_frac_difficulty_impossible_org, true, false);
		tCvar = FindConVar("bot_attack_aimpenalty_amt_close");
		SetConVarInt(tCvar, g_bot_attack_aimpenalty_amt_close_org, true, false);
		tCvar = FindConVar("bot_attack_aimpenalty_amt_far");
		SetConVarInt(tCvar, g_bot_attack_aimpenalty_amt_far_org, true, false);
		tCvar = FindConVar("bot_attack_aimpenalty_time_close");
		SetConVarFloat(tCvar, g_bot_attack_aimpenalty_time_close_org, true, false);
		tCvar = FindConVar("bot_attack_aimpenalty_time_far");
		SetConVarFloat(tCvar, g_bot_attack_aimpenalty_time_far_org, true, false);
		tCvar = FindConVar("bot_attack_aimtolerance_newthreat_amt");
		SetConVarFloat(tCvar, g_bot_attack_aimtolerance_newthreat_amt_org, true, false);

		tCvar = FindConVar("bot_aim_aimtracking_base");
		SetConVarFloat(tCvar, g_bot_aim_aimtracking_base_org, true, false);
		tCvar = FindConVar("bot_aim_aimtracking_frac_impossible");
		SetConVarFloat(tCvar, g_bot_aim_aimtracking_frac_impossible_org, true, false);
		tCvar = FindConVar("bot_aim_angularvelocity_frac_impossible");
		SetConVarFloat(tCvar, g_bot_aim_angularvelocity_frac_impossible_org, true, false);
		tCvar = FindConVar("bot_aim_angularvelocity_frac_sprinting_target");
		SetConVarFloat(tCvar, g_bot_aim_angularvelocity_frac_sprinting_target_org, true, false);
		tCvar = FindConVar("bot_aim_attack_aimtolerance_frac_impossible");
		SetConVarFloat(tCvar, g_bot_aim_attack_aimtolerance_frac_impossible_org, true, false);

	}
}

// On finale counter attack, add lives back to insurgents to trigger unlimited respawns (this is redundant code now and may use for something else)
public Action:Timer_FinaleCounterAssignLives(Handle:Timer)
{
	if (g_iCvar_final_counterattack_type == 2)
	{
			// Reset remaining lives for bots
			g_iRemaining_lives_team_ins = g_iRespawn_lives_team_ins;
	}
}

// When counter-attack end, reset reinforcement time
public Action:Timer_CounterAttackEnd(Handle:Timer)
{
	// If round end, exit
	if (g_iRoundStatus == 0)
	{
		// Stop counter-attack music
		//StopCounterAttackMusic();
		
		// Reset variable
		g_bIsCounterAttackTimerActive = false;
		return Plugin_Stop;
	}
	//Disable elite bots when not in counter
	if (g_isEliteCounter == 1 && g_elite_counter_attacks == 1)
	{
		g_isEliteCounter = 0;
		EnableDisableEliteBotCvars(0, 0);
	}
	// Check counter-attack end
	if (!Ins_InCounterAttack())
	{
		// Reset reinforcement time
		g_iReinforceTime = g_iReinforceTime_AD_Temp;
		
		// Reset respawn token
		ResetInsurgencyLives();
		if (g_iCvar_respawn_reset_type && g_isCheckpoint)
			ResetSecurityLives();
		
		// Stop counter-attack music
		//StopCounterAttackMusic();
		
		// Reset variable
		g_bIsCounterAttackTimerActive = false;
		
		new Handle:cvar = INVALID_HANDLE;
		cvar = FindConVar("mp_checkpoint_counterattack_always");
		SetConVarInt(cvar, 0, true, false);

		//PrintToServer("[RESPAWN] Counter-attack is over.");
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}

//Run this to mark a bot as ready to spawn. Add tokens if you want them to be able to spawn.
void ResetSecurityLives()
{
	// Return if respawn is disabled
	if (!g_iCvar_respawn_enable) return;
	
	// Update cvars
	UpdateRespawnCvars();

	if (g_isCheckpoint)
	{
		//If spawned per point, give more per-point lives based on team count.
		if (g_iCvar_respawn_reset_type == 1)
			SecDynLivesPerPoint();
	}
	// Individual lives
	if (g_iCvar_respawn_type_team_sec == 1)
	{
		for (new client = 1; client <= MaxClients; client++)
		{
			// Check valid player
			if (client > 0 && IsClientInGame(client))
			{
				//Reset Medic Stats:
				g_playerMedicRevivessAccumulated[client] = 0;
				g_playerMedicHealsAccumulated[client] = 0;
				g_playerNonMedicHealsAccumulated[client] = 0;
				
				// Check Team
				new iTeam = GetClientTeam(client);
				if (iTeam != TEAM_1_SEC)
					continue;

				//Bonus lives for conquer/outpost
				if (g_isConquer == 1 || g_isOutpost == 1 || g_isHunt == 1)
					g_iSpawnTokens[client] = g_iRespawnCount[iTeam] + 10;
				else
				{
					// Individual SEC lives
					if (g_isCheckpoint == 1 && g_iCvar_respawn_type_team_sec == 1)
					{
						// Reset remaining lives for player
						g_iSpawnTokens[client] = g_iRespawnCount[iTeam];
					}
				}
			}
		}
	}
	
	// Team lives
	if (g_iCvar_respawn_type_team_sec == 2)
	{
		// Reset remaining lives for player
		g_iRemaining_lives_team_sec = g_iRespawn_lives_team_sec;
	}
}

//Run this to mark a bot as ready to spawn. Add tokens if you want them to be able to spawn.
void ResetInsurgencyLives()
{
	// Disable if counquer
	//if (g_isConquer == 1 || g_isOutpost == 1) return;
	
	// Return if respawn is disabled
	if (!g_iCvar_respawn_enable) return;
	
	// Update cvars
	UpdateRespawnCvars();
	
	// Individual lives
	if (g_iCvar_respawn_type_team_ins == 1)
	{
		for (new client = 1; client <= MaxClients; client++)
		{
			// Check valid player
			if (client > 0 && IsClientInGame(client))
			{
				// Check Team
				new iTeam = GetClientTeam(client);
				if (iTeam != TEAM_2_INS)
					continue;
				
				//Bonus lives for conquer/outpost
				if (g_isConquer == 1 || g_isOutpost == 1 || g_isHunt == 1)
					g_iSpawnTokens[client] = g_iRespawnCount[iTeam] + 10;
				else
				g_iSpawnTokens[client] = g_iRespawnCount[iTeam];
			}
		}
	}
	
	// Team lives
	if (g_iCvar_respawn_type_team_ins == 2)
	{
		// Reset remaining lives for bots
		g_iRemaining_lives_team_ins = g_iRespawn_lives_team_ins;
	}
}

// When player picked squad, initialize variables
public Action:Event_PlayerPickSquad_Post( Handle:event, const String:name[], bool:dontBroadcast )
{
	//"squad_slot" "byte"
	//"squad" "byte"
	//"userid" "short"
	//"class_template" "string"
	//PrintToServer("##########PLAYER IS PICKING SQUAD!############");
	
	// Get client ID
	new client = GetClientOfUserId( GetEventInt( event, "userid" ) );
	
	// Get class name
	decl String:class_template[64];
	GetEventString(event, "class_template", class_template, sizeof(class_template));
	
	// Set class string
	g_client_last_classstring[client] = class_template;

	if( client == 0 || !IsClientInGame(client) || IsFakeClient(client))
		return;	
	// Init variable
	playerPickSquad[client] = 1;
	
	// If player changed squad and remain ragdoll
	new team = GetClientTeam(client);
	if (client > 0 && IsClientInGame(client) && IsClientObserver(client) && !IsPlayerAlive(client) && g_iHurtFatal[client] == 0 && team == TEAM_1_SEC)
	{
		// Remove ragdoll
		new playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
		if(playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
			RemoveRagdoll(client);
		
		// Init variable
		g_iHurtFatal[client] = -1;
	}

	// Get player nickname
	decl String:sNewNickname[64];

	// Medic class
	if (StrContains(g_client_last_classstring[client], "medic") > -1)
	{
		// Admin medic
		if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_BAN))
			Format(sNewNickname, sizeof(sNewNickname), "[ADMIN][MEDIC] %s", g_client_org_nickname[client]);
		// Donor medic
		else if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_RESERVATION))
			Format(sNewNickname, sizeof(sNewNickname), "[DONOR][MEDIC] %s", g_client_org_nickname[client]);
		// Normal medic
		else
			Format(sNewNickname, sizeof(sNewNickname), "[MEDIC] %s", g_client_org_nickname[client]);
	}
	else if (StrContains(g_client_last_classstring[client], "engineer") > -1)
	{
		// Admin medic
		if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_BAN))
			Format(sNewNickname, sizeof(sNewNickname), "[ADMIN][ENG] %s", g_client_org_nickname[client]);
		// Donor medic
		else if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_RESERVATION))
			Format(sNewNickname, sizeof(sNewNickname), "[DONOR][ENG] %s", g_client_org_nickname[client]);
		// Normal medic
		else
			Format(sNewNickname, sizeof(sNewNickname), "[ENG] %s", g_client_org_nickname[client]);
	}
	else if (StrContains(g_client_last_classstring[client], "mg") > -1)
	{
		// Admin medic
		if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_ROOT))
			Format(sNewNickname, sizeof(sNewNickname), "[ADMIN][MG] %s", g_client_org_nickname[client]);
		// Donor medic
		else if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_RESERVATION))
			Format(sNewNickname, sizeof(sNewNickname), "[DONOR][MG] %s", g_client_org_nickname[client]);
		// Normal medic
		else
			Format(sNewNickname, sizeof(sNewNickname), "[MG] %s", g_client_org_nickname[client]);
	}
	else if (StrContains(g_client_last_classstring[client], "vip") > -1)
	{
		// Admin medic
		if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_ROOT))
			Format(sNewNickname, sizeof(sNewNickname), "[ADMIN][VIP] %s", g_client_org_nickname[client]);
		// Donor medic
		else if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_RESERVATION))
			Format(sNewNickname, sizeof(sNewNickname), "[DONOR][VIP] %s", g_client_org_nickname[client]);
		// Normal medic
		else
			Format(sNewNickname, sizeof(sNewNickname), "[VIP] %s", g_client_org_nickname[client]);
	}
	// Normal class
	else
	{
		// Admin
		if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_BAN))
			Format(sNewNickname, sizeof(sNewNickname), "[ADMIN] %s", g_client_org_nickname[client]);
		// Donor
		else if (GetConVarInt(sm_respawn_enable_donor_tag) == 1 && (GetUserFlagBits(client) & ADMFLAG_RESERVATION))
			Format(sNewNickname, sizeof(sNewNickname), "[DONOR] %s", g_client_org_nickname[client]);
		// Normal player
		else
			Format(sNewNickname, sizeof(sNewNickname), "%s", g_client_org_nickname[client]);
	}
	
	// Set player nickname
	decl String:sCurNickname[64];
	Format(sCurNickname, sizeof(sCurNickname), "%N", client);
	if (!StrEqual(sCurNickname, sNewNickname))
		SetClientName(client, sNewNickname);
	
	g_playersReady = true;

	//Allow new players to use lives to respawn on join
	if (g_iRoundStatus == 1 && g_playerFirstJoin[client] == 1 && !IsPlayerAlive(client) && team == TEAM_1_SEC)
	{
		// Get SteamID to verify is player has connected before.
		decl String:steamId[64];
		//GetClientAuthString(client, steamId, sizeof(steamId));
		GetClientAuthId(client, AuthId_Steam3, steamId, sizeof(steamId));
		new isPlayerNew = FindStringInArray(g_playerArrayList, steamId);

		if (isPlayerNew != -1)
		{
			PrintToServer("Player %N has reconnected! | SteamID: %s | Index: %d", client, steamId, isPlayerNew);
		}
		else
		{
			PushArrayString(g_playerArrayList, steamId);
			PrintToServer("Player %N is new! | SteamID: %s | PlayerArrayList Size: %d", client, steamId, GetArraySize(g_playerArrayList));
			// Give individual lives to new player (no longer just at beginning of round)
			if (g_iCvar_respawn_type_team_sec == 1)
			{	
				if (g_isCheckpoint && g_iCvar_respawn_reset_type == 0)
				{
					// The number of control points
					new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
					// Active control poin
					new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
					new tLiveSec = GetConVarInt(sm_respawn_lives_team_sec);

					if (acp <= (ncp / 2))
						g_iSpawnTokens[client] = tLiveSec;
					else
						g_iSpawnTokens[client] = (tLiveSec / 2);

					if (tLiveSec < 1)
					{
						tLiveSec = 1;
						g_iSpawnTokens[client] = tLiveSec;
					}
				}
				else
					g_iSpawnTokens[client] = GetConVarInt(sm_respawn_lives_team_sec);

			
			}
			CreatePlayerRespawnTimer(client);
		}
	}
	//Update RespawnCvars when player picks squad
	UpdateRespawnCvars();
}

// Triggers when player hurt
public Action:Event_PlayerHurt_Pre(Handle:event, const String:name[], bool:dontBroadcast)
{
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));
	
	// Validate client index first
	if (victim < 1 || victim > MaxClients)
		return Plugin_Continue;
	if (!IsClientInGame(victim))
		return Plugin_Continue;
	if (IsFakeClient(victim))
		return Plugin_Continue;

	new victimHealth = GetEventInt(event, "health");
	new dmg_taken = GetEventInt(event, "dmg_health");
	//PrintToServer("victimHealth: %d, dmg_taken: %d", victimHealth, dmg_taken);
	if (g_fCvar_fatal_chance > 0.0 && dmg_taken > victimHealth)
	{
		// Get information for event structure
		new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
		new hitgroup = GetEventInt(event, "hitgroup");
		
		// Update last damege (related to 'hurt_fatal')
		g_clientDamageDone[victim] = dmg_taken;
		
		// Get weapon
		decl String:weapon[32];
		GetEventString(event, "weapon", weapon, sizeof(weapon));
		
		//PrintToServer("[DAMAGE TAKEN] Weapon used: %s, Damage done: %i",weapon, dmg_taken);
		
		// Check is team attack
		new attackerTeam;
		if (attacker > 0 && IsClientInGame(attacker) && IsClientConnected(attacker))
			attackerTeam = GetClientTeam(attacker);
		
		// Get fatal chance
		new Float:fRandom = GetRandomFloat(0.0, 1.0);
		
		// Is client valid
		if (IsClientInGame(victim))
		{
			
			// Explosive
			if (hitgroup == 0)
			{
				//explosive list
				//incens
				//grenade_molotov, grenade_anm14
				//PrintToServer("[HITGROUP HURT BURN]");
				//grenade_m67, grenade_f1, grenade_ied, grenade_c4, rocket_rpg7, rocket_at4, grenade_gp25_he, grenade_m203_he	
				if (StrEqual(weapon, "grenade_anm14", false) || StrEqual(weapon, "grenade_molotov", false) || 
                    StrEqual(weapon, "grenade_m203_incid", false) || 
                    StrEqual(weapon, "grenade_gp25_incid", false) || 
                    StrEqual(weapon, "grenade_m79_incen", false))
				{
					//PrintToServer("[SUICIDE] incen/molotov DETECTED!");
					if (dmg_taken >= g_iCvar_fatal_burn_dmg && (fRandom <= g_fCvar_fatal_chance))
					{
						// Hurt fatally
						g_iHurtFatal[victim] = 1;
						
						//PrintToServer("[PLAYER HURT BURN]");
					}
				}
				// explosive
				else if (StrEqual(weapon, "grenade_m67", false) || 
					StrEqual(weapon, "grenade_f1", false) || 
					StrEqual(weapon, "grenade_ied", false) || 
					StrEqual(weapon, "grenade_c4", false) || 
					StrEqual(weapon, "rocket_rpg7", false) || 
					StrEqual(weapon, "rocket_at4", false) || 
					StrEqual(weapon, "grenade_gp25_he", false) || 
					StrEqual(weapon, "grenade_m203_he", false) || 
                    StrEqual(weapon, "grenade_m26a2", false) || 
                    StrEqual(weapon, "grenade_c4_radius", false) || 
                    StrEqual(weapon, "grenade_ied_radius", false) || 
                    StrEqual(weapon, "grenade_ied_gunshot", false) || 
                    StrEqual(weapon, "grenade_ied_fire", false) || 
                    StrEqual(weapon, "grenade_ied_fire_bomber", false) || 
                    StrEqual(weapon, "grenade_m79", false))
				{
					//PrintToServer("[HITGROUP HURT EXPLOSIVE]");
					if (dmg_taken >= g_iCvar_fatal_explosive_dmg && (fRandom <= g_fCvar_fatal_chance))
					{
						// Hurt fatally
						g_iHurtFatal[victim] = 1;
						
						//PrintToServer("[PLAYER HURT EXPLOSIVE]");
					}
				}
				//PrintToServer("[SUICIDE] HITRGOUP 0 [GENERIC]");
			}
			// Headshot
			else if (hitgroup == 1)
			{
				//PrintToServer("[PLAYER HURT HEAD]");
				if (dmg_taken >= g_iCvar_fatal_head_dmg && (fRandom <= g_fCvar_fatal_head_chance) && attackerTeam != TEAM_1_SEC)
				{
					// Hurt fatally
					g_iHurtFatal[victim] = 1;
					
					//PrintToServer("[BOTSPAWNS] BOOM HEADSHOT");
				}
			}
			// Chest
			else if (hitgroup == 2 || hitgroup == 3)
			{
				//PrintToServer("[HITGROUP HURT CHEST]");
				if (dmg_taken >= g_iCvar_fatal_chest_stomach && (fRandom <= g_fCvar_fatal_chance))
				{
					// Hurt fatally
					g_iHurtFatal[victim] = 1;
					
					//PrintToServer("[PLAYER HURT CHEST]");
				}
			}
			// Limbs
			else if (hitgroup == 4 || hitgroup == 5	 || hitgroup == 6 || hitgroup == 7)
			{
				//PrintToServer("[HITGROUP HURT LIMBS]");
				if (dmg_taken >= g_iCvar_fatal_limb_dmg && (fRandom <= g_fCvar_fatal_chance))
				{
					// Hurt fatally
					g_iHurtFatal[victim] = 1;
					
					//PrintToServer("[PLAYER HURT LIMBS]");
				}
			}
		}
	}
	//Track wound type (minor, moderate, critical)
	if (g_iHurtFatal[victim] != 1)
	{
		if (dmg_taken <= g_minorWound_dmg)
		{
			g_playerWoundTime[victim] = g_minorRevive_time;
			g_playerWoundType[victim] = 0;
		}
		else if (dmg_taken > g_minorWound_dmg && dmg_taken <= g_moderateWound_dmg)
		{
			g_playerWoundTime[victim] = g_modRevive_time;
			g_playerWoundType[victim] = 1;
		}
		else if (dmg_taken > g_moderateWound_dmg)
		{
			g_playerWoundTime[victim] = g_critRevive_time;
			g_playerWoundType[victim] = 2;
		}
	}
	else
	{
		g_playerWoundTime[victim] = -1;
		g_playerWoundType[victim] = -1;
	}
	return Plugin_Continue;
}

// Trigged when player die PRE
public Action:Event_PlayerDeath_Pre(Handle:event, const String:name[], bool:dontBroadcast)
{
		new client = GetClientOfUserId(GetEventInt(event, "userid"));
		
		// Validate client index first
		if (client < 1 || client > MaxClients)
			return Plugin_Continue;
		if (!IsClientInGame(client))
			return Plugin_Continue;
		
		// Tracking ammo
		if (g_iEnableRevive == 1 && g_iRoundStatus == 1 && g_iCvar_enable_track_ammo == 1)
		{
			//PrintToChatAll("### GET PLAYER WEAPONS ###");
			//CONSIDER IF PLAYER CHOOSES DIFFERENT CLASS
			// Get weapons
			new primaryWeapon = GetPlayerWeaponSlot(client, 0);
			new secondaryWeapon = GetPlayerWeaponSlot(client, 1);
			//new playerGrenades = GetPlayerWeaponSlot(client, 3);
			
			// Set weapons to variables
			playerPrimary[client] = primaryWeapon;
			playerSecondary[client] = secondaryWeapon;
			
			//Get ammo left in clips for primary and secondary
			playerClip[client][0] = GetPrimaryAmmo(primaryWeapon, 0);
			playerClip[client][1] = GetPrimaryAmmo(secondaryWeapon, 1); // m_iClip2 for secondary if this doesnt work? would need GetSecondaryAmmo
			
			if (!playerInRevivedState[client])
			{
				//Get Magazines left on player
				if (primaryWeapon != -1 && IsValidEntity(primaryWeapon))
					 Client_GetWeaponPlayerAmmoEx(client, primaryWeapon, playerAmmo[client][0]); //primary
				if (secondaryWeapon != -1 && IsValidEntity(secondaryWeapon))
					 Client_GetWeaponPlayerAmmoEx(client, secondaryWeapon, playerAmmo[client][1]); //secondary	
			}	
			playerInRevivedState[client] = false;
			//PrintToServer("PlayerClip_1 %i, PlayerClip_2 %i, playerAmmo_1 %i, playerAmmo_2 %i, playerGrenades %i",playerClip[client][0], playerClip[client][1], playerAmmo[client][0], playerAmmo[client][1], playerAmmo[client][2]); 
			// if (playerGrenades != -1 && IsValidEntity(playerGrenades))
			// {
			//	 playerGrenadeType[victim][0] = GetGrenadeAmmo(victim, Gren_M67);
			//	 playerGrenadeType[victim][1] = GetGrenadeAmmo(victim, Gren_Incen);
			//	 playerGrenadeType[victim][2] = GetGrenadeAmmo(victim, Gren_Molot);
			//	 playerGrenadeType[victim][3] = GetGrenadeAmmo(victim, Gren_M18);
			//	 playerGrenadeType[victim][4] = GetGrenadeAmmo(victim, Gren_Flash);
			//	 playerGrenadeType[victim][5] = GetGrenadeAmmo(victim, Gren_F1);
			//	 playerGrenadeType[victim][6] = GetGrenadeAmmo(victim, Gren_IED);
			//	 playerGrenadeType[victim][7] = GetGrenadeAmmo(victim, Gren_C4);
			//	 playerGrenadeType[victim][8] = GetGrenadeAmmo(victim, Gren_AT4);
			//	 playerGrenadeType[victim][9] = GetGrenadeAmmo(victim, Gren_RPG7);
			// }
		}

}
// Trigged when player die
public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	////////////////////////
	// Rank System
	new attackerId = GetEventInt(event, "attacker");
	new attacker = GetClientOfUserId(attackerId);

	////////////////////////
	
	// Get player ID
	new client = GetClientOfUserId(GetEventInt(event, "userid"));

	// Check client valid
	if(client > MaxClients || client <= 0) return Plugin_Continue;

	if (!IsClientInGame(client)) return Plugin_Continue;

	if(attacker > MaxClients || attacker <= 0) return Plugin_Continue;

	if (!IsClientInGame(attacker)) return Plugin_Continue;
	
	g_iPlayerBGroups[client] = GetEntProp(client, Prop_Send, "m_nBody");

	//PrintToServer("BodyGroups: %d", g_iPlayerBGroups[client]);

	// Set variable
	new dmg_taken = GetEventInt(event, "damagebits");
	if (dmg_taken <= 0)
	{
		g_playerWoundTime[client] = g_minorRevive_time;
		g_playerWoundType[client] = 0;
	}
	//PrintToServer("[PLAYERDEATH] Client %N has %d lives remaining", client, g_iSpawnTokens[client]);

	// Get gamemode
	decl String:sGameMode[32];
	GetConVarString(FindConVar("mp_gamemode"), sGameMode, sizeof(sGameMode));
	new team = GetClientTeam(client);
	new attackerTeam = GetClientTeam(attacker);

	//AI Director START
	//Bot Team AD Status
	if (team == TEAM_2_INS && g_iRoundStatus == 1 && attackerTeam == TEAM_1_SEC)
	{
		//Bonus point for specialty bots
		if (AI_Director_IsSpecialtyBot(client))
			g_AIDir_TeamStatus += 1;
			
		g_AIDir_BotsKilledCount++;
		if (g_AIDir_BotsKilledCount > (GetTeamSecCount() / g_AIDir_BotsKilledReq_mult))
		{
			g_AIDir_BotsKilledCount = 0;  
			g_AIDir_TeamStatus += 1;
		}
	}
	//Player Team AD STATUS
	if (team == TEAM_1_SEC && g_iRoundStatus == 1)
	{
		if (g_iHurtFatal[client] == 1)
			g_AIDir_TeamStatus -= 3;
		else
			g_AIDir_TeamStatus -= 2;

		if ((StrContains(g_client_last_classstring[client], "medic") > -1))
			g_AIDir_TeamStatus -= 3;

	}

	g_AIDir_TeamStatus = AI_Director_SetMinMax(g_AIDir_TeamStatus, g_AIDir_TeamStatus_min, g_AIDir_TeamStatus_max);
		
	//AI Director END

	if (g_iCvar_revive_enable)
	{
		// Convert ragdoll
		if (team == TEAM_1_SEC)
		{
			// Get current position
			decl Float:vecPos[3];
			GetClientAbsOrigin(client, Float:vecPos);
			g_fDeadPosition[client] = vecPos;
			
			// Get current angles
			decl Float:angPos[3];
			GetClientAbsAngles(client, Float:angPos);
			g_fDeadAngle[client] = angPos;
			
			// Call ragdoll timer
			if (g_iEnableRevive == 1 && g_iRoundStatus == 1)
				CreateTimer(5.0, ConvertDeleteRagdoll, client);
		}
	}
	// Check enables
	if (g_iCvar_respawn_enable)
	{
		
		// Client should be TEAM_1_SEC = HUMANS or TEAM_2_INS = BOTS
		if ((team == TEAM_1_SEC) || (team == TEAM_2_INS))
		{
			// The number of control points
			new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
			
			// Active control poin
			new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
			
			// Do not decrease life in counterattack
			if (g_isCheckpoint == 1 && Ins_InCounterAttack() && 
				(((acp+1) == ncp &&	 g_iCvar_final_counterattack_type == 2) || 
				((acp+1) != ncp && g_iCvar_counterattack_type == 2))
			)
			{
				// Respawn type 1 bots
				if ((g_iCvar_respawn_type_team_ins == 1 && team == TEAM_2_INS) && 
				(((acp+1) == ncp &&	 g_iCvar_final_counterattack_type == 2) || 
				((acp+1) != ncp && g_iCvar_counterattack_type == 2))
				)
				{
					if ((g_iSpawnTokens[client] < g_iRespawnCount[team]))
						g_iSpawnTokens[client] = (g_iRespawnCount[team] + 1);
					
					// Call respawn timer
					CreateBotRespawnTimer(client);
				}
				// Respawn type 1 player (individual lives)
				else if (g_iCvar_respawn_type_team_sec == 1 && team == TEAM_1_SEC)
				{
					if (g_iSpawnTokens[client] > 0)
					{
						if (team == TEAM_1_SEC)
						{
							CreatePlayerRespawnTimer(client);
						}
					}
					else if (g_iSpawnTokens[client] <= 0 && g_iRespawnCount[team] > 0)
					{
						// Cannot respawn anymore
						decl String:sChat[128];
						Format(sChat, 128,"You cannot be respawned anymore. (out of lives)");
						PrintToChat(client, "%s", sChat);
					}
				}
				// Respawn type 2 for players
				else if (team == TEAM_1_SEC && g_iCvar_respawn_type_team_sec == 2 && g_iRespawn_lives_team_sec > 0)
				{
					g_iRemaining_lives_team_sec = g_iRespawn_lives_team_sec + 1;
					
					// Call respawn timer
					CreateCounterRespawnTimer(client);
				}
				// Respawn type 2 for bots
				else if (team == TEAM_2_INS && g_iCvar_respawn_type_team_ins == 2 && 
				(g_iRespawn_lives_team_ins > 0 || 
				((acp+1) == ncp && g_iCvar_final_counterattack_type == 2) || 
				((acp+1) != ncp && g_iCvar_counterattack_type == 2))
				)
				{
					g_iRemaining_lives_team_ins = g_iRespawn_lives_team_ins + 1;
					
					// Call respawn timer
					CreateBotRespawnTimer(client);
				}
			}
			// Normal respawn
			else if ((g_iCvar_respawn_type_team_sec == 1 && team == TEAM_1_SEC) || (g_iCvar_respawn_type_team_ins == 1 && team == TEAM_2_INS))
			{
				if (g_iSpawnTokens[client] > 0)
				{
					if (team == TEAM_1_SEC)
					{
						CreatePlayerRespawnTimer(client);
					}
					else if (team == TEAM_2_INS)
					{
						CreateBotRespawnTimer(client);
					}
				}
				else if (g_iSpawnTokens[client] <= 0 && g_iRespawnCount[team] > 0)
				{
					// Cannot respawn anymore
					decl String:sChat[128];
					Format(sChat, 128,"You cannot be respawned anymore.");
					PrintToChat(client, "%s", sChat);
				}
			}
			// Respawn type 2 for players
			else if (g_iCvar_respawn_type_team_sec == 2 && team == TEAM_1_SEC)
			{
				if (g_iRemaining_lives_team_sec > 0)
				{
					CreatePlayerRespawnTimer(client);
				}
				else if (g_iRemaining_lives_team_sec <= 0 && g_iRespawn_lives_team_sec > 0)
				{
					// Cannot respawn anymore
					decl String:sChat[128];
					Format(sChat, 128,"You cannot be respawned anymore.");
					PrintToChat(client, "%s", sChat);
				}
			}
			// Respawn type 2 for bots
			else if (g_iCvar_respawn_type_team_ins == 2 && g_iRemaining_lives_team_ins >  0 && team == TEAM_2_INS)
			{
				CreateBotRespawnTimer(client);
			}
		}
	}
	
	// Init variables
	decl String:wound_hint[64];
	decl String:fatal_hint[64];
	decl String:woundType[64];
	if (g_playerWoundType[client] == 0)
		woundType = "MINORLY WOUNDED";
	else if (g_playerWoundType[client] == 1)
		woundType = "MODERATELY WOUNDED";
	else if (g_playerWoundType[client] == 2)
		woundType = "CRITCALLY WOUNDED";

	// Display death message
	if (g_fCvar_fatal_chance > 0.0)
	{
		if (g_iHurtFatal[client] == 1 && !IsFakeClient(client))
		{
			Format(fatal_hint, 255,"You were fatally killed for %i damage", g_clientDamageDone[client]);
			PrintHintText(client, "%s", fatal_hint);
			PrintToChat(client, "%s", fatal_hint);
		}
		else
		{
			Format(wound_hint, 255,"You're %s for %i damage, call a medic for revive!", woundType, g_clientDamageDone[client]);
			PrintHintText(client, "%s", wound_hint);
			PrintToChat(client, "%s", wound_hint);
		}
	}
	else
	{
		Format(wound_hint, 255,"You're %s for %i damage, call a medic for revive!", woundType, g_clientDamageDone[client]);
		PrintHintText(client, "%s", wound_hint);
		PrintToChat(client, "%s", wound_hint);
	}
	
	return Plugin_Continue;
}

//fall damage
public Action:OnTakeDamage(client, &attacker, &inflictor, &Float:damage, &damagetype)
{
	if (damagetype & DMG_FALL)
	{
		new iHealth = GetClientHealth(client);
		if (damage >= iHealth)
		{
			// Get fatal chance
			new fRandomChance = GetRandomInt(1, 100);
			//PrintToChatAll("Fall");
			if (fRandomChance <= 25)
			{
				g_iHurtFatal[client] = 1;
			}
			else
			{
				//g_playerWoundTime[client] = g_critRevive_time;
				//g_playerWoundType[client] = 2;
				//PrintToServer("[PLAYER FELL TO THEIR DEATH]");
				if (g_iCvar_revive_enable)
				{
					// Get current position
					decl Float:vecPos[3];
					GetClientAbsOrigin(client, Float:vecPos);
					g_fDeadPosition[client] = vecPos;
			
					// Get current angles
					decl Float:angPos[3];
					GetClientAbsAngles(client, Float:angPos);
					g_fDeadAngle[client] = angPos;
			
					// Call ragdoll timer
					if (g_iEnableRevive == 1 && g_iRoundStatus == 1)
					{
						CreateTimer(5.0, ConvertDeleteRagdoll, client);
					}
				}
			}
		}
	}
	//flame death
	decl String:sWeapon[32];
	GetEdictClassname(inflictor, sWeapon, sizeof(sWeapon));
	if(StrEqual(sWeapon, "entityflame"))
	{
		new iHealth = GetClientHealth(client);
		if(damage >= iHealth)
		{
			// Get fatal chance
			new fRandomChance = GetRandomInt(1, 100);
			//PrintToChatAll("entityflame");
			if (fRandomChance <= 25)
			{
				g_iHurtFatal[client] = 1;
			}
			else
			{
				//g_playerWoundTime[client] = g_critRevive_time;
				//g_playerWoundType[client] = 2;
				if (g_iCvar_revive_enable)
				{
					// Get current position
					decl Float:vecPos[3];
					GetClientAbsOrigin(client, Float:vecPos);
					g_fDeadPosition[client] = vecPos;
			
					// Get current angles
					decl Float:angPos[3];
					GetClientAbsAngles(client, Float:angPos);
					g_fDeadAngle[client] = angPos;
			
					// Call ragdoll timer
					if (g_iEnableRevive == 1 && g_iRoundStatus == 1)
					{
						CreateTimer(5.0, ConvertDeleteRagdoll, client);
					}
				}
			}
		}
	}
	return Plugin_Continue;
}

// Convert dead body to new ragdoll
public Action:ConvertDeleteRagdoll(Handle:Timer, any:client)
{	
	if (IsClientInGame(client) && g_iRoundStatus == 1 && !IsPlayerAlive(client) && (GetClientTeam(client) == TEAM_1_SEC || GetClientTeam(client) == TEAM_2_INS) ) 
	{
		//PrintToServer("CONVERT RAGDOLL********************");
		//new clientRagdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
		//TeleportEntity(clientRagdoll, g_fDeadPosition[client], NULL_VECTOR, NULL_VECTOR);
		
		// Get dead body
		new clientRagdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
		
		//This timer safely removes client-side ragdoll
		if(clientRagdoll > 0 && IsValidEdict(clientRagdoll) && IsValidEntity(clientRagdoll) && g_iEnableRevive == 1)
		{
			// Get dead body's entity
			new ref = EntIndexToEntRef(clientRagdoll);
			new entity = EntRefToEntIndex(ref);
			if(entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
			{
				// Remove dead body's entity
				AcceptEntityInput(entity, "Kill");
				clientRagdoll = INVALID_ENT_REFERENCE;
			}
		}
		
		// Check is fatally dead
		if (g_iHurtFatal[client] != 1)
		{
			// Create new ragdoll
			new tempRag = CreateEntityByName("prop_ragdoll");
			
			// Set client's new ragdoll
			g_iClientRagdolls[client]  = EntIndexToEntRef(tempRag);
			
			// Set position, adjust value (+ 10) for height at which ragdoll is spawned at. 
			g_fDeadPosition[client][2] = g_fDeadPosition[client][2] + 10;
			
			// If success initialize ragdoll
			if(tempRag != -1)
			{
				// Get model name
				decl String:sModelName[64];
				GetClientModel(client, sModelName, sizeof(sModelName));
				
				// Set model
				SetEntityModel(tempRag, sModelName);
				
				// Give custom ragdoll name for each client, this way other plugins can search for targetname to modify behavior
				char sTargetName[64]; 
				Format(sTargetName, sizeof(sTargetName), "playervital_ragdoll_%i", client);
				DispatchKeyValue(tempRag, "targetname", sTargetName);

				DispatchSpawn(tempRag);
				
				// Set collisiongroup
				SetEntProp(tempRag, Prop_Send, "m_CollisionGroup", 17);
				//Set bodygroups for ragdoll
				SetEntProp(tempRag, Prop_Send, "m_nBody", g_iPlayerBGroups[client]);
				
				
				
				g_fDeadAngle[client][0] += -90.0;
				// Teleport to current position
				TeleportEntity(tempRag, g_fDeadPosition[client], g_fDeadAngle[client], NULL_VECTOR);
				// Set vector
				GetEntPropVector(tempRag, Prop_Send, "m_vecOrigin", g_fRagdollPosition[client]);
				
				// Set revive time remaining
				g_iReviveRemainingTime[client] = g_playerWoundTime[client];
				g_iReviveNonMedicRemainingTime[client] = g_nonMedRevive_time;
				// Start revive checking timer
				/*
				new Handle:revivePack;
				CreateDataTimer(1.0 , Timer_RevivePeriod, revivePack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);	
				WritePackCell(revivePack, client);
				WritePackCell(revivePack, tempRag);
				*/
			}
			else
			{
				// If failed to create ragdoll, remove entity
				if(tempRag > 0 && IsValidEdict(tempRag) && IsValidEntity(tempRag))
					RemoveRagdoll(client);
			}
		}
	}
}

// Remove ragdoll
void RemoveRagdoll(client)
{
	//new ref = EntIndexToEntRef(g_iClientRagdolls[client]);
	new entity = EntRefToEntIndex(g_iClientRagdolls[client]);
	if(entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
	{
		AcceptEntityInput(entity, "Kill");
		g_iClientRagdolls[client] = INVALID_ENT_REFERENCE;
	}	
}

// This handles revives by medics
public CreateReviveTimer(client)
{
	CreateTimer(0.0, RespawnPlayerRevive, client);
}

// Handles spawns when counter attack starts
public CreateCounterRespawnTimer(client)
{
	CreateTimer(0.0, RespawnPlayerCounter, client);
}

// Respawn bot
public CreateBotRespawnTimer(client)
{	
	if(client > MaxClients || client <= 0) return;
	
	if ((g_cqc_map_enabled == 1 && Ins_InCounterAttack() && ((StrContains(g_client_last_classstring[client], "bomber") > -1) || 
		(StrContains(g_client_last_classstring[client], "tank") > -1))) || 
		(!Ins_InCounterAttack() && ((StrContains(g_client_last_classstring[client], "bomber") > -1) || 
			(StrContains(g_client_last_classstring[client], "tank") > -1)))) //make sure its a bot bomber
	{
		if (g_cqc_map_enabled == 1 && Ins_InCounterAttack())
		{
			if (StrContains(g_client_last_classstring[client], "bomber") > -1)
			{
				//PrintToServer("BOMBER SPAWN: Delay %f", (g_fCvar_respawn_delay_team_ins_spec / 3));
				CreateTimer((g_fCvar_respawn_delay_team_ins_spec / 3), RespawnBot, client);
			}
			else if (StrContains(g_client_last_classstring[client], "tank") > -1)
			{
				//PrintToServer("JUGGER SPAWN: Delay %f", (g_fCvar_respawn_delay_team_ins_spec / 4));
				CreateTimer((g_fCvar_respawn_delay_team_ins_spec / 4), RespawnBot, client);
			}
		}
		else
		{
			if (StrContains(g_client_last_classstring[client], "bomber") > -1)
			{
				CreateTimer((g_fCvar_respawn_delay_team_ins_spec * 2), RespawnBot, client);
			}
			else if (StrContains(g_client_last_classstring[client], "tank") > -1)
			{
				CreateTimer((g_fCvar_respawn_delay_team_ins_spec), RespawnBot, client);
			}
		}
	}
	else
		CreateTimer(g_fCvar_respawn_delay_team_ins, RespawnBot, client);
	
}

// Respawn player
public CreatePlayerRespawnTimer(client)
{
	// Check is respawn timer active
	if (g_iPlayerRespawnTimerActive[client] == 0)
	{
		// Set timer active
		g_iPlayerRespawnTimerActive[client] = 1;
		
		new validAntenna = -1;
		validAntenna = FindValid_Antenna();

		// Set remaining timer for respawn
		if (validAntenna != -1)
		{
			new timeReduce = (GetTeamSecCount() / 3);
			if (timeReduce <= 0)
				timeReduce = 3;

			new jammerSpawnReductionAmt = (g_secWave_Timer / timeReduce);

			g_iRespawnTimeRemaining[client] = (g_secWave_Timer - jammerSpawnReductionAmt);
			if (g_iRespawnTimeRemaining[client] < 5)
				g_iRespawnTimeRemaining[client] = 5;
		}
		else
			g_iRespawnTimeRemaining[client] = g_secWave_Timer;

		// Call respawn timer
		CreateTimer(1.0, Timer_PlayerRespawn, client, TIMER_REPEAT);
	}
}

// Revive player
public Action:RespawnPlayerRevive(Handle:Timer, any:client)
{
	// Exit if client is not in game
	if (!IsClientInGame(client)) return;
	if (IsPlayerAlive(client) || g_iRoundStatus == 0) return;

	//PrintToServer("[REVIVE_RESPAWN] REVIVING client %N who has %d lives remaining", client, g_iSpawnTokens[client]);
	// Call forcerespawn fucntion
	SDKCall(g_hForceRespawn, client);

	//spawn player in prone position
	//SetEntPropFloat(client, Prop_Send, "m_StanceTransitionTimer", 0.0);
	//SetEntProp(client, Prop_Send, "m_iLastStance", 2);
	//SetEntProp(client, Prop_Send, "m_iCurrentStance", 2);
	SetEntProp(client, Prop_Send, "m_iDesiredStance", 2);
	
	// If set 'sm_respawn_enable_track_ammo', restore player's ammo
	if (playerRevived[client] == true && g_iCvar_enable_track_ammo == 1)
	{
	playerInRevivedState[client] = true;
	}
	//Set wound health
	new iHealth = GetClientHealth(client);
	if (g_playerNonMedicRevive[client] == 0)
	{
		if (g_playerWoundType[client] == 0)
			iHealth = g_minorWoundRevive_hp;
		else if (g_playerWoundType[client] == 1)
			iHealth = g_modWoundRevive_hp;
		else if (g_playerWoundType[client] == 2)
			iHealth = g_critWoundRevive_hp;
	}
	else if (g_playerNonMedicRevive[client] == 1)
	{
		//NonMedic Revived
		iHealth = g_nonMedicRevive_hp;
	}

	SetEntityHealth(client, iHealth);
	
	// Get player's ragdoll
	new playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
	
	//Remove network ragdoll
	if(playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
		RemoveRagdoll(client);
	
	//Do the post-spawn stuff like moving to final "spawnpoint" selected
	//CreateTimer(0.0, RespawnPlayerRevivePost, client);
	RespawnPlayerRevivePost(INVALID_HANDLE, client);
	if ((StrContains(g_client_last_classstring[client], "medic") > -1))
		g_AIDir_TeamStatus += 2;
	else
		g_AIDir_TeamStatus += 1;

	g_AIDir_TeamStatus = AI_Director_SetMinMax(g_AIDir_TeamStatus, g_AIDir_TeamStatus_min, g_AIDir_TeamStatus_max);
}

// Do post revive stuff
public Action:RespawnPlayerRevivePost(Handle:timer, any:client)
{
	// Exit if client is not in game
	if (!IsClientInGame(client)) return;
	
	//PrintToServer("[REVIVE_DEBUG] called RespawnPlayerRevivePost for client %N (%d)",client,client);
	TeleportEntity(client, g_fRagdollPosition[client], NULL_VECTOR, NULL_VECTOR);
	
	// Reset ragdoll position
	g_fRagdollPosition[client][0] = 0.0;
	g_fRagdollPosition[client][1] = 0.0;
	g_fRagdollPosition[client][2] = 0.0;
}

// Respawn player in counter attack
public Action:RespawnPlayerCounter(Handle:Timer, any:client)
{
	// Exit if client is not in game
	if (!IsClientInGame(client)) return;
	if (IsPlayerAlive(client) || g_iRoundStatus == 0) return;
	
	//PrintToServer("[Counter Respawn] Respawning client %N who has %d lives remaining", client, g_iSpawnTokens[client]);
	// Call forcerespawn fucntion
	SDKCall(g_hForceRespawn, client);

	// Get player's ragdoll
	new playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
	
	//Remove network ragdoll
	if(playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
		RemoveRagdoll(client);
	
		// If set 'sm_respawn_enable_track_ammo', restore player's ammo
		// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	
	//Remove grenades if not finale
	if ((acp+1) != ncp)
		RemoveWeapons(client, 0, 0, 1);

	// Teleport to avtive counter attack point
	//PrintToServer("[REVIVE_DEBUG] called RespawnPlayerPost for client %N (%d)",client,client);
	if (g_fRespawnPosition[0] != 0.0 && g_fRespawnPosition[1] != 0.0 && g_fRespawnPosition[2] != 0.0)
		TeleportEntity(client, g_fRespawnPosition, NULL_VECTOR, NULL_VECTOR);
	
	// Reset ragdoll position
	g_fRagdollPosition[client][0] = 0.0;
	g_fRagdollPosition[client][1] = 0.0;
	g_fRagdollPosition[client][2] = 0.0;
}


// Respawn bot
public Action:RespawnBot(Handle:Timer, any:client)
{
	// Exit if client is not in game
	if (!IsClientInGame(client) || IsPlayerAlive(client) || g_iRoundStatus == 0) return;

	decl String:sModelName[64];
	GetClientModel(client, sModelName, sizeof(sModelName));
	if (StrEqual(sModelName, ""))
	{
		//PrintToServer("Invalid model: %s", sModelName);
		return; //check if model is blank
	}
	else
	{
		PrintToServer("Valid model: %s", sModelName);
	}
	
	// Check respawn type
	if (g_iCvar_respawn_type_team_ins == 1 && g_iSpawnTokens[client] > 0)
		g_iSpawnTokens[client]--;
	else if (g_iCvar_respawn_type_team_ins == 2)
	{
		if (g_iRemaining_lives_team_ins > 0)
		{
			g_iRemaining_lives_team_ins--;
			
			if (g_iRemaining_lives_team_ins <= 0)
				g_iRemaining_lives_team_ins = 0;
			//PrintToServer("######################TEAM 2 LIVES REMAINING %i", g_iRemaining_lives_team_ins);
		}
	}
	//PrintToServer("######################TEAM 2 LIVES REMAINING %i", g_iRemaining_lives_team_ins);
	//PrintToServer("######################TEAM 2 LIVES REMAINING %i", g_iRemaining_lives_team_ins);
	//PrintToServer("[RESPAWN] Respawning client %N who has %d lives remaining", client, g_iSpawnTokens[client]);
	
	// Call forcerespawn fucntion

	SDKCall(g_hForceRespawn, client);
}

//Handle any work that needs to happen after the client is in the game
public Action:RespawnBotPost(Handle:timer, any:client)
{
	/*
	// Exit if client is not in game
	if (!IsClientInGame(client)) return;

	//PrintToServer("[BOTSPAWNS] called RespawnBotPost for client %N (%d)",client,client);
	//g_iSpawning[client] = 0;
	
	if ((g_iHidingSpotCount) && !Ins_InCounterAttack())
	{	
		//PrintToServer("[BOTSPAWNS] HAS g_iHidingSpotCount COUNT");
		
		//Older Nav Spawning
		// Get hiding point - Nav Spawning - Commented for Rehaul
		new Float:flHidingSpot[3];
		new iSpot = GetBestHidingSpot(client);

		//PrintToServer("[BOTSPAWNS] FOUND Hiding spot %d",iSpot);
		
		//If found hiding spot
		if (iSpot > -1)
		{
			// Set hiding spot
			flHidingSpot[0] = GetArrayCell(g_hHidingSpots, iSpot, NavMeshHidingSpot_X);
			flHidingSpot[1] = GetArrayCell(g_hHidingSpots, iSpot, NavMeshHidingSpot_Y);
			flHidingSpot[2] = GetArrayCell(g_hHidingSpots, iSpot, NavMeshHidingSpot_Z);
			
			// Debug message
			//new Float:vecOrigin[3];
			//GetClientAbsOrigin(client,vecOrigin);
			//new Float:distance = GetVectorDistance(flHidingSpot,vecOrigin);
			//PrintToServer("[BOTSPAWNS] Teleporting %N to hiding spot %d at %f,%f,%f distance %f", client, iSpot, flHidingSpot[0], flHidingSpot[1], flHidingSpot[2], distance);
			
			// Teleport to hiding spot
			TeleportEntity(client, flHidingSpot, NULL_VECTOR, NULL_VECTOR);
		}
	}
	*/
	
}

// Player respawn timer
public Action:Timer_PlayerRespawn(Handle:Timer, any:client)
{
	decl String:sRemainingTime[256];
	
	// Exit if client is not in game
	if (!IsClientInGame(client)) return Plugin_Stop; // empty class name
	
	if (!IsPlayerAlive(client) && g_iRoundStatus == 1)
	{
		if (g_iRespawnTimeRemaining[client] > 0)
		{	
			if (g_playerFirstJoin[client] == 1)
			{
				// Print remaining time to center text area
				if (!IsFakeClient(client))
				{
					Format(sRemainingTime, sizeof(sRemainingTime),"This is your first time joining.  You will reinforce in %d second%s (%d lives left) ", g_iRespawnTimeRemaining[client], (g_iRespawnTimeRemaining[client] > 1 ? "s" : ""), g_iSpawnTokens[client]);
					PrintCenterText(client, sRemainingTime);
				}
			}
			else
			{
				new String:woundType[128];
				new tIsFatal = false;
				if (g_iHurtFatal[client] == 1)
				{
					woundType = "fatally killed";
					tIsFatal = true;
				}
				else
				{
					woundType = "WOUNDED";
					if (g_playerWoundType[client] == 0)
						woundType = "MINORLY WOUNDED";
					else if (g_playerWoundType[client] == 1)
						woundType = "MODERATELY WOUNDED";
					else if (g_playerWoundType[client] == 2)
						woundType = "CRITCALLY WOUNDED";
				}
				// Print remaining time to center text area
				if (!IsFakeClient(client))
				{
					if (tIsFatal)
					{
						Format(sRemainingTime, sizeof(sRemainingTime),"%s for %d damage\n\n				 Reinforcing in %d second%s (%d lives left) ", woundType, g_clientDamageDone[client], g_iRespawnTimeRemaining[client], (g_iRespawnTimeRemaining[client] > 1 ? "s" : ""), g_iSpawnTokens[client]);
					}
					else
					{
						Format(sRemainingTime, sizeof(sRemainingTime),"%s for %d damage | wait patiently for a medic..do NOT mic/chat spam!\n\n				 Reinforcing in %d second%s (%d lives left) ", woundType, g_clientDamageDone[client], g_iRespawnTimeRemaining[client], (g_iRespawnTimeRemaining[client] > 1 ? "s" : ""), g_iSpawnTokens[client]);
					}
					PrintCenterText(client, sRemainingTime);
				}
			}
			
			// Decrease respawn remaining time
			g_iRespawnTimeRemaining[client]--;
		}
		else
		{
			// Decrease respawn token
			if (g_iCvar_respawn_type_team_sec == 1)
				g_iSpawnTokens[client]--;
			else if (g_iCvar_respawn_type_team_sec == 2)
				g_iRemaining_lives_team_sec--;
			
			// Call forcerespawn function
			SDKCall(g_hForceRespawn, client);

			//AI Director START

			if ((StrContains(g_client_last_classstring[client], "medic") > -1))
				g_AIDir_TeamStatus += 2;
			else
				g_AIDir_TeamStatus += 1;

			g_AIDir_TeamStatus = AI_Director_SetMinMax(g_AIDir_TeamStatus, g_AIDir_TeamStatus_min, g_AIDir_TeamStatus_max);
				
			//AI Director STOP
			
			// Print remaining time to center text area
			if (!IsFakeClient(client))
				PrintCenterText(client, "You reinforced! (%d lives left)", g_iSpawnTokens[client]);

			// Get ragdoll position
			new playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
			
			// Remove network ragdoll
			if(playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
				RemoveRagdoll(client);
			
			// Do the post-spawn stuff like moving to final "spawnpoint" selected
			//CreateTimer(0.0, RespawnPlayerPost, client);
			//RespawnPlayerPost(INVALID_HANDLE, client);
					
			// Reset ragdoll position
			g_fRagdollPosition[client][0] = 0.0;
			g_fRagdollPosition[client][1] = 0.0;
			g_fRagdollPosition[client][2] = 0.0;

			// Reset variable
			g_iPlayerRespawnTimerActive[client] = 0;
			
			return Plugin_Stop;
		}
	}
	else
	{
		// Reset variable
		g_iPlayerRespawnTimerActive[client] = 0;
		
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}


// Handles reviving for medics and non-medics
public Action:Timer_ReviveMonitor(Handle:timer, any:data)
{
	// Check round state
	if (g_iRoundStatus == 0) return Plugin_Continue;
	
	
	// Init variables
	new Float:fReviveDistance = 65.0;
	new iInjured;
	new iInjuredRagdoll;
	new Float:fRagPos[3];
	new Float:fMedicPos[3];
	new Float:fDistance;
	
	// Search medics
	for (new iMedic = 1; iMedic <= MaxClients; iMedic++)
	{
		if (!IsClientInGame(iMedic) || IsFakeClient(iMedic))
			continue;
		
		// Is valid iMedic?
		if (IsPlayerAlive(iMedic) && (StrContains(g_client_last_classstring[iMedic], "medic") > -1))
		{
			// Check is there nearest body
			iInjured = g_iNearestBody[iMedic];
			
			// Valid nearest body
			if (iInjured > 0 && IsClientInGame(iInjured) && !IsPlayerAlive(iInjured) && g_iHurtFatal[iInjured] == 0 
				&& iInjured != iMedic && GetClientTeam(iMedic) == GetClientTeam(iInjured)
			)
			{
				// Get found medic position
				GetClientAbsOrigin(iMedic, fMedicPos);
				
				// Get player's entity index
				iInjuredRagdoll = EntRefToEntIndex(g_iClientRagdolls[iInjured]);
				
				// Check ragdoll is valid
				if(iInjuredRagdoll > 0 && iInjuredRagdoll != INVALID_ENT_REFERENCE
					&& IsValidEdict(iInjuredRagdoll) && IsValidEntity(iInjuredRagdoll)
				)
				{
					// Get player's ragdoll position
					GetEntPropVector(iInjuredRagdoll, Prop_Send, "m_vecOrigin", fRagPos);
					
					// Update ragdoll position
					g_fRagdollPosition[iInjured] = fRagPos;
					
					// Get distance from iMedic
					fDistance = GetVectorDistance(fRagPos,fMedicPos);
				}
				else
					// Ragdoll is not valid
					continue;
				
				// Jareds pistols only code to verify iMedic is carrying knife
				new ActiveWeapon = GetEntPropEnt(iMedic, Prop_Data, "m_hActiveWeapon");
				if (ActiveWeapon < 0)
					continue;
				
				// Get weapon class name
				decl String:sWeapon[32];
				GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
				//PrintToServer("[KNIFE ONLY] CheckWeapon for iMedic %d named %N ActiveWeapon %d sWeapon %s",iMedic,iMedic,ActiveWeapon,sWeapon);
				
				// If iMedic can see ragdoll and using defib or knife
				if (fDistance < fReviveDistance && (ClientCanSeeVector(iMedic, fRagPos, fReviveDistance)) 
					&& ((StrContains(sWeapon, "weapon_defib") > -1) || (StrContains(sWeapon, "weapon_knife") > -1) || (StrContains(sWeapon, "weapon_kabar") > -1))
				)
				{
					//PrintToServer("[REVIVE_DEBUG] Distance from %N to %N is %f Seconds %d", iInjured, iMedic, fDistance, g_iReviveRemainingTime[iInjured]);		
					decl String:sBuf[255];
					
					// Need more time to reviving
					if (g_iReviveRemainingTime[iInjured] > 0)
					{

						decl String:woundType[64];
						if (g_playerWoundType[iInjured] == 0)
							woundType = "Minor wound";
						else if (g_playerWoundType[iInjured] == 1)
							woundType = "Moderate wound";
						else if (g_playerWoundType[iInjured] == 2)
							woundType = "Critical wound";

						// Hint to iMedic
						Format(sBuf, 255,"Reviving %N in: %i seconds (%s)", iInjured, g_iReviveRemainingTime[iInjured], woundType);
						PrintHintText(iMedic, "%s", sBuf);
						
						// Hint to victim
						Format(sBuf, 255,"%N is reviving you in: %i seconds (%s)", iMedic, g_iReviveRemainingTime[iInjured], woundType);
						PrintHintText(iInjured, "%s", sBuf);
						
						// Decrease revive remaining time
						g_iReviveRemainingTime[iInjured]--;
						
						//prevent respawn while reviving
						g_iRespawnTimeRemaining[iInjured]++;

						InProgressReviveByMedic[iInjured] = true;
						int CurrentTime = GetTime();
						LastTimeCheckedReviveProgress[iInjured] = CurrentTime;
					}
					// Revive player
					else if (g_iReviveRemainingTime[iInjured] <= 0)
					{	
						decl String:woundType[64];
						if (g_playerWoundType[iInjured] == 0)
							woundType = "minor wound";
						else if (g_playerWoundType[iInjured] == 1)
							woundType = "moderate wound";
						else if (g_playerWoundType[iInjured] == 2)
							woundType = "critical wound";
								

						// Chat to all
						//Format(sBuf, 255,"\x05%N\x01 revived \x03%N from a %s", iMedic, iInjured, woundType);
						//PrintToChatAll("%s", sBuf);
						
						// Hint to iMedic
						Format(sBuf, 255,"You revived %N from a %s", iInjured, woundType);
						PrintHintText(iMedic, "%s", sBuf);
						
						// Hint to victim
						Format(sBuf, 255,"%N revived you from a %s", iMedic, woundType);
						PrintHintText(iInjured, "%s", sBuf);

						//revive gasp sounds
						switch(GetRandomInt(7, 26))
						{
							/*case 1: EmitSoundToAll("player/focus_gasp.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 2: EmitSoundToAll("player/focus_gasp_01.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 3: EmitSoundToAll("player/focus_gasp_02.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 4: EmitSoundToAll("player/focus_gasp_03.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 5: EmitSoundToAll("player/focus_gasp_04.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 6: EmitSoundToAll("player/focus_gasp_05.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);*/
							case 7: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks1.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 8: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks2.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 9: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks3.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 10: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks4.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 11: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks5.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 12: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks6.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 13: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks7.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 14: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks8.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 15: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks9.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 16: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks10.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 17: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks11.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 18: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks12.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 19: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks13.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 20: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks14.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 21: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks15.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 22: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks16.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 23: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks17.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 24: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks18.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 25: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks19.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 26: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks20.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
						}

						//L4D2 defibrillator revive sound
						EmitSoundToAll("weapons/defibrillator/defibrillator_revive.wav", iMedic, SNDCHAN_AUTO, _, _, 0.3);

						// Add kill bonus to iMedic
						//new iBonus = GetConVarInt(sm_revive_bonus);
						//PrintToServer("iBonus: %d", iBonus);
						//new iScore = GetClientFrags(iMedic) + iBonus;
						//PrintToServer("GetClientFrags: %d | iScore: %d", GetClientFrags(iMedic), iScore);
						//SetEntProp(iMedic, Prop_Data, "m_iFrags", iScore);
						
						/////////////////////////
						// Rank System
						g_iStatRevives[iMedic]++;
						//
						/////////////////////////
						
						//Accumulate a revive
						g_playerMedicRevivessAccumulated[iMedic]++;
						new iReviveCap = GetConVarInt(sm_revive_cap_for_bonus);

						// Hint to iMedic
						Format(sBuf, 255,"You revived %N from a %s", iInjured, woundType);
						PrintHintText(iMedic, "%s", sBuf);

						if (g_playerMedicRevivessAccumulated[iMedic] >= iReviveCap)
						{
							g_playerMedicRevivessAccumulated[iMedic] = 0;
							g_iSpawnTokens[iMedic]++;
							decl String:sBuf2[255];
							//if (iBonus > 1)
							//	Format(sBuf2, 255,"Awarded %i kills and %i score for revive", iBonus, 10);
							//else
							Format(sBuf2, 255,"Awarded %i life for reviving %d players", 1, iReviveCap);
							PrintToChat(iMedic, "%s", sBuf2);
						}

						// Update ragdoll position
						g_fRagdollPosition[iInjured] = fRagPos;

						//Reward nearby medics who asssisted
						Check_NearbyMedicsRevive(iMedic, iInjured);
						
						// Reset revive counter
						playerRevived[iInjured] = true;
						
						// Call revive function
						g_playerNonMedicRevive[iInjured] = 0;
						CreateReviveTimer(iInjured);

						//gameme stats forward
						SendForwardResult(iMedic, iInjured);
						continue;
					}
				}
			}
		}
		//Non Medics with Medic Pack
		else if (IsPlayerAlive(iMedic) && !(StrContains(g_client_last_classstring[iMedic], "medic") > -1))
		{
			//PrintToServer("Non-Medic Reviving..");
			// Check is there nearest body
			iInjured = g_iNearestBody[iMedic];
			
			// Valid nearest body
			if (iInjured > 0 && IsClientInGame(iInjured) && !IsPlayerAlive(iInjured) && g_iHurtFatal[iInjured] == 0 
				&& iInjured != iMedic && GetClientTeam(iMedic) == GetClientTeam(iInjured)
			)
			{
				// Get found medic position
				GetClientAbsOrigin(iMedic, fMedicPos);
				
				// Get player's entity index
				iInjuredRagdoll = EntRefToEntIndex(g_iClientRagdolls[iInjured]);
				
				// Check ragdoll is valid
				if(iInjuredRagdoll > 0 && iInjuredRagdoll != INVALID_ENT_REFERENCE
					&& IsValidEdict(iInjuredRagdoll) && IsValidEntity(iInjuredRagdoll)
				)
				{
					// Get player's ragdoll position
					GetEntPropVector(iInjuredRagdoll, Prop_Send, "m_vecOrigin", fRagPos);
					
					// Update ragdoll position
					g_fRagdollPosition[iInjured] = fRagPos;
					
					// Get distance from iMedic
					fDistance = GetVectorDistance(fRagPos,fMedicPos);
				}
				else
					// Ragdoll is not valid
					continue;
				
				// Jareds pistols only code to verify iMedic is carrying knife
				new ActiveWeapon = GetEntPropEnt(iMedic, Prop_Data, "m_hActiveWeapon");
				if (ActiveWeapon < 0)
					continue;
				
				// Get weapon class name
				decl String:sWeapon[32];
				GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
				//PrintToServer("[KNIFE ONLY] CheckWeapon for iMedic %d named %N ActiveWeapon %d sWeapon %s",iMedic,iMedic,ActiveWeapon,sWeapon);
				
				// If NON Medic can see ragdoll and using healthkit
				if (fDistance < fReviveDistance && (ClientCanSeeVector(iMedic, fRagPos, fReviveDistance)) 
					&& ((StrContains(sWeapon, "weapon_healthkit") > -1))
				)
				{
					//PrintToServer("[REVIVE_DEBUG] Distance from %N to %N is %f Seconds %d", iInjured, iMedic, fDistance, g_iReviveNonMedicRemainingTime[iInjured]);		
					decl String:sBuf[255];
					
					// Need more time to reviving
					if (g_iReviveNonMedicRemainingTime[iInjured] > 0)
					{

						//PrintToServer("NONMEDIC HAS TIME");
						if (g_playerWoundType[iInjured] == 0 || g_playerWoundType[iInjured] == 1 || g_playerWoundType[iInjured] == 2)
						{
							decl String:woundType[64];
							if (g_playerWoundType[iInjured] == 0)
								woundType = "Minor wound";
							else if (g_playerWoundType[iInjured] == 1)
								woundType = "Moderate wound";
							else if (g_playerWoundType[iInjured] == 2)
								woundType = "Critical wound";
							// Hint to NonMedic
							Format(sBuf, 255,"Reviving %N in: %i seconds (%s)", iInjured, g_iReviveNonMedicRemainingTime[iInjured], woundType);
							PrintHintText(iMedic, "%s", sBuf);
							
							// Hint to victim
							Format(sBuf, 255,"%N is reviving you in: %i seconds (%s)", iMedic, g_iReviveNonMedicRemainingTime[iInjured], woundType);
							PrintHintText(iInjured, "%s", sBuf);
							
							// Decrease revive remaining time
							g_iReviveNonMedicRemainingTime[iInjured]--;
						}
						// else if (g_playerWoundType[iInjured] == 1 || g_playerWoundType[iInjured] == 2)
						// {
						//	decl String:woundType[64];
						//	if (g_playerWoundType[iInjured] == 1)
						//		woundType = "moderately wounded";
						//	else if (g_playerWoundType[iInjured] == 2)
						//		woundType = "critically wounded";
						//	// Hint to NonMedic
						//	Format(sBuf, 255,"%N is %s and can only be revived by a medic!", iInjured, woundType);
						//	PrintHintText(iMedic, "%s", sBuf);
						// }
						//prevent respawn while reviving
						g_iRespawnTimeRemaining[iInjured]++;
					}
					// Revive player
					else if (g_iReviveNonMedicRemainingTime[iInjured] <= 0)
					{	
						decl String:woundType[64];
						if (g_playerWoundType[iInjured] == 0)
							woundType = "minor wound";
						else if (g_playerWoundType[iInjured] == 1)
							woundType = "moderate wound";
						else if (g_playerWoundType[iInjured] == 2)
							woundType = "critical wound";

						// Chat to all
						//Format(sBuf, 255,"\x05%N\x01 revived \x03%N from a %s", iMedic, iInjured, woundType);
						//PrintToChatAll("%s", sBuf);
						
						// Hint to iMedic
						Format(sBuf, 255,"You revived %N from a %s", iInjured, woundType);
						PrintHintText(iMedic, "%s", sBuf);
						
						// Hint to victim
						Format(sBuf, 255,"%N revived you from a %s", iMedic, woundType);
						PrintHintText(iInjured, "%s", sBuf);

					//revive gasp sounds
					//new fRandomGasp = GetRandomInt(0, 100);
					//if(fRandomGasp <= 50)
					//{
						switch(GetRandomInt(7, 26))
						{
							/*case 1: EmitSoundToAll("player/focus_gasp.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 2: EmitSoundToAll("player/focus_gasp_01.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 3: EmitSoundToAll("player/focus_gasp_02.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 4: EmitSoundToAll("player/focus_gasp_03.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 5: EmitSoundToAll("player/focus_gasp_04.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 6: EmitSoundToAll("player/focus_gasp_05.wav", iInjured, SNDCHAN_VOICE, _, _, 1.0);*/
							case 7: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks1.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 8: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks2.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 9: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks3.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 10: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks4.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 11: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks5.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 12: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks6.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 13: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks7.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 14: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks8.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 15: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks9.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 16: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks10.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 17: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks11.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 18: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks12.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 19: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks13.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 20: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks14.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 21: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks15.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 22: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks16.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 23: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks17.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 24: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks18.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 25: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks19.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
							case 26: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks20.ogg", iInjured, SNDCHAN_VOICE, _, _, 1.0);
						}

                        //}
						
						// Add kill bonus to iMedic
						// new iBonus = GetConVarInt(sm_revive_bonus);
						// new iScore = GetClientFrags(iMedic) + iBonus;
						// SetEntProp(iMedic, Prop_Data, "m_iFrags", iScore);
						
						
						/////////////////////////
						// Rank System
						g_iStatRevives[iMedic]++;
						//
						/////////////////////////
						
						//Accumulate a revive
						g_playerMedicRevivessAccumulated[iMedic]++;
						new iReviveCap = GetConVarInt(sm_revive_cap_for_bonus);

						// Hint to iMedic
						Format(sBuf, 255,"You revived %N from a %s", iInjured, woundType);
						PrintHintText(iMedic, "%s", sBuf);
						// Add score bonus to iMedic (doesn't work)
						//iScore = GetPlayerScore(iMedic);
						//PrintToServer("[SCORE] score: %d", iScore + 10);
						//SetPlayerScore(iMedic, iScore + 10);
						if (g_playerMedicRevivessAccumulated[iMedic] >= iReviveCap)
						{
							g_playerMedicRevivessAccumulated[iMedic] = 0;
							g_iSpawnTokens[iMedic]++;
							decl String:sBuf2[255];
							//if (iBonus > 1)
							//	Format(sBuf2, 255,"Awarded %i kills and %i score for revive", iBonus, 10);
							//else
							Format(sBuf2, 255,"Awarded %i life for reviving %d players", 1, iReviveCap);
							PrintToChat(iMedic, "%s", sBuf2);
						}

						
						// Update ragdoll position
						g_fRagdollPosition[iInjured] = fRagPos;
						
						//Reward nearby medics who asssisted
						Check_NearbyMedicsRevive(iMedic, iInjured);

						// Reset revive counter
						playerRevived[iInjured] = true;
						
						g_playerNonMedicRevive[iInjured] = 1;
						// Call revive function
						CreateReviveTimer(iInjured);
						RemovePlayerItem(iMedic,ActiveWeapon);
						//Switch to knife after removing kit
						ChangePlayerWeaponSlot(iMedic, 2);
						
						//gameme stats forward
						SendForwardResult(iMedic, iInjured);
						continue;
					}
				}
			}
		}
	}
	
	return Plugin_Continue;
}

//gameme stats forward
public Action SendForwardResult(int iMedic, int iInjured)
{
	Action result;
	Call_StartForward(MedicRevivedForward);
	Call_PushCell(iMedic);
	Call_PushCell(iInjured);
	Call_Finish(result);
	return result;
}

// Handles medic functions (Inspecting health, healing)
public Action:Timer_MedicMonitor(Handle:timer)
{
	// Check round state
	if (g_iRoundStatus == 0) return Plugin_Continue;
	
	// Search medics
	for(new medic = 1; medic <= MaxClients; medic++)
	{
		if (!IsClientInGame(medic) || IsFakeClient(medic))
			continue;
		
		// Medic only can inspect health.
		new iTeam = GetClientTeam(medic);
		if (iTeam == TEAM_1_SEC && IsPlayerAlive(medic) && StrContains(g_client_last_classstring[medic], "medic") > -1)
		{
			// Target is teammate and alive.
			new iTarget = TraceClientViewEntity(medic);
			if(iTarget > 0 && iTarget <= MaxClients && IsClientInGame(iTarget) && IsPlayerAlive(iTarget) && iTeam == GetClientTeam(iTarget))
			{
				// Check distance
				new bool:bCanHealPaddle = false;
				new bool:bCanHealMedpack = false;
				new Float:fReviveDistance = 80.0;
				new Float:vecMedicPos[3];
				new Float:vecTargetPos[3];
				new Float:tDistance;
				GetClientAbsOrigin(medic, Float:vecMedicPos);
				GetClientAbsOrigin(iTarget, Float:vecTargetPos);
				tDistance = GetVectorDistance(vecMedicPos,vecTargetPos);
				
				if (tDistance < fReviveDistance && ClientCanSeeVector(medic, vecTargetPos, fReviveDistance))
				{
					// Check weapon
					new ActiveWeapon = GetEntPropEnt(medic, Prop_Data, "m_hActiveWeapon");
					if (ActiveWeapon < 0)
						continue;
					decl String:sWeapon[32];
					GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
					
					if ((StrContains(sWeapon, "weapon_defib") > -1) || (StrContains(sWeapon, "weapon_knife") > -1) || (StrContains(sWeapon, "weapon_kabar") > -1))
					{
						bCanHealPaddle = true;
					}
					if ((StrContains(sWeapon, "weapon_healthkit") > -1))
					{
						bCanHealMedpack = true;
					}
				}

				// Check heal
				new iHealth = GetClientHealth(iTarget);

				if (tDistance < 750.0)
				{
					PrintHintText(medic, "%N\nHP: %i", iTarget, iHealth);
				}

				if (bCanHealPaddle)
				{
					if (iHealth < 100)
					{
						iHealth += g_iHeal_amount_paddles;
						g_playerMedicHealsAccumulated[medic] += g_iHeal_amount_paddles;
						new iHealthCap = GetConVarInt(sm_heal_cap_for_bonus);
						new iRewardMedicEnabled = GetConVarInt(sm_reward_medics_enabled);
						//Reward player for healing
						if (g_playerMedicHealsAccumulated[medic] >= iHealthCap && iRewardMedicEnabled == 1)
						{
							g_playerMedicHealsAccumulated[medic] = 0;
							// new iBonus = GetConVarInt(sm_heal_bonus);
							// new iScore = GetClientFrags(medic) + iBonus;
							// SetEntProp(medic, Prop_Data, "m_iFrags", iScore);
							g_iSpawnTokens[medic]++;
							decl String:sBuf2[255];
							// if (iBonus > 1)
							//	Format(sBuf2, 255,"Awarded %i kills for healing %i in HP of other players.", iBonus, iHealthCap);
							// else
							Format(sBuf2, 255,"Awarded %i life for healing %i in HP of other players.", 1, iHealthCap);
							
							PrintToChat(medic, "%s", sBuf2);
						}
						
						if (iHealth >= 100)
						{
							////////////////////////
							// Rank System
							g_iStatHeals[medic]++;
							//
							////////////////////////

							iHealth = 100;
							//Client_PrintToChatAll(false, "{OG}%N{N} healed {OG}%N", medic, iTarget);
							//PrintToChatAll("\x05%N\x01 healed \x05%N", medic, iTarget);
							PrintHintText(iTarget, "You were healed by %N (HP: %i)", medic, iHealth);
							decl String:sBuf[255];
							Format(sBuf, 255,"You fully healed %N", iTarget);
							PrintHintText(medic, "%s", sBuf);
							PrintToChat(medic, "%s", sBuf);

							//YellOutHealed(medic);
							//SetCooldownHealed(medic);
						}
						else
						{
							PrintHintText(iTarget, "DON'T MOVE! %N is healing you.(HP: %i)", medic, iHealth);
						}
						
						SetEntityHealth(iTarget, iHealth);
						PrintHintText(medic, "%N\nHP: %i\n\nHealing with paddles for: %i", iTarget, iHealth, g_iHeal_amount_paddles);
						//Check for sound cooldown
						/*if (PlayerCooldownHealing[medic]) 
						{
							if (CurrentTime < PlayerTimedoneHealing[medic])
							{} 
							else 
							{
								RemoveCooldownHealing(medic);
							}
						} 
						else 
						{
							YellOutHealing(medic);
							SetCooldownHealing(medic);
						}*/
						/*if (PlayerCooldownHealed[medic]) 
						{
							if (CurrentTime < PlayerTimedoneHealed[medic])
							{} 
							else 
							{
								RemoveCooldownHealed(medic);
							}
						}*/
					}
					else
					{
						PrintHintText(medic, "%N\nHP: %i", iTarget, iHealth);
					}
				}
				else if (bCanHealMedpack)
				{
					if (iHealth < 100)
					{
						iHealth += g_iHeal_amount_medPack;
						g_playerMedicHealsAccumulated[medic] += g_iHeal_amount_medPack;
						new iHealthCap = GetConVarInt(sm_heal_cap_for_bonus);
						new iRewardMedicEnabled = GetConVarInt(sm_reward_medics_enabled);
						//Reward player for healing
						if (g_playerMedicHealsAccumulated[medic] >= iHealthCap && iRewardMedicEnabled == 1)
						{
							g_playerMedicHealsAccumulated[medic] = 0;
							// new iBonus = GetConVarInt(sm_heal_bonus);
							// new iScore = GetClientFrags(medic) + iBonus;
							// SetEntProp(medic, Prop_Data, "m_iFrags", iScore);
							g_iSpawnTokens[medic]++;
							decl String:sBuf2[255];
							// if (iBonus > 1)
							//	Format(sBuf2, 255,"Awarded %i kills for healing %i in HP of other players.", iBonus, iHealthCap);
							// else
							Format(sBuf2, 255,"Awarded %i life for healing %i in HP of other players.", 1, iHealthCap);
							
							PrintToChat(medic, "%s", sBuf2);
						}

						if (iHealth >= 100)
						{
							////////////////////////
							// Rank System
							g_iStatHeals[medic]++;
							//
							////////////////////////
							iHealth = 100;
							
							//Client_PrintToChatAll(false, "{OG}%N{N} healed {OG}%N", medic, iTarget);
							//PrintToChatAll("\x05%N\x01 healed \x05%N", medic, iTarget);
							PrintHintText(iTarget, "You were healed by %N (HP: %i)", medic, iHealth);
							decl String:sBuf[255];
							Format(sBuf, 255,"You fully healed %N", iTarget);
							PrintHintText(medic, "%s", sBuf);
							PrintToChat(medic, "%s", sBuf);

							//YellOutHealed(medic);
							//SetCooldownHealed(medic);
						}
						else
						{
							PrintHintText(iTarget, "DON'T MOVE! %N is healing you.(HP: %i)", medic, iHealth);
						}
						
						SetEntityHealth(iTarget, iHealth);
						PrintHintText(medic, "%N\nHP: %i\n\nHealing with medpack for: %i", iTarget, iHealth, g_iHeal_amount_medPack);

						//Check for sound cooldown
						/*if (PlayerCooldownHealing[medic]) 
						{
							if (CurrentTime < PlayerTimedoneHealing[medic])
							{} 
							else 
							{
								RemoveCooldownHealing(medic);
							}
						} 
						else 
						{
							YellOutHealing(medic);
							SetCooldownHealing(medic);
						}*/
						/*if (PlayerCooldownHealed[medic]) 
						{
							if (CurrentTime < PlayerTimedoneHealed[medic])
							{} 
							else 
							{
								RemoveCooldownHealed(medic);
							}
						}*/
					}
					else
					{
						PrintHintText(medic, "%N\nHP: %i", iTarget, iHealth);
					}
				}
			}
			else //Heal Self
			{
				// Check distance
				new bool:bCanHealMedpack = false;
				new bool:bCanHealPaddle = false;
				
				// Check weapon
				new ActiveWeapon = GetEntPropEnt(medic, Prop_Data, "m_hActiveWeapon");
				if (ActiveWeapon < 0)
					continue;
				decl String:sWeapon[32];
				GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));

				if ((StrContains(sWeapon, "weapon_defib") > -1) || (StrContains(sWeapon, "weapon_knife") > -1) || (StrContains(sWeapon, "weapon_kabar") > -1) || (StrContains(sWeapon, "weapon_katana") > -1))
				{
					bCanHealPaddle = true;
				}
				if ((StrContains(sWeapon, "weapon_healthkit") > -1))
				{
					bCanHealMedpack = true;
				}
				
				// Check heal
				new iHealth = GetClientHealth(medic);
				if (bCanHealMedpack || bCanHealPaddle)
				{
					if (iHealth < g_medicHealSelf_max)
					{
						if (bCanHealMedpack)
							iHealth += g_iHeal_amount_medPack;
						else
							iHealth += g_iHeal_amount_paddles;

						if (iHealth >= g_medicHealSelf_max)
						{
							iHealth = g_medicHealSelf_max;
							PrintHintText(medic, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_medicHealSelf_max);
						}
						else 
						{
							PrintHintText(medic, "Healing Self (HP: %i) | MAX: %i", iHealth, g_medicHealSelf_max);
						}
						SetEntityHealth(medic, iHealth);
					}
				}
			}
		}
		else if (iTeam == TEAM_1_SEC && IsPlayerAlive(medic) && !(StrContains(g_client_last_classstring[medic], "medic") > -1))
		{
			// Check weapon for non medics outside
			new ActiveWeapon = GetEntPropEnt(medic, Prop_Data, "m_hActiveWeapon");
			if (ActiveWeapon < 0)
				continue;
			decl String:checkWeapon[32];
			GetEdictClassname(ActiveWeapon, checkWeapon, sizeof(checkWeapon));
			if ((StrContains(checkWeapon, "weapon_healthkit") > -1))
			{
				// Target is teammate and alive.
				new iTarget = TraceClientViewEntity(medic);
				if(iTarget > 0 && iTarget <= MaxClients && IsClientInGame(iTarget) && IsPlayerAlive(iTarget) && iTeam == GetClientTeam(iTarget))
				{
					// Check distance
					new bool:bCanHealMedpack = false;
					new Float:fReviveDistance = 80.0;
					new Float:vecMedicPos[3];
					new Float:vecTargetPos[3];
					new Float:tDistance;
					GetClientAbsOrigin(medic, Float:vecMedicPos);
					GetClientAbsOrigin(iTarget, Float:vecTargetPos);
					tDistance = GetVectorDistance(vecMedicPos,vecTargetPos);
					
					if (tDistance < fReviveDistance && ClientCanSeeVector(medic, vecTargetPos, fReviveDistance))
					{
						// Check weapon
						if (ActiveWeapon < 0)
							continue;

						decl String:sWeapon[32];
						GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
						if ((StrContains(sWeapon, "weapon_healthkit") > -1))
						{
							bCanHealMedpack = true;
						}
					}
					// Check heal
					new iHealth = GetClientHealth(iTarget);

					if (tDistance < 750.0) 
					{
						PrintHintText(medic, "%N\nHP: %i", iTarget, iHealth);
					}
					if (bCanHealMedpack)
					{
						if (iHealth < g_nonMedic_maxHealOther)
						{
							iHealth += g_nonMedicHeal_amount;
							g_playerNonMedicHealsAccumulated[medic] += g_nonMedicHeal_amount;
							new iHealthCap = GetConVarInt(sm_heal_cap_for_bonus);
							new iRewardMedicEnabled = GetConVarInt(sm_reward_medics_enabled);
							//Reward player for healing
							if (g_playerNonMedicHealsAccumulated[medic] >= iHealthCap && iRewardMedicEnabled == 1)
							{
								g_playerNonMedicHealsAccumulated[medic] = 0;
								// new iBonus = GetConVarInt(sm_heal_bonus);
								// new iScore = GetClientFrags(medic) + iBonus;
								// SetEntProp(medic, Prop_Data, "m_iFrags", iScore);
								g_iSpawnTokens[medic]++;
								decl String:sBuf2[255];
								// if (iBonus > 1)
								//	Format(sBuf2, 255,"Awarded %i kills for healing %i in HP of other players.", iBonus, iHealthCap);
								// else
								Format(sBuf2, 255,"Awarded %i life for healing %i in HP of other players.", 1, iHealthCap);
								
								PrintToChat(medic, "%s", sBuf2);
							}

							if (iHealth >= g_nonMedic_maxHealOther)
							{
								////////////////////////
								// Rank System
								g_iStatHeals[medic]++;
								//
								////////////////////////
								iHealth = g_nonMedic_maxHealOther;
								
								//Client_PrintToChatAll(false, "{OG}%N{N} healed {OG}%N", medic, iTarget);
								//PrintToChatAll("\x05%N\x01 healed \x05%N", medic, iTarget);
								PrintHintText(iTarget, "Non-Medic %N can only heal you for %i HP!)", medic, iHealth);
								
								decl String:sBuf[255];
								Format(sBuf, 255,"You max healed %N", iTarget);
								PrintHintText(medic, "%s", sBuf);
								PrintToChat(medic, "%s", sBuf);
							}
							else
							{
								PrintHintText(iTarget, "DON'T MOVE! %N is healing you.(HP: %i)", medic, iHealth);
							}
							
							SetEntityHealth(iTarget, iHealth);
							PrintHintText(medic, "%N\nHP: %i\n\nHealing.", iTarget, iHealth);
						}
						else
						{
							if (iHealth < g_nonMedic_maxHealOther)
							{
								PrintHintText(medic, "%N\nHP: %i", iTarget, iHealth);
							}
							else if (iHealth >= g_nonMedic_maxHealOther)
								PrintHintText(medic, "%N\nHP: %i (MAX YOU CAN HEAL)", iTarget, iHealth);

						}
					}
				}
				else //Heal Self
				{
					// Check distance
					new bool:bCanHealMedpack = false;
					
					// Check weapon
					if (ActiveWeapon < 0)
						continue;
					decl String:sWeapon[32];
					GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));

					if ((StrContains(sWeapon, "weapon_healthkit") > -1))
					{
						bCanHealMedpack = true;
					}
					
					// Check heal
					new iHealth = GetClientHealth(medic);
					if (bCanHealMedpack)
					{
						if (iHealth < g_nonMedicHealSelf_max)
						{
							iHealth += g_nonMedicHeal_amount;
							if (iHealth >= g_nonMedicHealSelf_max)
							{
								iHealth = g_nonMedicHealSelf_max;
								PrintHintText(medic, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_nonMedicHealSelf_max);
							}
							else
							{
								PrintHintText(medic, "Healing Self (HP: %i) | MAX: %i", iHealth, g_nonMedicHealSelf_max);
							}
							
							SetEntityHealth(medic, iHealth);
						}
					}
				}
			}
			// show player names if sv_hud_targetindicator off
			/*else if (GetConVarInt(FindConVar("sv_hud_targetindicator")) == 0)
			{
				// Target is teammate and alive.
				new iTarget = TraceClientViewEntity(medic);
				if(iTarget > 0 && iTarget <= MaxClients && IsClientInGame(iTarget) && IsPlayerAlive(iTarget) && iTeam == GetClientTeam(iTarget))
				{
					// Check distance
					new Float:vecMedicPos[3];
					new Float:vecTargetPos[3];
					new Float:tDistance;
					GetClientAbsOrigin(medic, Float:vecMedicPos);
					GetClientAbsOrigin(iTarget, Float:vecTargetPos);
					tDistance = GetVectorDistance(vecMedicPos,vecTargetPos);
					if (tDistance < 90.0) 
					{
						PrintHintText(medic, "%N", iTarget);
					}
				}
			}*/
		}
	}
	
	return Plugin_Continue;
}

// public Action:Timer_ElitePeriodTick(Handle:timer, any:data)
// {
//	new fTempTime = 
//	if (g_elitePeriod == 0)
//	{


//	}

// }

//Main AI Director Tick
public Action:Timer_AIDirector_Main(Handle:timer, any:data)
{
	g_AIDir_ChangeCond_Counter++;

	//AI Director Set Difficulty
	if (g_AIDir_ChangeCond_Counter >= g_AIDir_ChangeCond_Rand)
	{
		g_AIDir_ChangeCond_Counter = 0;
		g_AIDir_ChangeCond_Rand = GetRandomInt(g_AIDir_ChangeCond_Min, g_AIDir_ChangeCond_Max);
		//PrintToServer("[AI_DIRECTOR] STATUS: %i | SetDifficulty CALLED", g_AIDir_TeamStatus);
		AI_Director_SetDifficulty();
	}

	// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	
	//Confirm percent finale
	if ((acp+1) == ncp)
	{
		if (g_finale_counter_spec_enabled == 1)
				g_dynamicSpawnCounter_Perc = g_finale_counter_spec_percent;
	}

	return Plugin_Continue;

}

public Action:Timer_AmmoResupply(Handle:timer, any:data)
{
	if (g_iRoundStatus == 0) return Plugin_Continue;
	for (new client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client))
			continue;
		new team = GetClientTeam(client); 
		// Valid medic?
		if (IsPlayerAlive(client) && team == TEAM_1_SEC)
		{
			new ActiveWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
			if (ActiveWeapon < 0)
				continue;

			// Get weapon class name
			decl String:sWeapon[32];
			GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
			if (GetClientButtons(client) & INS_RELOAD && ((StrContains(sWeapon, "weapon_defib") > -1) || (StrContains(sWeapon, "weapon_knife") > -1) || (StrContains(sWeapon, "weapon_kabar") > -1)	|| (StrContains(sWeapon, "weapon_knife") > -1)	|| (StrContains(sWeapon, "weapon_katana") > -1)))
			{
				new validAmmoCache = -1;
				validAmmoCache = FindValidProp_InDistance(client);
				//PrintToServer("validAmmoCache: %d", validAmmoCache);
				if (validAmmoCache != -1)
				{
					g_resupplyCounter[client] -= 1;
					if (g_ammoResupplyAmt[validAmmoCache] <= 0)
					{
						new secTeamCount = GetTeamSecCount();
						g_ammoResupplyAmt[validAmmoCache] = (secTeamCount / 3);
						if (g_ammoResupplyAmt[validAmmoCache] <= 1)
						{
							g_ammoResupplyAmt[validAmmoCache] = 1;
						}

					}
					decl String:sBuf[255];
					// Hint to client
					Format(sBuf, 255,"Resupplying ammo in %d seconds | Supply left: %d", g_resupplyCounter[client], g_ammoResupplyAmt[validAmmoCache]);
					PrintHintText(client, "%s", sBuf);
					if (g_resupplyCounter[client] <= 0)
					{
						g_resupplyCounter[client] = GetConVarInt(sm_resupply_delay);
						//Spawn player again
						AmmoResupply_Player(client, 0, 0, 0);
						

						g_ammoResupplyAmt[validAmmoCache] -= 1;
						if (g_ammoResupplyAmt[validAmmoCache] <= 0)
						{
							if(validAmmoCache != -1)
								AcceptEntityInput(validAmmoCache, "kill");
						}
						Format(sBuf, 255,"Rearmed! Ammo Supply left: %d", g_ammoResupplyAmt[validAmmoCache]);
						
						PrintHintText(client, "%s", sBuf);
						PrintToChat(client, "%s", sBuf);

					}
				}
			}
		}
	}
	return Plugin_Continue;
}

public AmmoResupply_Player(client, primaryRemove, secondaryRemove, grenadesRemove)
{

	new Float:plyrOrigin[3];
	new Float:tempOrigin[3];
	GetClientAbsOrigin(client,plyrOrigin);
	tempOrigin = plyrOrigin;
	tempOrigin[2] = -5000.0;

	//TeleportEntity(client, tempOrigin, NULL_VECTOR, NULL_VECTOR);
	//ForcePlayerSuicide(client);
	// Get dead body
	new clientRagdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
	
	//This timer safely removes client-side ragdoll
	if(clientRagdoll > 0 && IsValidEdict(clientRagdoll) && IsValidEntity(clientRagdoll))
	{
		// Get dead body's entity
		new ref = EntIndexToEntRef(clientRagdoll);
		new entity = EntRefToEntIndex(ref);
		if(entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
		{
			// Remove dead body's entity
			AcceptEntityInput(entity, "Kill");
			clientRagdoll = INVALID_ENT_REFERENCE;
		}
	}

	ForceRespawnPlayer(client, client);
	TeleportEntity(client, plyrOrigin, NULL_VECTOR, NULL_VECTOR);
	RemoveWeapons(client, primaryRemove, secondaryRemove, grenadesRemove);
	PrintHintText(client, "Ammo Resupplied");
	playerInRevivedState[client] = false;
	// //Give back life
	// new iDeaths = GetClientDeaths(client) - 1;
	// SetEntProp(client, Prop_Data, "m_iDeaths", iDeaths);
}
//Find Valid Prop
public RemoveWeapons(client, primaryRemove, secondaryRemove, grenadesRemove)
{

	new primaryWeapon = GetPlayerWeaponSlot(client, 0);
	new secondaryWeapon = GetPlayerWeaponSlot(client, 1);
	new playerGrenades = GetPlayerWeaponSlot(client, 3);

	// Check and remove primaryWeapon
	if (primaryWeapon != -1 && IsValidEntity(primaryWeapon) && primaryRemove == 1) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 13
	{
		// Remove primaryWeapon
		decl String:weapon[32];
		GetEntityClassname(primaryWeapon, weapon, sizeof(weapon));
		RemovePlayerItem(client,primaryWeapon);
		AcceptEntityInput(primaryWeapon, "kill");
	}
	// Check and remove secondaryWeapon
	if (secondaryWeapon != -1 && IsValidEntity(secondaryWeapon) && secondaryRemove == 1) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 13
	{
		// Remove primaryWeapon
		decl String:weapon[32];
		GetEntityClassname(secondaryWeapon, weapon, sizeof(weapon));
		RemovePlayerItem(client,secondaryWeapon);
		AcceptEntityInput(secondaryWeapon, "kill");
	}
	// Check and remove grenades
	if (playerGrenades != -1 && IsValidEntity(playerGrenades) && grenadesRemove == 1) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 13
	{
		while (playerGrenades != -1 && IsValidEntity(playerGrenades)) // since we only have 3 slots in current theate
		{
			playerGrenades = GetPlayerWeaponSlot(client, 3);
			if (playerGrenades != -1 && IsValidEntity(playerGrenades)) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 1
			{
				// Remove grenades
				decl String:weapon[32];
				GetEntityClassname(playerGrenades, weapon, sizeof(weapon));
				RemovePlayerItem(client,playerGrenades);
				AcceptEntityInput(playerGrenades, "kill");
				
			}
		}
	}
}
//Find Valid Prop
public FindValidProp_InDistance(client)
{

	new prop;
	while ((prop = FindEntityByClassname(prop, "prop_dynamic_override")) != -1)
	{
		new String:propModelName[128];
		GetEntPropString(prop, Prop_Data, "m_ModelName", propModelName, 128);
		//PrintToChatAll("propModelName %s", propModelName);
		if (StrEqual(propModelName, "models/sernix/ammo_cache/ammo_cache_small.mdl") || StrContains(propModelName, "models/sernix/ammo_cache/ammo_cache_small.mdl") > -1)
		{
			new Float:tDistance = (GetEntitiesDistance(client, prop));
			if (tDistance <= (GetConVarInt(sm_ammo_resupply_range)))
			{
				return prop;
			}
		}

	}
	return -1;
}
stock AI_Director_IsSpecialtyBot(client)
{
	if (IsFakeClient(client) && ((StrContains(g_client_last_classstring[client], "bomber") > -1) || (StrContains(g_client_last_classstring[client], "tank") > -1)))
		return true;
	else
		return false;
}
stock Float:GetEntitiesDistance(ent1, ent2)
{
	new Float:orig1[3];
	GetEntPropVector(ent1, Prop_Send, "m_vecOrigin", orig1);
	
	new Float:orig2[3];
	GetEntPropVector(ent2, Prop_Send, "m_vecOrigin", orig2);

	return GetVectorDistance(orig1, orig2);
}

// Check for nearest player
public Action:Timer_NearestBody(Handle:timer, any:data)
{
	// Check round state
	if (g_iRoundStatus == 0) return Plugin_Continue;
	
	// Variables to store
	new Float:fMedicPosition[3];
	new Float:fMedicAngles[3];
	new Float:fInjuredPosition[3];
	new Float:fNearestDistance;
	new Float:fTempDistance;

	// iNearestInjured client
	new iNearestInjured;

	//not in progress being revived by medic
	int iNearestInjuredNIP;
	float fNearestDistanceNIP;

	//total players can be revived count
	int TotalCanBeRevied;
	
	decl String:sDirection[64];
	decl String:sDistance[64];
	decl String:sHeight[11];

	// Client loop
	for (new medic = 1; medic <= MaxClients; medic++)
	{
		if (!IsClientInGame(medic) || IsFakeClient(medic))
			continue;
		
		// Valid medic?
		if (IsPlayerAlive(medic) && (StrContains(g_client_last_classstring[medic], "medic") > -1))
		{
			// Reset variables
			iNearestInjured = 0;
			fNearestDistance = 0.0;

			iNearestInjuredNIP = 0;
			fNearestDistanceNIP = 0.0;

			TotalCanBeRevied = 0;
			
			// Get medic position
			GetClientAbsOrigin(medic, fMedicPosition);

			//PrintToServer("MEDIC DETECTED ********************");
			// Search dead body
			for (new search = 1; search <= MaxClients; search++)
			{
				if (!IsClientInGame(search) || IsFakeClient(search) || IsPlayerAlive(search))
					continue;
				
				// Check if valid
				if (g_iHurtFatal[search] == 0 && search != medic && GetClientTeam(medic) == GetClientTeam(search))
				{
					if (InProgressReviveByMedic[search] == true)
					{
						int CurrentTime = GetTime();
						if ((CurrentTime - LastTimeCheckedReviveProgress[search]) >= 2)
						InProgressReviveByMedic[search] = false;
					}
					// Get found client's ragdoll
					new clientRagdoll = EntRefToEntIndex(g_iClientRagdolls[search]);
					if (clientRagdoll > 0 && IsValidEdict(clientRagdoll) && IsValidEntity(clientRagdoll) && clientRagdoll != INVALID_ENT_REFERENCE)
					{
						// Get ragdoll's position
						fInjuredPosition = g_fRagdollPosition[search];
						// Get distance from ragdoll
						fTempDistance = GetVectorDistance(fMedicPosition, fInjuredPosition);

						// Is he more fNearestDistance to the player as the player before?
						if (fNearestDistance == 0.0)
						{
							fNearestDistance = fTempDistance;
							iNearestInjured = search;
						}
						// Set new distance and new iNearestInjured player
						else if (fTempDistance < fNearestDistance)
						{
							fNearestDistance = fTempDistance;
							iNearestInjured = search;
						}
						//--- not in progress being revived by medic
						if (InProgressReviveByMedic[search] == false)
						{
							if (fNearestDistanceNIP == 0.0)
							{
								fNearestDistanceNIP = fTempDistance;
								iNearestInjuredNIP = search;
							}
							else if (fTempDistance < fNearestDistanceNIP)
							{
								fNearestDistanceNIP = fTempDistance;
								iNearestInjuredNIP = search;
							}
							//---
						}
						TotalCanBeRevied++;
					}
				}
			}
			
			// Found a dead body?
			if (iNearestInjured != 0)
			{
				// Set iNearestInjured body
				g_iNearestBody[medic] = iNearestInjured;

				if (iNearestInjuredNIP != 0)
				{
					// Get medic angle
					GetClientAbsAngles(medic, fMedicAngles);

					// Get direction string (if it cause server lag, remove this)
					GetDirectionString(fMedicAngles, fMedicPosition, fInjuredPosition, sDirection);
					
					// Get distance string
					GetDistanceString(fNearestDistanceNIP, sDistance);
					// Get height string
					GetHeightString(fMedicPosition, fInjuredPosition, sHeight);
					
					// Print iNearestInjured dead body's distance and direction text
					//PrintCenterText(medic, "Nearest dead: %N (%s)", iNearestInjured, sDistance);
					PrintCenterText(medic, "Nearest dead[%d]: %N ( %s | %s | %s )", TotalCanBeRevied, iNearestInjuredNIP, sDistance, sDirection, sHeight);

					float beamPos[3];
					beamPos = fInjuredPosition;
					beamPos[2] += 0.3;
					if (fTempDistance >= 140)
					{
						//Attack markers option
						//Effect_SetMarkerAtPos(medic,beamPos,1.0,{255, 0, 0, 255}); 

						//Beam dead when farther
						TE_SetupBeamRingPoint(beamPos, 1.0, Revive_Indicator_Radius, g_iBeaconBeam, g_iBeaconHalo, 0, 15, 5.0, 3.0, 5.0, {255, 0, 0, 255}, 1, FBEAM_FADEIN | FBEAM_FADEOUT);
						//void TE_SetupBeamRingPoint(const float center[3], float Start_Radius, float End_Radius, int ModelIndex, int HaloIndex, int StartFrame, int FrameRate, float Life, float Width, float Amplitude, const int Color[4], int Speed, int Flags)
						TE_SendToClient(medic);
					}
				}
			}
			else
			{
				// Reset iNearestInjured body
				g_iNearestBody[medic] = -1;
			}
		}
		else if (IsPlayerAlive(medic) && !(StrContains(g_client_last_classstring[medic], "medic") > -1))
		{
			// Reset variables
			iNearestInjured = 0;
			fNearestDistance = 0.0;
			
			// Get medic position
			GetClientAbsOrigin(medic, fMedicPosition);

			//PrintToServer("MEDIC DETECTED ********************");
			// Search dead body
			for (new search = 1; search <= MaxClients; search++)
			{
				if (!IsClientInGame(search) || IsFakeClient(search) || IsPlayerAlive(search))
					continue;
				
				// Check if valid
				if (g_iHurtFatal[search] == 0 && search != medic && GetClientTeam(medic) == GetClientTeam(search))
				{
					// Get found client's ragdoll
					new clientRagdoll = EntRefToEntIndex(g_iClientRagdolls[search]);
					if (clientRagdoll > 0 && IsValidEdict(clientRagdoll) && IsValidEntity(clientRagdoll) && clientRagdoll != INVALID_ENT_REFERENCE)
					{
						// Get ragdoll's position
						fInjuredPosition = g_fRagdollPosition[search];
						
						// Get distance from ragdoll
						fTempDistance = GetVectorDistance(fMedicPosition, fInjuredPosition);

						// Is he more fNearestDistance to the player as the player before?
						if (fNearestDistance == 0.0)
						{
							fNearestDistance = fTempDistance;
							iNearestInjured = search;
						}
						// Set new distance and new iNearestInjured player
						else if (fTempDistance < fNearestDistance)
						{
							fNearestDistance = fTempDistance;
							iNearestInjured = search;
						}
					}
				}
			}
			
			// Found a dead body?
			if (iNearestInjured != 0)
			{
				// Set iNearestInjured body
				g_iNearestBody[medic] = iNearestInjured;
				
			}
			else
			{
				// Reset iNearestInjured body
				g_iNearestBody[medic] = -1;
			}
		}
	}
	
	return Plugin_Continue;
}


public Check_NearbyPlayers(enemyBot)
{
	for (new client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client))
		{
			if (IsPlayerAlive(client))
			{
				new Float:botOrigin[3];
				new Float:clientOrigin[3];
				new Float:fDistance;
		
				GetClientAbsOrigin(enemyBot,botOrigin);
				GetClientAbsOrigin(client,clientOrigin);
				
				//determine distance from the two
				fDistance = GetVectorDistance(botOrigin,clientOrigin);

				if (fDistance <= 600)
				{
					return true;
				}
			}
		}
	}
	return false;
}

/**
 * Get direction string for nearest dead body
 *
 * @param fClientAngles[3]		Client angle
 * @param fClientPosition[3]	Client position
 * @param fTargetPosition[3]	Target position
 * @Return						direction string.
 */
void GetDirectionString(float fClientAngles[3], float fClientPosition[3], float fTargetPosition[3], char sDirection[64])
{
	float fTempAngles[3], fTempPoints[3];
		
	// Angles from origin
	MakeVectorFromPoints(fClientPosition, fTargetPosition, fTempPoints);
	GetVectorAngles(fTempPoints, fTempAngles);
	
	// Differenz
	float fDiff = fClientAngles[1] - fTempAngles[1];
	
	// Correct it
	if (fDiff < -180)
		fDiff = 360 + fDiff;

	if (fDiff > 180)
		fDiff = 360 - fDiff;
	
	// Now geht the direction
	// Up
	if (fDiff >= -22.5 && fDiff < 22.5)
		Format(sDirection, sizeof(sDirection), "FWD");//"\xe2\x86\x91");
	// right up
	else if (fDiff >= 22.5 && fDiff < 67.5)
		Format(sDirection, sizeof(sDirection), "FWD-RIGHT");//"\xe2\x86\x97");
	// right
	else if (fDiff >= 67.5 && fDiff < 112.5)
		Format(sDirection, sizeof(sDirection), "RIGHT");//"\xe2\x86\x92");
	// right down
	else if (fDiff >= 112.5 && fDiff < 157.5)
		Format(sDirection, sizeof(sDirection), "BACK-RIGHT");//"\xe2\x86\x98");
	// down
	else if (fDiff >= 157.5 || fDiff < -157.5)
		Format(sDirection, sizeof(sDirection), "BACK");//"\xe2\x86\x93");
	// down left
	else if (fDiff >= -157.5 && fDiff < -112.5)
		Format(sDirection, sizeof(sDirection), "BACK-LEFT");//"\xe2\x86\x99");
	// left
	else if (fDiff >= -112.5 && fDiff < -67.5)
		Format(sDirection, sizeof(sDirection), "LEFT");//"\xe2\x86\x90");
	// left up
	else if (fDiff >= -67.5 && fDiff < -22.5)
		Format(sDirection, sizeof(sDirection), "FWD-LEFT");//"\xe2\x86\x96");
}

// Return distance string
void GetDistanceString(float fDistance, char sResult[64])
{
	// Distance to meters
	new Float:fTempDistance = fDistance * 0.01905;

	// Distance to feet?
	if (g_iUnitMetric == 1)
	{
		// Meter
		Format(sResult, sizeof(sResult), "%.0f meter", fTempDistance);
		return;
	}

	fTempDistance = fTempDistance * 3.2808399;

	// Feet
	Format(sResult, sizeof(sResult), "%.0f feet", fTempDistance);
	return;
}

/**
 * Get height string for nearest dead body
 *
 * @param fClientPosition[3]	Client position
 * @param fTargetPosition[3]	Target position
 * @Return						height string.
 */
void GetHeightString(float fClientPosition[3], float fTargetPosition[3], char s[11])
{
	decl Float:verticalDifference;
	decl Float:fTempDistance;
	char unit = 'm';

	verticalDifference = FloatAbs(fClientPosition[2] - fTargetPosition[2]);
	fTempDistance = verticalDifference * 0.01905; // Distance to meters

	if (g_iUnitMetric == 1)
	{
		fTempDistance = fTempDistance * 3.2808399; // Distance to feet
		unit = '\'';
	}
	
	if (fClientPosition[2]+64 < fTargetPosition[2])
	{
        Format(s, sizeof(s), "ABOVE %.0f%s", fTempDistance, unit);
		return;
	}

	if (fClientPosition[2]-64 > fTargetPosition[2])
	{
        Format(s, sizeof(s), "BELOW %.0f%s", fTempDistance, unit);
		return;
	}

	s = "LEVEL";
}
// Check tags
stock TagsCheck(const String:tag[], bool:remove = false)
{
	new Handle:hTags = FindConVar("sv_tags");
	decl String:tags[255];
	GetConVarString(hTags, tags, sizeof(tags));

	if (StrContains(tags, tag, false) == -1 && !remove)
	{
		decl String:newTags[255];
		Format(newTags, sizeof(newTags), "%s,%s", tags, tag);
		ReplaceString(newTags, sizeof(newTags), ",,", ",", false);
		SetConVarString(hTags, newTags);
		GetConVarString(hTags, tags, sizeof(tags));
	}
	else if (StrContains(tags, tag, false) > -1 && remove)
	{
		ReplaceString(tags, sizeof(tags), tag, "", false);
		ReplaceString(tags, sizeof(tags), ",,", ",", false);
		SetConVarString(hTags, tags);
	}
}

// Get tesm2 player count
stock GetTeamSecCount() {
	new clients = 0;
	new iTeam;
	for( new i = 1; i <= MaxClients; i++ ) {
		if (IsClientInGame(i))
		{
			iTeam = GetClientTeam(i);
			if(iTeam == TEAM_1_SEC)
				clients++;
		}
	}
	return clients;
}

// Get real client count
stock GetRealClientCount( bool:inGameOnly = true ) {
	int clients = 0;
	for(int i = 1; i <= MaxClients; i++ ) {
		if((inGameOnly ? IsClientInGame(i) : IsClientConnected(i)) && !IsFakeClient(i))
			clients++;
	}

	return clients;
}

// Get insurgent team bot count
stock GetTeamInsCount() {
	int clients;
	for(int i = 1; i <= MaxClients; i++ ) {
		if (IsClientInGame(i) && IsClientConnected(i) && IsFakeClient(i))
			clients++;
	}
	return clients;
}

// Get remaining life
stock GetRemainingLife()
{
	new iResult;
	for (new i = 1; i <= MaxClients; i++)
	{
		if (i > 0 && IsClientConnected(i) && IsClientInGame(i) && IsPlayerAlive(i) && !IsFakeClient(i))
		{
			if (g_iSpawnTokens[i] > 0)
				iResult = iResult + g_iSpawnTokens[i];
		}
	}
	
	return iResult;
}

// Trace client's view entity
stock TraceClientViewEntity(client)
{
	new Float:m_vecOrigin[3];
	new Float:m_angRotation[3];

	GetClientEyePosition(client, m_vecOrigin);
	GetClientEyeAngles(client, m_angRotation);

	new Handle:tr = TR_TraceRayFilterEx(m_vecOrigin, m_angRotation, MASK_VISIBLE, RayType_Infinite, TRDontHitSelf, client);
	new pEntity = -1;

	if (TR_DidHit(tr))
	{
		pEntity = TR_GetEntityIndex(tr);
		CloseHandle(tr);
		return pEntity;
	}

	if(tr != INVALID_HANDLE)
	{
		CloseHandle(tr);
	}
	
	return -1;
}

// Check is hit self
public bool:TRDontHitSelf(entity, mask, any:data) // Don't ray trace ourselves -_-"
{
	return (1 <= entity <= MaxClients) && (entity != data);
}

//Find Valid Antenna
public FindValid_Antenna()
{
	new prop;
	while ((prop = FindEntityByClassname(prop, "prop_dynamic_override")) != INVALID_ENT_REFERENCE)
	{
		new String:propModelName[128];
		GetEntPropString(prop, Prop_Data, "m_ModelName", propModelName, 128);

		new String:targetname[64];
		GetEntPropString(prop, Prop_Data, "m_iName", targetname, sizeof(targetname));

		if (StrEqual(propModelName, "models/sernix/ied_jammer/ied_jammer.mdl"))
		{
			if(StrContains(targetname,"holo", false) == -1) {
				return prop;
			}
		}
	}
	return -1;
}

/*
########################LUA HEALING INTEGRATION######################
#	This portion of the script adds in health packs from Lua		#
##############################START##################################
#####################################################################
*/
public Action:Event_GrenadeThrown(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	new nade_id = GetEventInt(event, "entityid");

	// Validate client index first
	if (client < 1 || client > MaxClients)
		return Plugin_Continue;
	if (!IsClientInGame(client))
		return Plugin_Continue;
	if (!IsPlayerAlive(client))
		return Plugin_Continue;
	if (nade_id < 0)
		return Plugin_Continue;

	decl String:grenade_name[32];
			GetEntityClassname(nade_id, grenade_name, sizeof(grenade_name));
			if (StrEqual(grenade_name, "healthkit"))
			{
				switch(GetRandomInt(1, 18))
				{
					case 1: EmitSoundToAll("player/voice/radial/security/leader/unsuppressed/need_backup1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 2: EmitSoundToAll("player/voice/radial/security/leader/unsuppressed/need_backup2.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 3: EmitSoundToAll("player/voice/radial/security/leader/unsuppressed/need_backup3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 4: EmitSoundToAll("player/voice/radial/security/leader/unsuppressed/holdposition2.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 5: EmitSoundToAll("player/voice/radial/security/leader/unsuppressed/holdposition3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 6: EmitSoundToAll("player/voice/radial/security/leader/unsuppressed/moving2.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 7: EmitSoundToAll("player/voice/radial/security/leader/suppressed/backup3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 8: EmitSoundToAll("player/voice/radial/security/leader/suppressed/holdposition1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 9: EmitSoundToAll("player/voice/radial/security/leader/suppressed/holdposition2.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 10: EmitSoundToAll("player/voice/radial/security/leader/suppressed/holdposition3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 11: EmitSoundToAll("player/voice/radial/security/leader/suppressed/holdposition4.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 12: EmitSoundToAll("player/voice/radial/security/leader/suppressed/moving3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 13: EmitSoundToAll("player/voice/radial/security/leader/suppressed/ontheway1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 14: EmitSoundToAll("player/voice/security/command/leader/located4.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 15: EmitSoundToAll("player/voice/security/command/leader/setwaypoint1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 16: EmitSoundToAll("player/voice/security/command/leader/setwaypoint2.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 17: EmitSoundToAll("player/voice/security/command/leader/setwaypoint3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 18: EmitSoundToAll("player/voice/security/command/leader/setwaypoint4.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
		}
	}
}

//Healthkit Start

public OnEntityDestroyed(entity)
{
	if (entity > MaxClients)
	{
		decl String:classname[255];
		GetEntityClassname(entity, classname, 255);
		if (StrEqual(classname, "healthkit"))
		{
			//StopSound(entity, SNDCHAN_STATIC, "Lua_sounds/healthkit_healing.wav");
		}
		if (!(StrContains(classname, "wcache_crate_01") > -1))
		{
			g_ammoResupplyAmt[entity] = 0; 
		}
	}
}

public OnEntityCreated(entity, const String:classname[])
{

	if (StrEqual(classname, "healthkit"))
	{
		new Handle:hDatapack;

		g_healthPack_Amount[entity] = g_medpack_health_amt;
		CreateDataTimer(Healthkit_Timer_Tickrate, Healthkit, hDatapack, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		WritePackCell(hDatapack, entity);
		WritePackFloat(hDatapack, GetGameTime()+Healthkit_Timer_Timeout);
		g_fLastHeight[entity] = -9999.0;
		g_iTimeCheckHeight[entity] = -9999;
		SDKHook(entity, SDKHook_VPhysicsUpdate, HealthkitGroundCheck);
		CreateTimer(0.1, HealthkitGroundCheckTimer, entity, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
	else if (StrEqual(classname, "grenade_m67") || StrEqual(classname, "grenade_f1") || StrEqual(classname, "grenade_m26a2"))
	{
		CreateTimer(0.5, GrenadeScreamCheckTimer, entity, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
	else if (StrEqual(classname, "grenade_molotov") || StrEqual(classname, "grenade_anm14"))
		CreateTimer(0.2, FireScreamCheckTimer, entity, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public Action:FireScreamCheckTimer(Handle:timer, any:entity)
{
	new Float:fGrenOrigin[3];
	new Float:fPlayerOrigin[3];
	new Float:fPlayerEyeOrigin[3];
	new owner;
	if (IsValidEntity(entity) && entity > 0 && HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
	{
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fGrenOrigin);
		owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	}
	else
		KillTimer(timer);
 
	for (new client = 1;client <= MaxClients;client++)
	{
		if (!IsValidClient(client)) continue;
		if (!IsValidClient(owner)) continue;

		if (!IsFakeClient(client) && IsPlayerAlive(client) && GetClientTeam(client) == 2 && GetClientTeam(owner) == 3)
		{
			GetClientEyePosition(client, fPlayerEyeOrigin);
			GetClientAbsOrigin(client,fPlayerOrigin);
			//new Handle:trace = TR_TraceRayFilterEx(fPlayerEyeOrigin, fGrenOrigin, MASK_SOLID_BRUSHONLY, RayType_EndPoint, Base_TraceFilter); 

			if (GetVectorDistance(fPlayerOrigin, fGrenOrigin) <= 300 && g_plyrFireScreamCoolDown[client] <= 0)// && TR_DidHit(trace) && fGrenOrigin[2] > 0)
			{
				//PrintToServer("SCREAM FIRE");
				PlayerFireScreamRand(client);
				new fRandomInt = GetRandomInt(20, 30);
				g_plyrFireScreamCoolDown[client] = fRandomInt;
				//CloseHandle(trace);  
			}
		}
	}

	if (!IsValidEntity(entity) || !(entity > 0))
		KillTimer(timer);
}

public Action:GrenadeScreamCheckTimer(Handle:timer, any:entity)
{
	new Float:fGrenOrigin[3];
	new Float:fPlayerOrigin[3];
	new Float:fPlayerEyeOrigin[3];
	new owner;
	if (IsValidEntity(entity) && entity > 0 && HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
	{
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fGrenOrigin);
		owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	}
	else
		KillTimer(timer);

	for (new client = 1;client <= MaxClients;client++)
	{
		if (!IsValidClient(client)) continue;
		if (!IsValidClient(owner)) continue;

		if (!IsFakeClient(client) && IsPlayerAlive(client) && GetClientTeam(client) == 2 && GetClientTeam(owner) == 3)
		{
			GetClientEyePosition(client, fPlayerEyeOrigin);
			GetClientAbsOrigin(client,fPlayerOrigin);			
			//new Handle:trace = TR_TraceRayFilterEx(fPlayerEyeOrigin, fGrenOrigin, MASK_VISIBLE, RayType_EndPoint, Base_TraceFilter); 

			if (GetVectorDistance(fPlayerOrigin, fGrenOrigin) <= 240 && g_plyrGrenScreamCoolDown[client] <= 0)// && TR_DidHit(trace) && fGrenOrigin[2] > 0)
			{
				PlayerGrenadeScreamRand(client);
				new fRandomInt = GetRandomInt(6, 12);
				g_plyrGrenScreamCoolDown[client] = fRandomInt;
				//CloseHandle(trace); 
			} 
		}
	}

	if (!IsValidEntity(entity) || !(entity > 0))
		KillTimer(timer);
}
public Action:HealthkitGroundCheck(entity, activator, caller, UseType:type, Float:value)
{
	new Float:fOrigin[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOrigin);
	new iRoundHeight = RoundFloat(fOrigin[2]);
	if (iRoundHeight != g_iTimeCheckHeight[entity])
	{
		g_iTimeCheckHeight[entity] = iRoundHeight;
		g_fTimeCheck[entity] = GetGameTime();
	}
}

public Action:HealthkitGroundCheckTimer(Handle:timer, any:entity)
{
	if (entity > MaxClients && IsValidEntity(entity))
	{
		new Float:fGameTime = GetGameTime();
		if (fGameTime-g_fTimeCheck[entity] >= 1.0)
		{
			new Float:fOrigin[3];
			GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOrigin);
			new iRoundHeight = RoundFloat(fOrigin[2]);
			if (iRoundHeight == g_iTimeCheckHeight[entity])
			{
				g_fTimeCheck[entity] = GetGameTime();
				SDKUnhook(entity, SDKHook_VPhysicsUpdate, HealthkitGroundCheck);
				SDKHook(entity, SDKHook_VPhysicsUpdate, OnEntityPhysicsUpdate);
				KillTimer(timer);
			}
		}
	}
	else KillTimer(timer);
}

public Action:OnEntityPhysicsUpdate(entity, activator, caller, UseType:type, Float:value)
{
	TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, Float:{0.0, 0.0, 0.0});
}

public Action:Healthkit(Handle:timer, Handle:hDatapack)
{
	ResetPack(hDatapack);
	new entity = ReadPackCell(hDatapack);
	new Float:fEndTime = ReadPackFloat(hDatapack);
	new Float:fGameTime = GetGameTime();
	
	// Add bounds check
	if (entity < 0 || entity >= MAX_ENTITIES_SAFE)
	{
		LogError("[RESPAWN] Entity index %d out of bounds in Healthkit", entity);
		return Plugin_Stop;
	}
	
	//PrintToServer("fGameTime %i",fGameTime);
	//PrintToServer("g_healthPack_Amount %i",g_healthPack_Amount[entity]);
	if (entity > 0 && IsValidEntity(entity) && fGameTime > fEndTime)
	{
		RemoveHealthkit(entity);
		KillTimer(timer);
		return Plugin_Stop;
	}
	if (g_healthPack_Amount[entity] > 0)
	{	
			//PrintToServer("DEBUG 1");
		if (entity > 0 && IsValidEntity(entity))
		{
			//PrintToServer("DEBUG 2");
			new Float:fOrigin[3];
			GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOrigin);
			if (g_fLastHeight[entity] == -9999.0)
			{
				g_fLastHeight[entity] = 0.0;
				//Play sound
				
				//PrintToServer("DEBUG 3");
			}
			fOrigin[2] += 1.0;
			TE_SetupBeamRingPoint(fOrigin, 1.0, Healthkit_Radius*1.95, g_iBeaconBeam, g_iBeaconHalo, 0, 30, 5.0, 3.0, 0.0, {0, 200, 0, 255}, 1, (FBEAM_FADEOUT));
			//void TE_SetupBeamRingPoint(const float center[3], float Start_Radius, float End_Radius, int ModelIndex, int HaloIndex, int StartFrame, int FrameRate, float Life, float Width, float Amplitude, const int Color[4], int Speed, int Flags)
			TE_SendToAll();
			fOrigin[2] -= 16.0;
			if (fOrigin[2] != g_fLastHeight[entity])
			{
				g_fLastHeight[entity] = fOrigin[2];
			}
			else
			{
				new Float:fAng[3];
				GetEntPropVector(entity, Prop_Send, "m_angRotation", fAng);
				if (fAng[1] > 89.0 || fAng[1] < -89.0)
					fAng[1] = 90.0;
				if (fAng[2] > 89.0 || fAng[2] < -89.0)
				{
					fAng[2] = 0.0;
					fOrigin[2] -= 6.0;
					TeleportEntity(entity, fOrigin, fAng, Float:{0.0, 0.0, 0.0});
					fOrigin[2] += 6.0;
					EmitSoundToAll("ui/sfx/cl_click.wav", entity, SNDCHAN_VOICE, _, _, 1.0);
				}
			}
			for (new client = 1;client <= MaxClients;client++)
			{
				if (IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == 2)
				{
					//non medic area heal self
					if (!(StrContains(g_client_last_classstring[client], "medic") > -1))
					{ 
						decl Float:fPlayerOrigin[3];
						GetClientEyePosition(client, fPlayerOrigin);
						if (GetVectorDistance(fPlayerOrigin, fOrigin) <= Healthkit_Radius)
						{
									//PrintToServer("DEBUG 5");
							//g_medpack_health_amt
							new Handle:hData = CreateDataPack();
							WritePackCell(hData, entity);
							WritePackCell(hData, client);
							//fOrigin[2] += 6.0;
							//new Handle:trace = TR_TraceRayFilterEx(fPlayerOrigin, fOrigin, MASK_SOLID, RayType_EndPoint, Filter_ClientSelf, hData);
							CloseHandle(hData);
							new isMedicNearby = Check_NearbyMedics(client);
							//if (!TR_DidHit(trace))
							if (isMedicNearby)
							{	
									//PrintToServer("DEBUG 4");
								new iHealth = GetClientHealth(client);
								//new iMaxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
								//new iHealth = GetEntProp(client, Prop_Data, "m_iHealth");
								if (iHealth < 100)
								{
									//PrintToServer("DEBUG 6");
									iHealth += g_iHeal_amount_paddles;
									g_healthPack_Amount[entity] -= g_iHeal_amount_paddles;
									if (iHealth >= 100)
									{
										//EmitSoundToAll("Lua_sounds/healthkit_complete.wav", client, SNDCHAN_STATIC, _, _, 1.0);
										iHealth = 100;
										PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
										PrintHintText(client, "A medic assisted in healing you (HP: %i)", iHealth);
									}
									else 
									{
										PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
										PrintHintText(client, "Medic area healing you (HP: %i)", iHealth);
										switch(GetRandomInt(1, 6))
										{
											case 1: EmitSoundToAll("weapons/universal/uni_crawl_l_01.wav", client, SNDCHAN_VOICE, _, _, 1.0);
											case 2: EmitSoundToAll("weapons/universal/uni_crawl_l_04.wav", client, SNDCHAN_VOICE, _, _, 1.0);
											case 3: EmitSoundToAll("weapons/universal/uni_crawl_l_02.wav", client, SNDCHAN_VOICE, _, _, 1.0);
											case 4: EmitSoundToAll("weapons/universal/uni_crawl_r_03.wav", client, SNDCHAN_VOICE, _, _, 1.0);
											case 5: EmitSoundToAll("weapons/universal/uni_crawl_r_05.wav", client, SNDCHAN_VOICE, _, _, 1.0);
											case 6: EmitSoundToAll("weapons/universal/uni_crawl_r_06.wav", client, SNDCHAN_VOICE, _, _, 1.0);
										}
									}

									SetEntityHealth(client, iHealth);
								}
							}
							else
							{
									//PrintToServer("DEBUG 7");
								//Get weapon
								decl String:sWeapon[32];
								new ActiveWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
								if (ActiveWeapon < 0)
									continue;

								GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
								new iHealth = GetClientHealth(client);
								if ((StrContains(sWeapon, "weapon_kabar") > -1)	|| (StrContains(sWeapon, "weapon_katana") > -1))
								{
									//PrintToServer("DEBUG 8");
									if (iHealth < g_nonMedicHealSelf_max)
									{
									//PrintToServer("DEBUG 9");
										iHealth += g_nonMedicHeal_amount;
										g_healthPack_Amount[entity] -= g_nonMedicHeal_amount;
										if (iHealth >= g_nonMedicHealSelf_max)
										{
									//PrintToServer("DEBUG 10");
											//EmitSoundToAll("Lua_sounds/healthkit_complete.wav", client, SNDCHAN_STATIC, _, _, 1.0);
											iHealth = g_nonMedicHealSelf_max;
											PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
											PrintHintText(client, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_nonMedicHealSelf_max);
										}
										else 
										{
											PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
											PrintHintText(client, "Healing Self (HP: %i) | MAX: %i", iHealth, g_nonMedicHealSelf_max);
										}

										SetEntityHealth(client, iHealth);
									}
									else 
									{
										PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
										PrintHintText(client, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_nonMedicHealSelf_max);
									}

								}
								else if (iHealth < g_nonMedicHealSelf_max && !(StrContains(sWeapon, "weapon_kabar") > -1) || (StrContains(sWeapon, "weapon_katana") > -1))
								{
										PrintHintText(client, "No medics nearby! Pull knife out to heal! (HP: %i)", iHealth);
								}
							}
							
						}
					} //Medic assist area heal and self heal
					else if ((StrContains(g_client_last_classstring[client], "medic") > -1))
					{
						decl Float:fPlayerOrigin[3];
						GetClientEyePosition(client, fPlayerOrigin);
						if (GetVectorDistance(fPlayerOrigin, fOrigin) <= Healthkit_Radius)
						{
							//g_medpack_health_amt
							new Handle:hData = CreateDataPack();
							WritePackCell(hData, entity);
							WritePackCell(hData, client);
							fOrigin[2] += 32.0;
							//new Handle:trace = TR_TraceRayFilterEx(fPlayerOrigin, fOrigin, MASK_SOLID, RayType_EndPoint, Filter_ClientSelf, hData);
							CloseHandle(hData);

							new ActiveWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
							if (ActiveWeapon < 0)
								continue;

							// Get weapon class name
							decl String:sWeapon[32];
							GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
							if (((StrContains(sWeapon, "weapon_defib") > -1) || (StrContains(sWeapon, "weapon_knife") > -1) || (StrContains(sWeapon, "weapon_kabar") > -1) || (StrContains(sWeapon, "weapon_katana") > -1)))
							{
								//PrintToServer("DEBUG 3");
								new iHealth = GetClientHealth(client);
								//new iMaxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
								//new iHealth = GetEntProp(client, Prop_Data, "m_iHealth");
								if (Check_NearbyMedics(client))
								{
									if (iHealth < 100)
									{
										iHealth += g_iHeal_amount_paddles;
										g_healthPack_Amount[entity] -= g_iHeal_amount_paddles;
										if (iHealth >= 100)
										{
											//EmitSoundToAll("Lua_sounds/healthkit_complete.wav", client, SNDCHAN_STATIC, _, _, 1.0);
											iHealth = 100;
											PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
											PrintHintText(client, "A medic assisted in healing you (HP: %i)", iHealth);
										}
										else 
										{
											PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
											PrintHintText(client, "Self area healing (HP: %i)", iHealth);
										}

										SetEntityHealth(client, iHealth);
									}
								}
								else
								{
									if (iHealth < g_medicHealSelf_max)
									{
										iHealth += g_iHeal_amount_paddles;
										g_healthPack_Amount[entity] -= g_iHeal_amount_paddles;
										if (iHealth >= g_medicHealSelf_max)
										{
											//EmitSoundToAll("Lua_sounds/healthkit_complete.wav", client, SNDCHAN_STATIC, _, _, 1.0);
											iHealth = g_medicHealSelf_max;
											PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
											PrintHintText(client, "You area healed yourself (HP: %i) | MAX: %i", iHealth, g_medicHealSelf_max);
										}
										else 
										{
											PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
											PrintHintText(client, "Self area healing (HP: %i) | MAX %i", iHealth, g_medicHealSelf_max);
										}
									}
									else 
									{
										PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[entity]);
										PrintHintText(client, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_medicHealSelf_max);
									}
								}
							}
						}
					}
				}
			}
		}
		else
		{
			//PrintToServer("DEBUG 4");
			RemoveHealthkit(entity);
			KillTimer(timer);
		}
	}
	else if (g_healthPack_Amount[entity] <= 0)
	{
			//PrintToServer("DEBUG 5");
		RemoveHealthkit(entity);
		KillTimer(timer);
	}
	return Plugin_Continue;
}




public bool:Filter_ClientSelf(entity, contentsMask, any:data)
{
	ResetPack(data);
	new client = ReadPackCell(data);
	new player = ReadPackCell(data);
	if (entity != client && entity != player)
		return true;
	return false;
}

public RemoveHealthkit(entity)
{
	if (entity > MaxClients && IsValidEntity(entity))
	{
		//StopSound(entity, SNDCHAN_STATIC, "Lua_sounds/healthkit_healing.wav");
		//EmitSoundToAll("soundscape/emitters/oneshot/radio_explode.ogg", entity, SNDCHAN_STATIC, _, _, 1.0);
		
		//new dissolver = CreateEntityByName("env_entity_dissolver");
		//if (dissolver != -1)
		//{
			// DispatchKeyValue(dissolver, "dissolvetype", Healthkit_Remove_Type);
			// DispatchKeyValue(dissolver, "magnitude", "1");
			// DispatchKeyValue(dissolver, "target", "!activator");
			// AcceptEntityInput(dissolver, "Dissolve", entity);
			// AcceptEntityInput(dissolver, "Kill");

			AcceptEntityInput(entity, "Kill");
		//}
	}
}

public Check_NearbyMedics(client)
{
	for (new friendlyMedic = 1; friendlyMedic <= MaxClients; friendlyMedic++)
	{
		if (IsClientConnected(friendlyMedic) && IsClientInGame(friendlyMedic) && !IsFakeClient(friendlyMedic))
		{
			//PrintToServer("Medic 1");
			//new team = GetClientTeam(friendlyMedic);
			if (IsPlayerAlive(friendlyMedic) && (StrContains(g_client_last_classstring[friendlyMedic], "medic") > -1) && client != friendlyMedic)
			{
			//PrintToServer("Medic 2");
				//Get position of bot and prop
				new Float:plyrOrigin[3];
				new Float:medicOrigin[3];
				new Float:fDistance;
		
				GetClientAbsOrigin(client,plyrOrigin);
				GetClientAbsOrigin(friendlyMedic,medicOrigin);
				//GetEntPropVector(entity, Prop_Send, "m_vecOrigin", propOrigin);
				
				//determine distance from the two
				fDistance = GetVectorDistance(medicOrigin,plyrOrigin);
				
				new ActiveWeapon = GetEntPropEnt(friendlyMedic, Prop_Data, "m_hActiveWeapon");
				if (ActiveWeapon < 0)
					continue;

				// Get weapon class name
				decl String:sWeapon[32];
				GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));

			//PrintToServer("Medic 3");
				new bool:bCanHealPaddle = false;
				if ((StrContains(sWeapon, "weapon_defib") > -1) || (StrContains(sWeapon, "weapon_knife") > -1) || (StrContains(sWeapon, "weapon_kabar") > -1) || (StrContains(sWeapon, "weapon_healthkit") > -1) || (StrContains(sWeapon, "weapon_katana") > -1))
				{
			//PrintToServer("Medic 4");
					bCanHealPaddle = true;
				}
				if (fDistance <= Healthkit_Radius && bCanHealPaddle)
				{
			//PrintToServer("Medic 5");
					return true;
				}
			}
		}
	}
	return false;
}

//This is to award nearby medics that participate in reviving a player
public Check_NearbyMedicsRevive(client, iInjured)
{
	for (new friendlyMedic = 1; friendlyMedic <= MaxClients; friendlyMedic++)
	{
		if (IsClientConnected(friendlyMedic) && IsClientInGame(friendlyMedic) && !IsFakeClient(friendlyMedic))
		{
			//PrintToServer("Medic 1");
			//new team = GetClientTeam(friendlyMedic);
			if (IsPlayerAlive(friendlyMedic) && (StrContains(g_client_last_classstring[friendlyMedic], "medic") > -1) && client != friendlyMedic)
			{
				//PrintToServer("Medic 2");
				//Get position of bot and prop
				new Float:medicOrigin[3];
				new Float:fDistance;
		
				GetClientAbsOrigin(friendlyMedic,medicOrigin);
				//GetEntPropVector(entity, Prop_Send, "m_vecOrigin", propOrigin);
				
				//determine distance from the two
				fDistance = GetVectorDistance(medicOrigin,g_fRagdollPosition[iInjured]);
				
				new ActiveWeapon = GetEntPropEnt(friendlyMedic, Prop_Data, "m_hActiveWeapon");
				if (ActiveWeapon < 0)
					continue;

				// Get weapon class name
				decl String:sWeapon[32];
				GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));

				//PrintToServer("Medic 3");
				new bool:bCanHealPaddle = false;
				if ((StrContains(sWeapon, "weapon_defib") > -1) || (StrContains(sWeapon, "weapon_knife") > -1) || (StrContains(sWeapon, "weapon_kabar") > -1))
				{
					//PrintToServer("Medic 4");
					bCanHealPaddle = true;
				}

				new Float:fReviveDistance = 65.0;
				if (fDistance <= fReviveDistance && bCanHealPaddle)
				{

					decl String:woundType[64];
					if (g_playerWoundType[iInjured] == 0)
						woundType = "minor wound";
					else if (g_playerWoundType[iInjured] == 1)
						woundType = "moderate wound";
					else if (g_playerWoundType[iInjured] == 2)
						woundType = "critical wound";
					decl String:sBuf[255];
					// Chat to all
					//Format(sBuf, 255,"\x05%N\x01 revived(assisted) \x03%N from a %s", friendlyMedic, iInjured, woundType);
					//PrintToChatAll("%s", sBuf);
					
					// Add kill bonus to friendlyMedic
					// new iBonus = GetConVarInt(sm_revive_bonus);
					// new iScore = GetClientFrags(friendlyMedic) + iBonus;
					// SetEntProp(friendlyMedic, Prop_Data, "m_iFrags", iScore);
					
					/////////////////////////
					// Rank System
					g_iStatRevives[friendlyMedic]++;
					//
					/////////////////////////
					
					// Add score bonus to friendlyMedic (doesn't work)
					//iScore = GetPlayerScore(friendlyMedic);
					//PrintToServer("[SCORE] score: %d", iScore + 10);
					//SetPlayerScore(friendlyMedic, iScore + 10);

					//Accumulate a revive
					g_playerMedicRevivessAccumulated[friendlyMedic]++;
					new iReviveCap = GetConVarInt(sm_revive_cap_for_bonus);
					// Hint to friendlyMedic
					Format(sBuf, 255,"You revived(assisted) %N from a %s", iInjured, woundType);
					PrintHintText(friendlyMedic, "%s", sBuf);

					if (g_playerMedicRevivessAccumulated[friendlyMedic] >= iReviveCap)
					{
						g_playerMedicRevivessAccumulated[friendlyMedic] = 0;
						g_iSpawnTokens[friendlyMedic]++;
						decl String:sBuf2[255];
						// if (iBonus > 1)
						//	Format(sBuf2, 255,"Awarded %i kills and %i score for assisted revive", iBonus, 10);
						// else
						Format(sBuf2, 255,"Awarded %i life for reviving %d players", 1, iReviveCap);
						PrintToChat(friendlyMedic, "%s", sBuf2);
					}
				}
			}
		}
	}
}
/*
########################LUA HEALING INTEGRATION######################
#	This portion of the script adds in health packs from Lua		#
##############################END####################################
#####################################################################
*/




stock Effect_SetMarkerAtPos(client,Float:pos[3],Float:intervall,color[4]){

	
	/*static Float:lastMarkerTime[MAXPLAYERS+1] = {0.0,...};
	new Float:gameTime = GetGameTime();
	
	if(lastMarkerTime[client] > gameTime){
		
		//no update cuz its already up2date
		return;
	}
	
	lastMarkerTime[client] = gameTime+intervall;*/
	
	new Float:start[3];
	new Float:end[3];
	//decl Float:worldMaxs[3];
	
	//World_GetMaxs(worldMaxs);
	
	end[0] = start[0] = pos[0];
	end[1] = start[1] = pos[1];
	end[2] = start[2] = pos[2];
	end[2] += 10000.0;
	start[2] += 5.0;
	
	//intervall -= 0.1;
	
	for(new effect=1;effect<=2;effect++){
		
		
		//blue team
		switch(effect){
			
			case 1:{
				TE_SetupBeamPoints(start, end, g_iBeaconBeam, 0, 0, 20, intervall, 1.0, 50.0, 0, 0.0, color, 0);
			}
			case 2:{
				TE_SetupBeamRingPoint(start, 50.0, 50.1, g_iBeaconBeam, g_iBeaconHalo, 0, 10, intervall, 2.0, 0.0, color, 10, 0);
			}
		}
		
		TE_SendToClient(client);
	}
}

public Action Event_PlayerTeam(Handle event, const char[] name, bool dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));

	// Validate client index first
	if (client < 1 || client > MaxClients)
		return Plugin_Continue;
	if (!IsClientInGame(client))
		return Plugin_Continue;

	new m_iTeam = GetClientTeam(client);
	if (!IsFakeClient(client) && m_iTeam == TEAM_SPEC)
	{
		//remove network ragdoll associated with player
		new playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
		if(playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
			RemoveRagdoll(client);
	}

	return Plugin_Continue;
}


//############# AI DIRECTOR In-Script Functions START #######################


public AI_Director_ResetReinforceTimers() 
{
		//Set Reinforce Time
		g_iReinforceTime_AD_Temp = (g_AIDir_ReinforceTimer_Orig);
		g_iReinforceTimeSubsequent_AD_Temp = (g_AIDir_ReinforceTimer_SubOrig);
}

public AI_Director_SetDifficulty()
{
	AI_Director_ResetReinforceTimers();

	//AI Director Local Scaling Vars
	int AID_ReinfAdj_med = 20, AID_ReinfAdj_high = 30, AID_ReinfAdj_pScale = 0;
	float AID_SpecDelayAdj_low = 10.0, AID_SpecDelayAdj_med = 20.0, AID_SpecDelayAdj_high = 30.0, AID_SpecDelayAdj_pScale_Pro = 0.0, AID_SpecDelayAdj_pScale_Con = 0.0;
	// int AID_AmbChance_pScale = 0;
	int AID_SetDiffChance_pScale = 0;

	//Scale based on team count
	new tTeamSecCount = GetTeamSecCount();
	if (tTeamSecCount <= 6)
	{
		AID_ReinfAdj_pScale = 8;
		AID_SpecDelayAdj_pScale_Pro = 30.0;
		AID_SpecDelayAdj_pScale_Con = 10.0;
	}
	else if (tTeamSecCount >= 7 && tTeamSecCount <= 12)
	{
		AID_ReinfAdj_pScale = 4;
		AID_SpecDelayAdj_pScale_Pro = 20.0;
		AID_SpecDelayAdj_pScale_Con = 20.0;
		// AID_AmbChance_pScale = 0;
		AID_SetDiffChance_pScale = 5;
	}
	else if (tTeamSecCount >= 13)
	{
		AID_ReinfAdj_pScale = 8;
		AID_SpecDelayAdj_pScale_Pro = 10.0;
		AID_SpecDelayAdj_pScale_Con = 30.0;
		// AID_AmbChance_pScale = 0;
		AID_SetDiffChance_pScale = 10;
	}

	// Get the number of control points
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
	// Get active push point
	new acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");

	new tAmbScaleMult = 0;
	if (ncp <= 5)
	{
		tAmbScaleMult = 0;
		AID_SetDiffChance_pScale += 5;
	}
	//Add More to Ambush chance based on what point we are at. 
	// AID_AmbChance_pScale += (acp * tAmbScaleMult);
	AID_SetDiffChance_pScale += (acp * tAmbScaleMult);

	new Float:cvarSpecDelay = GetConVarFloat(sm_respawn_delay_team_ins_special);
	new fRandomInt = GetRandomInt(0, 100);


	//Set Difficulty Based On g_AIDir_TeamStatus and adjust per player scale g_SernixMaxPlayerCount
	if (fRandomInt <= (g_AIDir_DiffChanceBase + AID_SetDiffChance_pScale))
	{
		AI_Director_ResetReinforceTimers();
		//Set Reinforce Time
		g_iReinforceTime_AD_Temp = ((g_AIDir_ReinforceTimer_Orig - AID_ReinfAdj_high) - AID_ReinfAdj_pScale);
		g_iReinforceTimeSubsequent_AD_Temp = ((g_AIDir_ReinforceTimer_SubOrig - AID_ReinfAdj_high) - AID_ReinfAdj_pScale);

		//Mod specialized bot spawn interval
		g_fCvar_respawn_delay_team_ins_spec = ((cvarSpecDelay - AID_SpecDelayAdj_high) - AID_SpecDelayAdj_pScale_Con);
		if (g_fCvar_respawn_delay_team_ins_spec <= 0.0)
			g_fCvar_respawn_delay_team_ins_spec = 1.0;
	}
	// < 25% DOING BAD >> MAKE EASIER //Scale variables should be lower with higher player counts
	else if (g_AIDir_TeamStatus < (g_AIDir_TeamStatus_max / 4))
	{
		//Set Reinforce Time
		g_iReinforceTime_AD_Temp = ((g_AIDir_ReinforceTimer_Orig + AID_ReinfAdj_high) + AID_ReinfAdj_pScale);
		g_iReinforceTimeSubsequent_AD_Temp = ((g_AIDir_ReinforceTimer_SubOrig + AID_ReinfAdj_high) + AID_ReinfAdj_pScale);

		//Mod specialized bot spawn interval
		g_fCvar_respawn_delay_team_ins_spec = ((cvarSpecDelay + AID_SpecDelayAdj_high) + AID_SpecDelayAdj_pScale_Pro);
	}
	// >= 25% and < 50% NORMAL >> No Adjustments
	else if (g_AIDir_TeamStatus >= (g_AIDir_TeamStatus_max / 4) && g_AIDir_TeamStatus < (g_AIDir_TeamStatus_max / 2))
	{
		AI_Director_ResetReinforceTimers();

		// >= 25% and < 33% Ease slightly if <= half the team alive which is 9 right now.
		if (g_AIDir_TeamStatus >= (g_AIDir_TeamStatus_max / 4) && g_AIDir_TeamStatus < (g_AIDir_TeamStatus_max / 3) && GetTeamSecCount() <= 6)
		{
			//Set Reinforce Time
			g_iReinforceTime_AD_Temp = ((g_AIDir_ReinforceTimer_Orig + AID_ReinfAdj_med) + AID_ReinfAdj_pScale);
			g_iReinforceTimeSubsequent_AD_Temp = ((g_AIDir_ReinforceTimer_SubOrig + AID_ReinfAdj_med) + AID_ReinfAdj_pScale);

			//Mod specialized bot spawn interval
			g_fCvar_respawn_delay_team_ins_spec = ((cvarSpecDelay + AID_SpecDelayAdj_low) + AID_SpecDelayAdj_pScale_Pro);
		}
		else
		{
			//Set Reinforce Time
			g_iReinforceTime_AD_Temp = (g_AIDir_ReinforceTimer_Orig);
			g_iReinforceTimeSubsequent_AD_Temp = (g_AIDir_ReinforceTimer_SubOrig);

			//Mod specialized bot spawn interval
			g_fCvar_respawn_delay_team_ins_spec = cvarSpecDelay;
		}

	}
	// >= 50% and < 75% DOING GOOD
	else if (g_AIDir_TeamStatus >= (g_AIDir_TeamStatus_max / 2) && g_AIDir_TeamStatus < ((g_AIDir_TeamStatus_max / 4) * 3))
	{
		AI_Director_ResetReinforceTimers();
		//Set Reinforce Time
		g_iReinforceTime_AD_Temp = ((g_AIDir_ReinforceTimer_Orig - AID_ReinfAdj_med) - AID_ReinfAdj_pScale);
		g_iReinforceTimeSubsequent_AD_Temp = ((g_AIDir_ReinforceTimer_SubOrig - AID_ReinfAdj_med) - AID_ReinfAdj_pScale);

		//Mod specialized bot spawn interval
		g_fCvar_respawn_delay_team_ins_spec = ((cvarSpecDelay - AID_SpecDelayAdj_med) - AID_SpecDelayAdj_pScale_Con);
		if (g_fCvar_respawn_delay_team_ins_spec <= 0.0)
			g_fCvar_respawn_delay_team_ins_spec = 1.0;
	}
	// >= 75%  CAKE WALK
	else if (g_AIDir_TeamStatus >= ((g_AIDir_TeamStatus_max / 4) * 3))
	{
		AI_Director_ResetReinforceTimers();
		//Set Reinforce Time
		g_iReinforceTime_AD_Temp = ((g_AIDir_ReinforceTimer_Orig - AID_ReinfAdj_high) - AID_ReinfAdj_pScale);
		g_iReinforceTimeSubsequent_AD_Temp = ((g_AIDir_ReinforceTimer_SubOrig - AID_ReinfAdj_high) - AID_ReinfAdj_pScale);

		//Mod specialized bot spawn interval
		g_fCvar_respawn_delay_team_ins_spec = ((cvarSpecDelay - AID_SpecDelayAdj_high) - AID_SpecDelayAdj_pScale_Con);
		if (g_fCvar_respawn_delay_team_ins_spec <= 0.0)
			g_fCvar_respawn_delay_team_ins_spec = 1.0;
	}
	//return g_AIDir_TeamStatus; 
}

public Action fatal_cmd(int client, int args)
{
	if(IsPlayerAlive(client) || g_iHurtFatal[client] == 0) return Plugin_Continue;

	g_iHurtFatal[client] = 1;
	// Remove network ragdoll associated with player
	int playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
	if (playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
		RemoveRagdoll(client);
	PrintToChat(client, "Changed your death to fatal.");

	return Plugin_Continue; 
}
