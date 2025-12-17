/**
 *	[INS] Player Respawn Script - Player and BOT respawn script for sourcemod plugin.
 *
 *	This program is free software: you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation, either version 3 of the License, or
 *	(at your option) any later version.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <insurgencydy>
#include <smlib>
#include <discord>

// enable/disable medic code and ammo bag resupply
#define DOCTOR 1    // 1 = on | 0 = off

#if DOCTOR
    // LUA Healing define values
    #define Healthkit_Timer_Tickrate 0.5      // Basic Sound has 0.8 loop
    #define Healthkit_Timer_Timeout  360.0    // 6 minutes
    #define Healthkit_Radius         120.0
    #define Revive_Indicator_Radius  100.0
#endif

// This will be used for checking which team the player is on before repsawning them
#define SPECTATOR_TEAM 0
#define TEAM_SPEC      1
#define TEAM_1_SEC     2
#define TEAM_2_INS     3

// Navmesh Init
#define MAX_OBJECTIVES 13
#define MAX_ENTITIES   2048

ConVar revive_point_bonus;
ConVar full_heal_point_bonus;

ConVar is_ww2_server;

#if DOCTOR
int g_iReviveEnabled,
    g_iTimeCheckHeight[2048]  = { 0, ... },
    g_healthPack_Amount[2048] = { 0, ... },
    g_iEnableRevive           = 0,
    g_iReviveRemainingTime[MAXPLAYERS + 1],
    g_iReviveNonMedicRemainingTime[MAXPLAYERS + 1],
    g_iHurtFatal[MAXPLAYERS + 1],
    g_iClientRagdolls[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... },
    g_iNearestBody[MAXPLAYERS + 1],
    g_resupplyCounter[MAXPLAYERS + 1],
    // g_ammoResupplyAmt[MAX_ENTITIES+1],
    g_timeReviveCheck[MAXPLAYERS + 1] = { -1, ... },
    g_clientDamageDone[MAXPLAYERS + 1],
    g_playerWoundType[MAXPLAYERS + 1],
    g_playerWoundTime[MAXPLAYERS + 1],
    g_iReviveDistanceMetric,    // unit to use 1 = feet, 0 = meters // Player Distance Plugin //Credits to author = "Popoklopsi", url = "http://popoklopsi.de"
    g_iFatalLimbDmg,
    g_iFatalHeadDmg,
    g_iFatalBurnDmg,
    g_iFatalExplosiveDmg,
    g_iFatalChestStomach,
    g_iStatRevives[MAXPLAYERS + 1] = { 0, ... }, g_iStatHeals[MAXPLAYERS + 1] = { 0, ... },    // medic revive stats
    g_iHealAmountPaddles,
    g_iHealAmountMedpack,
    g_iNonMedicHealAmt,
    g_iNonMedicReviveHp,
    g_iMedicMinorReviveHp,
    g_iMedicModerateReviveHp,
    g_iMedicCriticalReviveHp,
    g_iMinorWoundDmg,
    g_iModerateWoundDmg,
    g_iMedicHealSelfMax,
    g_iNonMedicHealSelfMax,
    g_iNonMedicMaxHealOther,
    g_iMinorReviveTime,
    g_iModerateReviveTime,
    g_iCriticalReviveTime,
    g_iNonMedicReviveTime,
    g_iMedpackHealthAmount,
    g_iResupplyDelay,
    g_last_bot_respawn_time,
    g_iFreeLives[MAXPLAYERS + 1] = { 1, ... };

char  ga_sPlayerBGroups[MAXPLAYERS + 1][32];

float g_fLastHeight[2048] = { 0.0, ... },
      g_fTimeCheck[2048]  = { 0.0, ... },
      g_fDeadPosition[MAXPLAYERS + 1][3],
      g_fDeadAngle[MAXPLAYERS + 1][3],
      g_fRagdollPosition[MAXPLAYERS + 1][3],
      // g_fAmmoResupplyRange,
      //  Fatal dead
    g_fFatalChance,
      g_fFatalHeadChance,
      g_fSecCounterRespawnPosition[3] = { 0.0, ... };

// gameme forwards
GlobalForward MedicRevivedForward,
    MedicHealedForward,
    DeadCountForward;

bool g_beingRevivedByMedic[MAXPLAYERS + 1] = { false, ... },
                                        g_revivedByMedic[MAXPLAYERS + 1],
                                        ga_bPlayerSelectNewClass[MAXPLAYERS + 1] = { false, ... },
                                        g_is_respawning[MAXPLAYERS + 1]          = { false, ... };

ConVar g_cvReviveEnabled                                                         = null,
       // Fatal dead
    g_cvFatalChance                                                              = null,
       g_cvFatalHeadChance                                                       = null,
       g_cvFatalLimbDmg                                                          = null,
       g_cvFatalHeadDmg                                                          = null,
       g_cvFatalBurnDmg                                                          = null,
       g_cvFatalExplosiveDmg                                                     = null,
       g_cvFatalChestStomach                                                     = null,
       // Medic specific
    g_cvReviveDistanceMetric                                                     = null,
       g_cvHealAmountMedpack                                                     = null,
       g_cvHealAmountPaddles                                                     = null,
       g_cvNonMedicHealAmt                                                       = null,
       g_cvNonMedicReviveHp                                                      = null,
       g_cvMedicMinorReviveHp                                                    = null,
       g_cvMedicModerateReviveHp                                                 = null,
       g_cvMedicCriticalReviveHp                                                 = null,
       g_cvMinorWoundDmg                                                         = null,
       g_cvModerateWoundDmg                                                      = null,
       g_cvMedicHealSelfMax                                                      = null,
       g_cvNonMedicMaxHealOther                                                  = null,
       g_cvMinorReviveTime                                                       = null,
       g_cvModerateReviveTime                                                    = null,
       g_cvCriticalReviveTime                                                    = null,
       g_cvNonMedicReviveTime                                                    = null,
       g_cvMedpackHealthAmount                                                   = null,
       g_cvNonMedicHealSelfMax                                                   = null,
       g_cvAmmoResupplyRange                                                     = null,    // Range of ammo resupply
    g_cvResupplyDelay                                                            = null;    // Delay to resupply
#endif
int g_iBeaconBeam,
    g_iBeaconHalo,
    g_isMapInit,
    // g_radioGearID = 4,	//Intel radio
    g_iTotalAliveEnemies,
    g_iPlayerEquipGear,
    g_iNvgToggle,          // NVG
    g_iRoundStatus = 0,    // 0 is over, 1 is active
    g_playerPickSquad[MAXPLAYERS + 1],
    g_plyrGrenScreamCoolDown[MAXPLAYERS + 1],
    g_plyrFireScreamCoolDown[MAXPLAYERS + 1],
    g_TeamSecCount,
    g_iNCP,
    g_iACP,
    // g_iCqcMapEnabled,
    g_iMinCounterDurSec,
    g_iMaxCounterDurSec,
    g_iCounterattackType,
    g_iFinalCounterDurSec,
    g_iCounterattackVanilla,
    g_iFinalCounterattackType,
    g_iPushSpawnStatus = -1,
    g_iNextSpawnStatus = -1,
    // Template of bots AI Director uses
    g_iCheckStaticEnemy,
    g_iTimerCheckStaticEnemy,
    g_iCheckStaticEnemyCounter,
    g_iTimerCheckStaticEnemyCounter,
    g_iReinforceTime,
    g_iTimerReinforceTime,
    g_iReinforceTimeSubsequent,
    g_iReinforceMultiplier,
    g_iReinforceMltiplierBase,
    g_iRemaining_lives_team_ins,
    g_iRespawnLivesTeamIns,
    g_botsReady,
    m_hMyWeapons,
    m_flNextPrimaryAttack,
    m_flNextSecondaryAttack,
    StuckCheck[MAXPLAYERS + 1] = { 0, ... },
    g_iLivesTeamInsPlayerMultiplier;

// Handle for revive
Handle g_hForceRespawn = null,
       g_hGameConfig   = null;

char g_client_last_classstring[MAXPLAYERS + 1][64],
    g_client_org_nickname[MAXPLAYERS + 1][64];

#define letme_heal_sounds_count 10

char normal_ragdoll_player[128] = "models/characters/civilian_vip_security.mdl";
char normal_ragdoll_medic[128]  = "models/characters/security_medic.mdl";
char ww2_ragdoll_any[128]       = "models/characters/american/player_american_01.mdl";

char let_me_heal_you[][]        = {
    "lua_sounds/medic/letme/medic_letme_heal1.ogg",
    "lua_sounds/medic/letme/medic_letme_heal2.ogg",
    "lua_sounds/medic/letme/medic_letme_heal3.ogg",
    "lua_sounds/medic/letme/medic_letme_heal4.ogg",
    "lua_sounds/medic/letme/medic_letme_heal5.ogg",
    "lua_sounds/medic/letme/medic_letme_heal6.ogg",
    "lua_sounds/medic/letme/medic_letme_heal7.ogg",
    "lua_sounds/medic/letme/medic_letme_heal8.ogg",
    "lua_sounds/medic/letme/medic_letme_heal9.ogg",
    "lua_sounds/medic/letme/medic_letme_heal10.ogg"
};

bool g_preRoundInitial = false,
     g_bLaunchControl  = false,
     g_bCounterAttack  = false,
     isStuck[MAXPLAYERS + 1],
     g_playersReady         = false;

bool   g_should_ask_to_heal = true;
int    g_iBonusPoint[MAXPLAYERS + 1];

ConVar g_cvDelayTeamIns                 = null,
       g_cvDelayTeamInsSpecial          = null,
       g_cvLivesTeamInsPlayerMultiplier = null,
       g_cvCounterattackType            = null,
       g_cvCounterattackVanilla         = null,
       g_cvFinalCounterattackType       = null,
       g_cvCounterChance                = null,
       g_cvMinCounterDurSec             = null,
       g_cvMaxCounterDurSec             = null,
       g_cvFinalCounterDurSec           = null,
       g_cvReinforceTime                = null,
       g_cvReinforceTimeSubsequent      = null,
       g_cvReinforceMultiplier          = null,
       g_cvReinforceMltiplierBase       = null,
       g_cvCheckStaticEnemy             = null,
       g_cvCheckStaticEnemyCounter      = null,
       g_cvCqcMapEnabled                = null,
       g_cvSpawnAttackDelay             = null,    // Attack delay for spawning bots
    g_cvCounterattackDuration           = null,
       g_cvCounterattackDisable         = null,
       g_cvCounterattackAlways          = null,
       g_cvSpawnMaxRange                = null,
       g_cvSpawnPercentNext             = null,
       g_cvSpawnDistFromCapped          = null,
       g_cvSpawnDistCounterFix          = null,
       g_cvStopSpawnDist                = null;

float Ground_Velocity[3]                = { 0.0, 0.0, -300.0 },
      RadiusSize                        = 200.0,    // Radius size to fix player position.
    Step                                = 20.0,     // Step between each position tested.
    g_fCounterChance,
      g_fDelayTeamIns,
      // g_fDelayTeamInsSpecial,
    g_fSecStartSpawn[3],
      g_fSpawnAttackDelay,
      g_fSpawnMaxRange,
      g_fSpawnPercentNext,
      g_fSpawnDistFromCapped,
      g_fSpawnDistCounterFix,
      g_fStopSpawnDist,
      g_enemyTimerAwayPos[MAXPLAYERS + 1][3],    // Kill Stray Enemy Bots Globals
    g_fCounterattackDuration;

ArrayList ga_hMapSpawns,
    ga_hBotSpawns,
    ga_hNextBotSpawns,
    ga_hFinalBotSpawns;

public Plugin myinfo =
{
    name        = "[GG2 BM2_RESPAWN] Player Respawn",
    author      = "Jared Ballou (Contributor: Daimyo, naong, and community members)",
    description = "Respawn dead players via admincommand or by queues",
    version     = "2.7.2",
    url         = "http://jballou.com"
};

// Start plugin
public void OnPluginStart()
{
    // Database.Connect(T_Connect, "insurgency_stats");
    // all spawns
    ga_hMapSpawns      = CreateArray();
    // found spawns for bots
    ga_hBotSpawns      = CreateArray(3);
    ga_hNextBotSpawns  = CreateArray(3);
    ga_hFinalBotSpawns = CreateArray(3);

    // medic heal/revive amounts
    RegAdminCmd("medic_stats", get_current_medic_stats, ADMFLAG_BAN, "Show stats for the current medics (medic class)");

    // Total bot count
    RegAdminCmd("totalb", Check_Total_Enemies, ADMFLAG_BAN, "Show the total alive enemies");
    // Find player gear offset
    g_iPlayerEquipGear = FindSendPropInfo("CINSPlayer", "m_EquippedGear");
    if (g_iPlayerEquipGear == -1)
    {
        SetFailState("Offset \"m_EquippedGear\" not found!");
    }
    g_iNvgToggle = FindSendPropInfo("CINSGearNVG", "m_bEnabled");
    if (g_iNvgToggle == -1)
    {
        SetFailState("Offset \"CINSGearNVG : m_bEnabled\" not found!");
    }

#if DOCTOR
    RegConsoleCmd("fatal", fatal_cmd, "Set your death to fatal");

    // TUG medic_tracker
    MedicRevivedForward = new GlobalForward("Medic_Revived", ET_Event, Param_Cell, Param_Cell);
    MedicHealedForward  = new GlobalForward("Medic_Healed", ET_Event, Param_Cell, Param_Cell);
    DeadCountForward    = new GlobalForward("Dead_Count", ET_Event, Param_Cell, Param_Cell);

    is_ww2_server       = CreateConVar("sm_is_ww2_server", "0", "Is this a WW2 Server (needs diff models)?");

    g_cvReviveEnabled   = CreateConVar("sm_revive_enabled", "1", "Reviving enabled from medics?  This creates revivable ragdoll after death; 0 - disabled, 1 - enabled");
    g_iReviveEnabled    = g_cvReviveEnabled.IntValue;
    g_cvReviveEnabled.AddChangeHook(OnConVarChanged);

    // Fatally death
    g_cvFatalChance = CreateConVar("sm_respawn_fatal_chance", "0.20", "Chance for a kill to be fatal, 0.6 default = 60% chance to be fatal (To disable set 0.0)");
    g_fFatalChance  = g_cvFatalChance.FloatValue;
    g_cvFatalChance.AddChangeHook(OnConVarChanged);

    g_cvFatalHeadChance = CreateConVar("sm_respawn_fatal_head_chance", "0.75", "Chance for a headshot kill to be fatal, 0.6 default = 60% chance to be fatal");
    g_fFatalHeadChance  = g_cvFatalHeadChance.FloatValue;
    g_cvFatalHeadChance.AddChangeHook(OnConVarChanged);

    g_cvFatalLimbDmg = CreateConVar("sm_respawn_fatal_limb_dmg", "180", "Amount of damage to fatally kill player in limb");
    g_iFatalLimbDmg  = g_cvFatalLimbDmg.IntValue;
    g_cvFatalLimbDmg.AddChangeHook(OnConVarChanged);

    g_cvFatalHeadDmg = CreateConVar("sm_respawn_fatal_head_dmg", "200", "Amount of damage to fatally kill player in head");
    g_iFatalHeadDmg  = g_cvFatalHeadDmg.IntValue;
    g_cvFatalHeadDmg.AddChangeHook(OnConVarChanged);

    g_cvFatalBurnDmg = CreateConVar("sm_respawn_fatal_burn_dmg", "80", "Amount of damage to fatally kill player in burn");
    g_iFatalBurnDmg  = g_cvFatalBurnDmg.IntValue;
    g_cvFatalBurnDmg.AddChangeHook(OnConVarChanged);

    g_cvFatalExplosiveDmg = CreateConVar("sm_respawn_fatal_explosive_dmg", "220", "Amount of damage to fatally kill player in explosive");
    g_iFatalExplosiveDmg  = g_cvFatalExplosiveDmg.IntValue;
    g_cvFatalExplosiveDmg.AddChangeHook(OnConVarChanged);

    g_cvFatalChestStomach = CreateConVar("sm_respawn_fatal_chest_stomach", "170", "Amount of damage to fatally kill player in chest/stomach");
    g_iFatalChestStomach  = g_cvFatalChestStomach.IntValue;
    g_cvFatalChestStomach.AddChangeHook(OnConVarChanged);

    // Medic Revive
    g_cvReviveDistanceMetric = CreateConVar("sm_revive_distance_metric", "0", "Distance metric (0: meters / 1: feet)");
    g_iReviveDistanceMetric  = g_cvReviveDistanceMetric.IntValue;
    g_cvReviveDistanceMetric.AddChangeHook(OnConVarChanged);

    g_cvHealAmountMedpack = CreateConVar("sm_heal_amount_medpack", "8", "Heal amount per 0.5 seconds when using medpack");
    g_iHealAmountMedpack  = g_cvHealAmountMedpack.IntValue;
    g_cvHealAmountMedpack.AddChangeHook(OnConVarChanged);

    g_cvHealAmountPaddles = CreateConVar("sm_heal_amount_paddles", "4", "Heal amount per 0.5 seconds when using paddles");
    g_iHealAmountPaddles  = g_cvHealAmountPaddles.IntValue;
    g_cvHealAmountPaddles.AddChangeHook(OnConVarChanged);

    g_cvNonMedicHealAmt = CreateConVar("sm_non_medic_heal_amt", "3", "Heal amount per 0.5 seconds when non-medic");
    g_iNonMedicHealAmt  = g_cvNonMedicHealAmt.IntValue;
    g_cvNonMedicHealAmt.AddChangeHook(OnConVarChanged);

    g_cvNonMedicReviveHp = CreateConVar("sm_non_medic_revive_hp", "20", "Health given to target revive when non-medic reviving");
    g_iNonMedicReviveHp  = g_cvNonMedicReviveHp.IntValue;
    g_cvNonMedicReviveHp.AddChangeHook(OnConVarChanged);

    g_cvMedicMinorReviveHp = CreateConVar("sm_medic_minor_revive_hp", "70", "Health given to target revive when medic reviving minor wound");
    g_iMedicMinorReviveHp  = g_cvMedicMinorReviveHp.IntValue;
    g_cvMedicMinorReviveHp.AddChangeHook(OnConVarChanged);

    g_cvMedicModerateReviveHp = CreateConVar("sm_medic_moderate_revive_hp", "50", "Health given to target revive when medic reviving moderate wound");
    g_iMedicModerateReviveHp  = g_cvMedicModerateReviveHp.IntValue;
    g_cvMedicModerateReviveHp.AddChangeHook(OnConVarChanged);

    g_cvMedicCriticalReviveHp = CreateConVar("sm_medic_critical_revive_hp", "35", "Health given to target revive when medic reviving critical wound");
    g_iMedicCriticalReviveHp  = g_cvMedicCriticalReviveHp.IntValue;
    g_cvMedicCriticalReviveHp.AddChangeHook(OnConVarChanged);

    g_cvMinorWoundDmg = CreateConVar("sm_minor_wound_dmg", "150", "Any amount of damage <= to this is considered a minor wound when killed");
    g_iMinorWoundDmg  = g_cvMinorWoundDmg.IntValue;
    g_cvMinorWoundDmg.AddChangeHook(OnConVarChanged);

    g_cvModerateWoundDmg = CreateConVar("sm_moderate_wound_dmg", "250", "Any amount of damage <= to this is considered a minor wound when killed.	Anything greater is CRITICAL");
    g_iModerateWoundDmg  = g_cvModerateWoundDmg.IntValue;
    g_cvModerateWoundDmg.AddChangeHook(OnConVarChanged);

    g_cvMedicHealSelfMax = CreateConVar("sm_medic_heal_self_max", "80", "Max medic can heal self to with med pack");
    g_iMedicHealSelfMax  = g_cvMedicHealSelfMax.IntValue;
    g_cvMedicHealSelfMax.AddChangeHook(OnConVarChanged);

    g_cvNonMedicHealSelfMax = CreateConVar("sm_non_medic_heal_self_max", "60", "Max non-medic can heal self to with med pack");
    g_iNonMedicHealSelfMax  = g_cvNonMedicHealSelfMax.IntValue;
    g_cvNonMedicHealSelfMax.AddChangeHook(OnConVarChanged);

    g_cvNonMedicMaxHealOther = CreateConVar("sm_non_medic_max_heal_other", "60", "Heal amount per 0.5 seconds when using paddles");
    g_iNonMedicMaxHealOther  = g_cvNonMedicMaxHealOther.IntValue;
    g_cvNonMedicMaxHealOther.AddChangeHook(OnConVarChanged);

    g_cvMinorReviveTime = CreateConVar("sm_minor_revive_time", "4", "Seconds it takes medic to revive minor wounded");
    g_iMinorReviveTime  = g_cvMinorReviveTime.IntValue;
    g_cvMinorReviveTime.AddChangeHook(OnConVarChanged);

    g_cvModerateReviveTime = CreateConVar("sm_moderate_revive_time", "6", "Seconds it takes medic to revive moderate wounded");
    g_iModerateReviveTime  = g_cvModerateReviveTime.IntValue;
    g_cvModerateReviveTime.AddChangeHook(OnConVarChanged);

    g_cvCriticalReviveTime = CreateConVar("sm_critical_revive_time", "8", "Seconds it takes medic to revive critical wounded");
    g_iCriticalReviveTime  = g_cvCriticalReviveTime.IntValue;
    g_cvCriticalReviveTime.AddChangeHook(OnConVarChanged);

    g_cvNonMedicReviveTime = CreateConVar("sm_non_medic_revive_time", "15", "Seconds it takes non-medic to revive minor wounded, requires medpack");
    g_iNonMedicReviveTime  = g_cvNonMedicReviveTime.IntValue;
    g_cvNonMedicReviveTime.AddChangeHook(OnConVarChanged);

    g_cvMedpackHealthAmount = CreateConVar("sm_medpack_health_amount", "500", "Amount of health a deployed healthpack has");
    g_iMedpackHealthAmount  = g_cvMedpackHealthAmount.IntValue;
    g_cvMedpackHealthAmount.AddChangeHook(OnConVarChanged);

    g_cvAmmoResupplyRange = CreateConVar("sm_ammo_resupply_range", "80", "Range to resupply near ammo cache");
    // g_fAmmoResupplyRange = g_cvAmmoResupplyRange.FloatValue;
    g_cvAmmoResupplyRange.AddChangeHook(OnConVarChanged);

    g_cvResupplyDelay = CreateConVar("sm_resupply_delay", "8", "Delay loop for resupply ammo");
    g_iResupplyDelay  = g_cvResupplyDelay.IntValue;
    g_cvResupplyDelay.AddChangeHook(OnConVarChanged);
#endif
    g_cvSpawnAttackDelay = CreateConVar("sm_botspawns_spawn_attack_delay", "0.0", "Delay in seconds for spawning bots to wait before firing.");
    g_fSpawnAttackDelay  = g_cvSpawnAttackDelay.FloatValue;
    g_cvSpawnAttackDelay.AddChangeHook(OnConVarChanged);

    g_cvDelayTeamIns = CreateConVar("sm_respawn_delay_team_ins", "0.0", "How many seconds to delay the respawn (bots)");
    g_fDelayTeamIns  = g_cvDelayTeamIns.FloatValue;
    g_cvDelayTeamIns.AddChangeHook(OnConVarChanged);

    g_cvDelayTeamInsSpecial = CreateConVar("sm_respawn_delay_team_ins_special", "600.0", "How many seconds to delay the respawn (special bots)");
    // g_fDelayTeamInsSpecial = g_cvDelayTeamInsSpecial.FloatValue;
    g_cvDelayTeamInsSpecial.AddChangeHook(OnConVarChanged);

    g_cvLivesTeamInsPlayerMultiplier = CreateConVar("sm_respawn_lives_team_ins_player_multiplier", "5", "Number of bots per player. If set to 0 then it uses 'sm_respawn_lives_team_ins' setting");
    g_iLivesTeamInsPlayerMultiplier  = g_cvLivesTeamInsPlayerMultiplier.IntValue;
    g_cvLivesTeamInsPlayerMultiplier.AddChangeHook(OnConVarChanged);

    // Counter attack
    g_cvCounterChance = CreateConVar("sm_respawn_counter_chance", "0.5", "Percent chance that a counter attack will happen def: 50%");
    g_fCounterChance  = g_cvCounterChance.FloatValue;
    g_cvCounterChance.AddChangeHook(OnConVarChanged);

    g_cvCounterattackType = CreateConVar("sm_respawn_counterattack_type", "1", "Respawn during counterattack? (0: no, 1: yes, 2: infinite)");
    g_iCounterattackType  = g_cvCounterattackType.IntValue;
    g_cvCounterattackType.AddChangeHook(OnConVarChanged);

    g_cvFinalCounterattackType = CreateConVar("sm_respawn_final_counterattack_type", "1", "Respawn during final counterattack? (0: no, 1: yes, 2: infinite)");
    g_iFinalCounterattackType  = g_cvFinalCounterattackType.IntValue;
    g_cvFinalCounterattackType.AddChangeHook(OnConVarChanged);

    g_cvMinCounterDurSec = CreateConVar("sm_respawn_min_counter_dur_sec", "120", "Minimum randomized counter attack duration");
    g_iMinCounterDurSec  = g_cvMinCounterDurSec.IntValue;
    g_cvMinCounterDurSec.AddChangeHook(OnConVarChanged);

    g_cvMaxCounterDurSec = CreateConVar("sm_respawn_max_counter_dur_sec", "140", "Maximum randomized counter attack duration");
    g_iMaxCounterDurSec  = g_cvMaxCounterDurSec.IntValue;
    g_cvMaxCounterDurSec.AddChangeHook(OnConVarChanged);

    g_cvFinalCounterDurSec = CreateConVar("sm_respawn_final_counter_dur_sec", "180", "Final counter attack duration");
    g_iFinalCounterDurSec  = g_cvFinalCounterDurSec.IntValue;
    g_cvFinalCounterDurSec.AddChangeHook(OnConVarChanged);

    g_cvCounterattackVanilla = CreateConVar("sm_respawn_counterattack_vanilla", "0", "Use vanilla counter attack mechanics? (0: no, 1: yes)");
    g_iCounterattackVanilla  = g_cvCounterattackVanilla.IntValue;
    g_cvCounterattackVanilla.AddChangeHook(OnConVarChanged);

    // Reinforcements
    g_cvReinforceTime = CreateConVar("sm_respawn_reinforce_time", "360", "When enemy forces are low on lives, how much time til they get reinforcements?");
    g_iReinforceTime  = g_cvReinforceTime.IntValue;
    g_cvReinforceTime.AddChangeHook(OnConVarChanged);

    g_cvReinforceTimeSubsequent = CreateConVar("sm_respawn_reinforce_time_subsequent", "300", "When enemy forces are low on lives and already reinforced, how much time til they get reinforcements on subsequent reinforcement?");
    g_iReinforceTimeSubsequent  = g_cvReinforceTimeSubsequent.IntValue;
    g_cvReinforceTimeSubsequent.AddChangeHook(OnConVarChanged);

    g_cvReinforceMultiplier = CreateConVar("sm_respawn_reinforce_multiplier", "3", "Division multiplier to determine when to start reinforce timer for bots based on team pool lives left over");
    g_iReinforceMultiplier  = g_cvReinforceMultiplier.IntValue;
    g_cvReinforceMultiplier.AddChangeHook(OnConVarChanged);

    g_cvReinforceMltiplierBase = CreateConVar("sm_respawn_reinforce_multiplier_base", "18", "This is the base int number added to the division multiplier, so (10 * reinforce_mult + base_mult)");
    g_iReinforceMltiplierBase  = g_cvReinforceMltiplierBase.IntValue;
    g_cvReinforceMltiplierBase.AddChangeHook(OnConVarChanged);

    // Control static enemy
    g_cvCheckStaticEnemy = CreateConVar("sm_respawn_check_static_enemy", "25", "Seconds amount to check if an AI has moved probably stuck");
    g_iCheckStaticEnemy  = g_cvCheckStaticEnemy.IntValue;
    g_cvCheckStaticEnemy.AddChangeHook(OnConVarChanged);

    g_cvCheckStaticEnemyCounter = CreateConVar("sm_respawn_check_static_enemy_counter", "15", "Seconds amount to check if an AI has moved during counter");
    g_iCheckStaticEnemyCounter  = g_cvCheckStaticEnemyCounter.IntValue;
    g_cvCheckStaticEnemyCounter.AddChangeHook(OnConVarChanged);

    // range settings for bot spawn
    g_cvSpawnMaxRange = CreateConVar("sm_botspawn_objmax", "400.0", "Maximum distance for bot spawn from objective");
    g_fSpawnMaxRange  = g_cvSpawnMaxRange.FloatValue;
    g_cvSpawnMaxRange.AddChangeHook(OnConVarChanged);

    g_cvSpawnPercentNext = CreateConVar("sm_botspawn_next", "0.25", "Percent chance for bot spawn on next objective");
    g_fSpawnPercentNext  = g_cvSpawnPercentNext.FloatValue;
    g_cvSpawnPercentNext.AddChangeHook(OnConVarChanged);

    g_cvSpawnDistFromCapped = CreateConVar("sm_botspawn_capped", "500.0", "Bot spawn distance check from captured objective to avoid spawning too close to sec spawn (lower it for maps like launch_control)");
    g_fSpawnDistFromCapped  = g_cvSpawnDistFromCapped.FloatValue;
    g_cvSpawnDistFromCapped.AddChangeHook(OnConVarChanged);

    g_cvSpawnDistCounterFix = CreateConVar("sm_botspawn_counterfix", "400.0", "If bot spawns at this or less distance from CP during counter-attack then try to find a better spawn (e.g., bridgeatremagen final counter) [0.0 = off]");
    g_fSpawnDistCounterFix  = g_cvSpawnDistCounterFix.FloatValue;
    g_cvSpawnDistCounterFix.AddChangeHook(OnConVarChanged);

    g_cvStopSpawnDist = CreateConVar("sm_botspawn_secdist", "400.0", "Spawn bots on the next objective if security player at this distance from the current objective [0.0 = off]");
    g_fStopSpawnDist  = g_cvStopSpawnDist.FloatValue;
    g_cvStopSpawnDist.AddChangeHook(OnConVarChanged);

    g_cvCounterattackDuration = FindConVar("mp_checkpoint_counterattack_duration");
    g_fCounterattackDuration  = g_cvCounterattackDuration.FloatValue;
    g_cvCounterattackDuration.AddChangeHook(OnConVarChanged);

    g_cvCounterattackDisable = FindConVar("mp_checkpoint_counterattack_disable");
    g_cvCounterattackAlways  = FindConVar("mp_checkpoint_counterattack_always");

    // Specialized Counter
    g_cvCqcMapEnabled        = CreateConVar("sm_cqc_map_enabled", "0", "Is this a cqc map? 0|1 no|yes");
    // g_iCqcMapEnabled = g_cvCqcMapEnabled.IntValue;
    g_cvCqcMapEnabled.AddChangeHook(OnConVarChanged);

    // medic/healing bonus points
    revive_point_bonus    = CreateConVar("sm_revive_point_bonus", "75.0", "Points awarded to score for a revive");
    full_heal_point_bonus = CreateConVar("sm_full_heal_point_bonus", "50.0", "Points awarded to score for giving a player max health possible");

    if ((m_hMyWeapons = FindSendPropInfo("CBasePlayer", "m_hMyWeapons")) == -1)
    {
        SetFailState("Fatal Error: Unable to find property offset \"CBasePlayer::m_hMyWeapons\" !");
    }

    if ((m_flNextPrimaryAttack = FindSendPropInfo("CBaseCombatWeapon", "m_flNextPrimaryAttack")) == -1)
    {
        SetFailState("Fatal Error: Unable to find property offset \"CBaseCombatWeapon::m_flNextPrimaryAttack\" !");
    }

    if ((m_flNextSecondaryAttack = FindSendPropInfo("CBaseCombatWeapon", "m_flNextSecondaryAttack")) == -1)
    {
        SetFailState("Fatal Error: Unable to find property offset \"CBaseCombatWeapon::m_flNextSecondaryAttack\" !");
    }

    // Add admin respawn console command
    RegAdminCmd("sm_respawn", Command_Respawn, ADMFLAG_SLAY, "sm_respawn <#userid|name>");

    // Add reload config console command for admin
    RegAdminCmd("sm_respawn_reload", Command_Reload, ADMFLAG_SLAY, "sm_respawn_reload");

    RegAdminCmd("bsdebug", cmd_BotSpawnDebug, ADMFLAG_RCON, "show found bot spawns");

    HookEvent("player_spawn", Event_Spawn);
    HookEvent("player_spawn", Event_SpawnPost, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("player_pick_squad", Event_PlayerPickSquad_Post, EventHookMode_Post);
    HookEvent("object_destroyed", Event_ObjectDestroyed_Pre, EventHookMode_Pre);
    HookEvent("object_destroyed", Event_ObjectDestroyed);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured_Pre, EventHookMode_Pre);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured_Post, EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("player_connect", Event_PlayerConnect);
    HookEvent("game_end", Event_GameEnd, EventHookMode_PostNoCopy);
    CreateTimer(5.0, getDeadCounts, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
#if DOCTOR
    HookEvent("grenade_thrown", Event_GrenadeThrown);
    HookEvent("player_hurt", Event_PlayerHurt_Pre, EventHookMode_Pre);
    HookEvent("round_end", Event_RoundEnd_Pre, EventHookMode_Pre);
    HookEvent("player_team", Event_PlayerTeam);
#endif

    g_hGameConfig = LoadGameConfigFile("insurgency.games");

    if (g_hGameConfig == INVALID_HANDLE)
        SetFailState("Fatal Error: Missing File \"insurgency.games\"!");

    StartPrepSDKCall(SDKCall_Player);
    char game[40];
    GetGameFolderName(game, sizeof(game));
    if (StrEqual(game, "insurgency"))
    {
        // PrintToServer("[RESPAWN] ForceRespawn for Insurgency");
        PrepSDKCall_SetFromConf(g_hGameConfig, SDKConf_Signature, "ForceRespawn");
    }
    if (StrEqual(game, "doi"))
    {
        // PrintToServer("[RESPAWN] ForceRespawn for DoI");
        PrepSDKCall_SetFromConf(g_hGameConfig, SDKConf_Virtual, "ForceRespawn");
    }
    g_hForceRespawn = EndPrepSDKCall();
    if (g_hForceRespawn == INVALID_HANDLE)
    {
        SetFailState("Fatal Error: Unable to find signature for \"ForceRespawn\"!");
    }
    // Load localization file
    LoadTranslations("common.phrases");
    LoadTranslations("respawn.phrases.txt");
    LoadTranslations("nearest_player.phrases.txt");
    LoadTranslations("tug.phrases.txt");
    AutoExecConfig(true, "respawn");
}

void UpdateRespawnCvars()
{
    // Set base value of remaining lives for team insurgent
    if (g_iLivesTeamInsPlayerMultiplier > 0)
    {
        g_TeamSecCount         = GetTeamSecCount();
        g_iRespawnLivesTeamIns = g_TeamSecCount * g_iLivesTeamInsPlayerMultiplier;
    }
    else {
        g_iRespawnLivesTeamIns = 0;
    }
}

// On map starts, call initalizing function
public void OnMapStart()
{
    for (int i = 0; i <= 2; i++)
    {
        g_fSecStartSpawn[i] = 0.0;
    }
    g_iACP = 0;

    // final counter teleport some bots to first objective spawns
    char sMapName[64];
    GetCurrentMap(sMapName, sizeof(sMapName));
    if (StrEqual(sMapName, "launch_control_coop_ws") || StrEqual(sMapName, "iron_express"))
    {
        g_bLaunchControl = true;
    }
    else {
        g_bLaunchControl = false;
    }

    SDKHook(GetPlayerResourceEntity(), SDKHook_ThinkPost, SHook_PlayerResourceThinkPost);

    ClearArray(ga_hMapSpawns);
    // Wait until players ready to enable spawn checking
    g_playersReady = false;
    g_botsReady    = 0;
    g_iBeaconBeam  = PrecacheModel("sprites/laserbeam.vmt");
    g_iBeaconHalo  = PrecacheModel("sprites/halo01.vmt");
#if DOCTOR
    // test fix pile o ragdoll
    // PrecacheModel("models/characters/civilian_vip_security.mdl");
    // Destory, Flip sounds
    // PrecacheSound("soundscape/emitters/oneshot/radio_explode.ogg");

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
#endif
    // Grenade Call Out
    // TEAM_1_SEC
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
    // TEAM_2_INS
    PrecacheSound("player/voice/bot/subordinate/incominggrenade1.ogg");
    PrecacheSound("player/voice/bot/subordinate/incominggrenade2.ogg");
    PrecacheSound("player/voice/bot/subordinate/incominggrenade3.ogg");
    PrecacheSound("player/voice/bot/subordinate/incominggrenade4.ogg");
    PrecacheSound("player/voice/bot/subordinate/incominggrenade5.ogg");
    PrecacheSound("player/voice/bot/subordinate/incominggrenade19.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade6.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade7.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade9.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade10.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade11.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade12.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade13.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade17.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade18.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade19.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade20.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade21.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade22.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade23.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade25.ogg");
    PrecacheSound("player/voice/bot/leader/incominggrenade26.ogg");
    // Molotov/Incen Callout
    // TEAM_1_SEC
    PrecacheSound("player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated7.ogg");
    PrecacheSound("player/voice/responses/security/leader/damage/molotov_incendiary_detonated6.ogg");
    PrecacheSound("player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated6.ogg");
    PrecacheSound("player/voice/responses/security/leader/damage/molotov_incendiary_detonated5.ogg");
    PrecacheSound("player/voice/responses/security/leader/damage/molotov_incendiary_detonated4.ogg");
    // TEAM_2_INS
    PrecacheSound("player/voice/responses/insurgent/leader/damage/molotov_incendiary_detonated5.ogg");
    PrecacheSound("player/voice/responses/insurgent/leader/damage/molotov_incendiary_detonated7.ogg");
    PrecacheSound("player/voice/responses/insurgent/subordinate/damage/molotov_incendiary_detonated3.ogg");
#if DOCTOR
    // L4D2 defibrillator revive sound
    PrecacheSound("weapons/defibrillator/defibrillator_revive.wav");
    // Lua sounds
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

    PrecacheSound("tug/medic_letme_heal1.ogg");
    for (int i = 0; i < sizeof(let_me_heal_you); i++)
    {
        PrecacheSound(let_me_heal_you[i]);
    }

#endif
    // Wait for navmesh
    CreateTimer(2.0, Timer_MapStart);
    g_preRoundInitial = true;

    LogMessage("[BM2 RESPAWN] got wtf_ww2_server: %i", is_ww2_server.IntValue);
    if (is_ww2_server.IntValue == 1)
    {
        LogMessage("[BM2 RESPAWN] got WW2 setup.. caching ww2_ragdoll_any");
        PrecacheModel(ww2_ragdoll_any);
    }
    else {
        PrecacheModel(normal_ragdoll_medic);
        PrecacheModel(normal_ragdoll_player);
        LogMessage("[BM2 RESPAWN] got NON WW2 setup.. caching normal_ragdoll_medic and normal_ragdoll_player");
    }
}

public void Event_GameEnd(Event event, const char[] name, bool dontBroadcast)
{
#if DOCTOR
    g_iEnableRevive = 0;
#endif
    g_iRoundStatus = 0;
    g_botsReady    = 0;
}

public void SHook_PlayerResourceThinkPost(int iEnt)
{
    int offset = FindSendPropInfo("CINSPlayerResource", "m_iPlayerScore");

    int iTotalScore[MAXPLAYERS + 1];
    GetEntDataArray(iEnt, offset, iTotalScore, MaxClients + 1);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (g_iBonusPoint[i] > 0)
        {
            iTotalScore[i] += g_iBonusPoint[i];
        }
    }
    SetEntDataArray(iEnt, offset, iTotalScore, MaxClients + 1);
}

Action Timer_should_ask_to_heal(Handle timer)
{
    if (!g_should_ask_to_heal)
    {
        // LogMessage("[BM2 RESPAWN] Setting should_ask_to_heal back to true");
        g_should_ask_to_heal = true;
    }
    return Plugin_Continue;
}

Action Timer_MapStart(Handle timer)
{
    // Check is map initialized
    if (g_isMapInit)
    {
        return Plugin_Continue;
    }
    ServerCommand("exec betterbots.cfg");
    FindMapSpawnPoints();
    g_iNCP                = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");    // Get the number of control points

    g_isMapInit           = 1;
    // Bot Reinforce Times
    g_iTimerReinforceTime = g_iReinforceTime;

    // Update cvars
    UpdateRespawnCvars();

#if DOCTOR
    g_iEnableRevive = 0;
#endif
    // Reset respawn token
    ResetInsurgencyLives();
    // Enemy reinforcement announce timer
    CreateTimer(1.0, Timer_EnemyReinforce, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    // Enemy remaining announce timer
    CreateTimer(30.0, Timer_Enemies_Remaining, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    // Player status check timer
    CreateTimer(1.0, Timer_PlayerStatus, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
#if DOCTOR
    // Revive monitor
    CreateTimer(1.0, Timer_ReviveMonitor, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    // Heal monitor
    CreateTimer(0.5, Timer_MedicMonitor, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    // Display nearest body for medics
    CreateTimer(0.1, Timer_NearestBody, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    // Monitor ammo resupply
    // CreateTimer(1.0, Timer_AmmoResupply, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
#endif
    // Static enemy check timer
    CreateTimer(1.0, Timer_CheckEnemyAway, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, Timer_CheckIfCounter, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    g_iTimerCheckStaticEnemy        = g_iCheckStaticEnemy;
    g_iTimerCheckStaticEnemyCounter = g_iCheckStaticEnemyCounter;
    g_bCounterAttack                = false;
    return Plugin_Continue;
}

public void OnMapEnd()
{
    // Reset respawn token
    ResetInsurgencyLives();
    g_isMapInit    = 0;
    g_botsReady    = 0;
    g_iRoundStatus = 0;
#if DOCTOR
    g_iEnableRevive = 0;
#endif
}

// Console command for reload config
public Action Command_Reload(int client, int args)
{
    ServerCommand("exec sourcemod/respawn.cfg");
    // Reset respawn token
    ResetInsurgencyLives();
    ReplyToCommand(client, "[SM] Reloaded 'sourcemod/respawn.cfg' file.");
    return Plugin_Handled;
}

// Respawn function for console command
public Action Command_Respawn(int client, int args)
{
    // Check argument
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_player_respawn <#userid|name>");
        return Plugin_Handled;
    }
    // Retrive argument
    char arg[65];
    GetCmdArg(1, arg, sizeof(arg));
    char target_name[MAX_TARGET_LENGTH];
    int  target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
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
    // If we don't have dead players
    if (target_count <= COMMAND_TARGET_NONE)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    // Team filter dead players, re-order target_list array with new_target_count
    int target, team, new_target_count;
    for (int i = 0; i < target_count; i++)
    {
        target = target_list[i];
        team   = GetClientTeam(target);
        if (team >= 2)
        {
            target_list[new_target_count] = target;    // re-order
            new_target_count++;
        }
    }

    // No dead players from	 team 2 and 3
    if (new_target_count == COMMAND_TARGET_NONE)
    {
        ReplyToTargetError(client, new_target_count);
        return Plugin_Handled;
    }
    target_count = new_target_count;    // re-set new value.
    // If target exists
    if (tn_is_ml)
        ShowActivity2(client, "[SM] ", "%t", "Toggled respawn on target", target_name);
    else
        ShowActivity2(client, "[SM] ", "%t", "Toggled respawn on target", "_s", target_name);
    // Process respawn
    for (int i = 0; i < target_count; i++)
        RespawnPlayer(client, target_list[i]);
    return Plugin_Handled;
}

// Respawn player
void RespawnPlayer(int client, int target)
{
    int team = GetClientTeam(target);
    if (IsClientInGame(target) && !IsClientTimingOut(target) && g_client_last_classstring[target][0] && g_playerPickSquad[target] && !IsPlayerAlive(target) && team == TEAM_1_SEC)
    {
        // Write a log
        LogAction(client, target, "\"%L\" respawned \"%L\"", client, target);
        // Call forcerespawn fucntion
        SDKCall(g_hForceRespawn, target);
    }
}

#if DOCTOR
// ForceRespawnPlayer player
/*
void ForceRespawnPlayer(int client, int target) {
    int team = GetClientTeam(target);
    if (IsClientInGame(target) && !IsClientTimingOut(target) && g_client_last_classstring[target][0] && g_playerPickSquad[target] && team == TEAM_1_SEC) {
        // Write a log
        LogAction(client, target, "\"%L\" respawned \"%L\"", client, target);
        // Call forcerespawn fucntion
        SDKCall(g_hForceRespawn, target);
    }
}
*/
#endif

// Check and inform player status
Action Timer_PlayerStatus(Handle timer)
{
    // int starttime = GetTime();
    // int endtime = 0;
    if (!g_iRoundStatus) return Plugin_Continue;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }
        if (--g_plyrGrenScreamCoolDown[client] <= 0)
            g_plyrGrenScreamCoolDown[client] = 0;

        if (--g_plyrFireScreamCoolDown[client] <= 0)
            g_plyrFireScreamCoolDown[client] = 0;
#if DOCTOR
        if (!g_playerPickSquad[client]
            || IsPlayerAlive(client)
            || GetClientTeam(client) != TEAM_1_SEC
            || !g_iEnableRevive
            || !g_iRoundStatus
            || ga_bPlayerSelectNewClass[client])
        {
            continue;
        }

        if (g_iHurtFatal[client])
        {
            PrintCenterText(client, "%T", "player_fatal_death_center", client, g_clientDamageDone[client]);
        }
        else {
            if (g_playerWoundType[client] == 0)
            {
                // minorly wounded
                PrintCenterText(client, "%T", "minorly_wounded", client, g_clientDamageDone[client]);
            }
            else if (g_playerWoundType[client] == 1) {
                // moderately wounded
                PrintCenterText(client, "%T", "moderately_wounded", client, g_clientDamageDone[client]);
            }
            else if (g_playerWoundType[client] == 2) {
                // critically wounded
                PrintCenterText(client, "%T", "critically_wounded", client, g_clientDamageDone[client]);
            }
            else {
                // just wounded
                PrintCenterText(client, "%T", "just_wounded", client, g_clientDamageDone[client]);
            }
        }

#endif
    }
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock Timer_PlayerStatus (START: %i) (END: %i)", starttime, endtime);
    return Plugin_Continue;
}

// Announce enemies remaining
Action Timer_Enemies_Remaining(Handle timer)
{
    // Check round state
    // int starttime = GetTime();
    // int endtime = 0;
    if (!g_iRoundStatus) return Plugin_Continue;
    int aliveInsurgents  = countAliveInsurgents();
    g_iTotalAliveEnemies = aliveInsurgents + g_iRemaining_lives_team_ins;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)
            || IsFakeClient(client)
            || !IsPlayerAlive(client))
        {
            continue;
        }
        if (g_bCounterAttack && IsInfiniteCounterAttack())
        {
            // PrintHintText(client, "Total enemies alive: Infinite");
            PrintHintText(client, "%T", "total_enemies_alive_infinite", client);
        }
        else {
            // PrintHintText(client, "Total enemies alive: %d", g_iTotalAliveEnemies);
            PrintHintText(client, "%T", "total_enemies_alive", client, g_iTotalAliveEnemies);
        }
    }
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock Timer_Enemies_Remaining (START: %i) (END: %i)", starttime, endtime);
    return Plugin_Continue;
}

public Action get_current_medic_stats(int caller_client, int args)
{
    int current_revivables    = 0;
    int current_nonrevivables = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)
            || IsFakeClient(client))
        {
            continue;
        }

        if (!IsPlayerAlive(client))
        {
            if (g_playerWoundType[client] > -1)
            {
                current_revivables++;
            }
            else {
                current_nonrevivables++;
            }
        }
        if (StrContains(g_client_last_classstring[client], "medic") != -1)
        {
            char status[8];
            if (IsPlayerAlive(client))
            {
                status = "alive";
            }
            else {
                status = "dead";
            }
            int  revive_count = g_iStatRevives[client];
            int  heal_count   = g_iStatHeals[client];
            char message[256];
            Format(message, sizeof(message), "%N (%s) heals: %i // revives: %i", client, status, heal_count, revive_count);
            ReplyToCommand(caller_client, message);
        }
    }
    ReplyToCommand(caller_client, "current revivable: %i // current NONrevivable: %i (right now)", current_revivables, current_nonrevivables);
    return Plugin_Stop;
}

public Action Check_Total_Enemies(int client, int args)
{
    // Check round state
    if (!g_iRoundStatus)
    {
        ReplyToCommand(client, "Use it after round start");
        return Plugin_Handled;
    }
    int  aliveInsurgents = countAliveInsurgents();
    char textToPrint[64];
    if (g_bCounterAttack && IsInfiniteCounterAttack())
    {
        Format(textToPrint, sizeof(textToPrint), "Enemies alive: %d | Enemy reinforcements left: Infinite", aliveInsurgents);
    }
    else {
        Format(textToPrint, sizeof(textToPrint), "Enemies alive: %d | Enemy reinforcements left: %d", aliveInsurgents, g_iRemaining_lives_team_ins);
    }
    PrintHintText(client, "%s", textToPrint);
    return Plugin_Handled;
}

// This timer reinforces bot team if you do not capture point
Action Timer_EnemyReinforce(Handle timer)
{
    // int starttime = GetTime();
    // int endtime = 0;
    //  Check round state
    if (!g_iRoundStatus) return Plugin_Continue;
    // Check enemy remaining
    if (g_iRemaining_lives_team_ins <= (g_iRespawnLivesTeamIns / g_iReinforceMultiplier) + g_iReinforceMltiplierBase)
    {
        g_iTimerReinforceTime--;

        // char textToPrint[72];
        if (g_iTimerReinforceTime == 140 || g_iTimerReinforceTime == 70 || (g_iTimerReinforceTime <= 10 && g_iTimerReinforceTime >= 0))
        {
            // Format(textToPrint, sizeof(textToPrint), "[INTEL] Enemies reinforce in %d seconds | Capture the point soon!", g_iTimerReinforceTime);
            // PrintHintTextToAll(textToPrint);
            PrintHintTextToAll("%t", "enemies_reinforce_in", g_iTimerReinforceTime);
        }

        if (g_iTimerReinforceTime > 0)
        {
            // endtime = GetTime();
            // LogMessage("[BM2 RESPAWN] profile_clock Timer_EnemyReinforce (START: %i) (END: %i)", starttime, endtime);
            return Plugin_Continue;
        }

        // If enemy reinforcement is not over, add it
        // Only add more reinforcements if under certain amount so its not endless.
        if (g_iRemaining_lives_team_ins <= 0 || g_iRemaining_lives_team_ins < (g_iRespawnLivesTeamIns / g_iReinforceMultiplier) + g_iReinforceMltiplierBase)
        {
            if (g_iRemaining_lives_team_ins <= 0)
            {
                // Format(textToPrint, sizeof(textToPrint), "[INTEL] Enemy reinforcements have arrived!");
                // PrintHintTextToAll(textToPrint);
                PrintHintTextToAll("%t", "enemy_reinforcements_arrived");
            }

            g_iRemaining_lives_team_ins = g_iRemaining_lives_team_ins + (g_iRespawnLivesTeamIns / 4);

            g_iTimerReinforceTime       = g_iReinforceTimeSubsequent;
            // LogMessage("[BM2 RESPAWN] bots just reinforced");
            for (int client = 1; client <= MaxClients; client++)
            {
                if (client <= 0
                    || !IsClientInGame(client)
                    || !IsFakeClient(client)
                    || IsPlayerAlive(client)
                    || GetClientTeam(client) != TEAM_2_INS)
                {
                    continue;
                }
                g_iRemaining_lives_team_ins++;
                CreateBotRespawnTimer(client);
            }
        }
    }
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock Timer_EnemyReinforce (START: %i) (END: %i)", starttime, endtime);
    return Plugin_Continue;
}

Action Timer_CheckIfCounter(Handle timer)
{
    g_bCounterAttack = view_as<bool>(GameRules_GetProp("m_bCounterAttack"));
    return Plugin_Continue;
    /*
    if (Ins_InCounterAttack()) {
        g_bCounterAttack = true;
    } else {
        g_bCounterAttack = false;
    }
    */
}

// Check enemy is stuck
Action Timer_CheckEnemyAway(Handle timer)
{
    // Check round state
    if (!g_iRoundStatus) return Plugin_Continue;

    int iSecondsToCheck = 0;

    // remove one second and write new value to helper variable
    if (Ins_InCounterAttack())
    {
        g_bCounterAttack = true;
        iSecondsToCheck  = --g_iTimerCheckStaticEnemyCounter;
    }
    else {
        g_bCounterAttack = false;
        iSecondsToCheck  = --g_iTimerCheckStaticEnemy;
    }

    if (iSecondsToCheck <= 0)
    {
        float enemyPos[3],
            flDistance,
            flDistanceToCapturePoint;

        for (int enemyBot = 1; enemyBot <= MaxClients; enemyBot++)
        {
            if (!IsClientInGame(enemyBot)
                || !IsFakeClient(enemyBot)
                || !IsPlayerAlive(enemyBot)
                || GetClientTeam(enemyBot) != TEAM_2_INS)
            {
                continue;
            }

            flDistance               = 0.0;
            flDistanceToCapturePoint = 0.0;

            GetClientAbsOrigin(enemyBot, enemyPos);
            flDistance               = GetVectorDistance(enemyPos, g_enemyTimerAwayPos[enemyBot]);
            flDistanceToCapturePoint = GetDistanceToCapturePoint(enemyPos, g_iACP);

            // If enemy position is static, kill him
            if (flDistance <= 150 && flDistanceToCapturePoint > 1000)
            {
                LogMessage("[BM2 RESPAWN] %i position is static, killing them", enemyBot);
                RemoveWeapons(enemyBot);
                ForcePlayerSuicide(enemyBot);
                AddLifeForStaticKilling(enemyBot);
            }
            else {
                // Update current position
                g_enemyTimerAwayPos[enemyBot] = enemyPos;
            }
        }

        // Reset both time stuck variables
        g_iTimerCheckStaticEnemyCounter = g_iCheckStaticEnemyCounter;
        g_iTimerCheckStaticEnemy        = g_iCheckStaticEnemy;
    }
    return Plugin_Continue;
}

float GetDistanceToCapturePoint(float vOrigin[3], int acp)
{
    float fVecCP[3];
    Ins_ObjectiveResource_GetPropVector("m_vCPPositions", fVecCP, acp);
    return GetVectorDistance(vOrigin, fVecCP);
}

void AddLifeForStaticKilling(int client)
{
    if (GetClientTeam(client) != TEAM_2_INS || g_iRespawnLivesTeamIns <= 0)
    {
        return;
    }
    g_iRemaining_lives_team_ins++;
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
float[] GetInsSpawnGround(int spawnPoint, float vecSpawn[3])
{
    float fGround[3];
    vecSpawn[2] += 15.0;
    TR_TraceRayFilter(vecSpawn, view_as<float>({ 90.0, 0.0, 0.0 }), MASK_PLAYERSOLID, RayType_Infinite, TRDontHitSelf, spawnPoint);
    if (TR_DidHit())
    {
        TR_GetEndPosition(fGround);
        return fGround;
    }
    return vecSpawn;
}

void FindMapSpawnPoints()
{
    int point = -1;
    point     = FindEntityByClassname(MaxClients + 1, "ins_spawnpoint");
    while (point != -1)
    {
        PushArrayCell(ga_hMapSpawns, point);
        point = FindEntityByClassname(point, "ins_spawnpoint");
    }
}

void FindBotSpawnPoints()
{
    float        fVecSpawn[3];
    static float fCurrentCpLoop = 0.0,
                 fNextCpLoop    = 0.0;

    // int starttime = GetTime();
    // int endtime = 0;

    if (fCurrentCpLoop == 0.0 && fNextCpLoop == 0.0)
    {
        if (g_iACP + 1 == g_iNCP)
        {
            ClearArray(ga_hFinalBotSpawns);
            ga_hFinalBotSpawns = ga_hBotSpawns.Clone();
        }
        ClearArray(ga_hBotSpawns);
        // copy already found spawns from next objective array
        if (GetArraySize(ga_hNextBotSpawns) > 0)
        {
            ga_hBotSpawns      = ga_hNextBotSpawns.Clone();
            g_iPushSpawnStatus = 1;
            if (g_bLaunchControl && g_iACP + 1 == g_iNCP)
            {
                // endtime = GetTime();
                // LogMessage("[BM2 RESPAWN] profile_clock findbotspawnpoints (START: %i) (END: %i)", starttime, endtime);
                return;
            }
            ClearArray(ga_hNextBotSpawns);
        }
    }

    if (g_iACP + 1 == g_iNCP)
    {
        return;
    }

    int iArraySize       = GetArraySize(ga_hBotSpawns),
        iNextCpArraySize = GetArraySize(ga_hNextBotSpawns);

    for (int i = 0; i < GetArraySize(ga_hMapSpawns); i++)
    {
        int   iSpawn             = GetArrayCell(ga_hMapSpawns, i);
        float fCappedDistance    = 0.0,
              fSecStartPointDist = 0.0;
        GetEntPropVector(iSpawn, Prop_Send, "m_vecOrigin", fVecSpawn);

        if (g_iACP == 0)
        {
            // start spawn for security
            fSecStartPointDist = GetVectorDistance(fVecSpawn, g_fSecStartSpawn);
        }

        if (iArraySize < 1
            && GetDistanceToCapturePoint(fVecSpawn, g_iACP) <= (g_fSpawnMaxRange + fCurrentCpLoop))
        {
            // make sure bot spawns not too close to capped point
            if (g_iACP > 0)
            {
                fCappedDistance = GetDistanceToCapturePoint(fVecSpawn, (g_iACP - 1));
            }

            if ((g_iACP > 0 && fCappedDistance >= g_fSpawnDistFromCapped) || fSecStartPointDist >= 400.0)
            {
                fVecSpawn = GetInsSpawnGround(iSpawn, fVecSpawn);
                PushArrayArray(ga_hBotSpawns, fVecSpawn);
                g_iPushSpawnStatus = 1;
                fCurrentCpLoop     = 0.0;
            }
        }
        // find next objective spawns
        else if (g_iACP + 1 < g_iNCP
                 && iNextCpArraySize < 1
                 && (g_iACP > 0 || fSecStartPointDist >= 400.0)
                 && GetDistanceToCapturePoint(fVecSpawn, (g_bLaunchControl && (g_iACP + 2 == g_iNCP)) ? 0 : g_iACP + 1) <= (g_fSpawnMaxRange + fNextCpLoop)
                 && GetDistanceToCapturePoint(fVecSpawn, g_iACP) >= g_fSpawnDistFromCapped) {
            fVecSpawn = GetInsSpawnGround(iSpawn, fVecSpawn);
            PushArrayArray(ga_hNextBotSpawns, fVecSpawn);
            g_iNextSpawnStatus = 1;
            fNextCpLoop        = 0.0;
        }
    }

    // didn't find try again
    if (g_iPushSpawnStatus != 1 || g_iNextSpawnStatus != 1)
    {
        if (g_iPushSpawnStatus == -1)
        {
            // too far stop looking
            if (fCurrentCpLoop >= 350.0)
            {
                g_iPushSpawnStatus = -2;
                fCurrentCpLoop     = 0.0;
            }
            else {
                fCurrentCpLoop += 50.0;
            }
        }
        else {
            fCurrentCpLoop = 0.0;
        }

        if (g_iNextSpawnStatus == -1)
        {
            // too far stop looking
            if (fNextCpLoop >= 350.0)
            {
                g_iNextSpawnStatus = -2;
                fNextCpLoop        = 0.0;
            }
            else {
                fNextCpLoop += 50.0;
            }
        }
        else {
            fNextCpLoop = 0.0;
        }

        if (g_iPushSpawnStatus == -1 || g_iNextSpawnStatus == -1)
        {
            FindBotSpawnPoints();
        }
    }
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock findbotspawnpoints (START: %i) (END: %i)", starttime, endtime);
}

// Lets begin to find a valid spawnpoint after spawned
void TeleportClient(int client, bool force_spawn_next_cap = false)
{
    // int starttime = GetTime();
    // int endtime = 0;

    int         iTime = GetTime();
    static int  iDelay;
    static bool bSecNearObj;

    if (iDelay < iTime)
    {
        bSecNearObj = IsSecNearObj();
        iDelay      = iTime + 2;
    }

    float vecSpawn[3];

    if (force_spawn_next_cap)
    {
        int iArray = GetArraySize(ga_hNextBotSpawns) - 1;
        if (iArray < 0)
        {
            return;
        }
        GetArrayArray(ga_hNextBotSpawns, iArray > 0 ? GetRandomInt(0, iArray) : iArray, vecSpawn);
        TeleportEntity(client, vecSpawn, NULL_VECTOR, NULL_VECTOR);
        // endtime = GetTime();
        // LogMessage("[BM2 RESPAWN] profile_clock teleportclient %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
        return;
    }

    if (g_iNextSpawnStatus == 1
        && (bSecNearObj
            || ((StrContains(g_client_last_classstring[client], "bomber") > -1
                 || StrContains(g_client_last_classstring[client], "tank") > -1)
                && g_iTotalAliveEnemies < 10)
            || GetRandomFloat(0.0, 1.0) <= g_fSpawnPercentNext))
    {
        int iArray = GetArraySize(ga_hNextBotSpawns) - 1;
        if (iArray < 0)
        {
            // endtime = GetTime();
            // LogMessage("[BM2 RESPAWN] profile_clock teleportclient %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
            return;
        }
        GetArrayArray(ga_hNextBotSpawns, iArray > 0 ? GetRandomInt(0, iArray) : iArray, vecSpawn);
    }
    else if (g_iPushSpawnStatus == 1) {
        int iArray = GetArraySize(ga_hBotSpawns) - 1;
        if (iArray < 0)
        {
            // endtime = GetTime();
            // LogMessage("[BM2 RESPAWN] profile_clock teleportclient %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
            return;
        }
        GetArrayArray(ga_hBotSpawns, iArray > 0 ? GetRandomInt(0, iArray) : iArray, vecSpawn);
    }
    else {
        // endtime = GetTime();
        // LogMessage("[BM2 RESPAWN] profile_clock teleportclient %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
        return;
    }

    bool too_close = is_too_close(vecSpawn);
    if (too_close)
    {
        TeleportClient(client, force_spawn_next_cap = true);
        return;
    }

    TeleportEntity(client, vecSpawn, NULL_VECTOR, NULL_VECTOR);
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock teleportclient %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
    // SetNextAttack(client);
}

void FixTooCloseCounterSpawn(int client)
{
    float vecOrigin[3],
        vecSpawn[3];

    // int starttime = GetTime();
    // int endtime = 0;
    GetClientAbsOrigin(client, vecOrigin);

    if (GetDistanceToCapturePoint(vecOrigin, g_iACP - 1) > g_fSpawnDistCounterFix)
    {
        // endtime = GetTime();
        // LogMessage("[BM2 RESPAWN] profile_clock fixtooclosecounterspawn %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
        return;
    }

    if (g_iACP != g_iNCP)
    {
        int iArray = GetArraySize(ga_hNextBotSpawns) - 1;
        if (iArray < 0)
        {
            // endtime = GetTime();
            // LogMessage("[BM2 RESPAWN] profile_clock fixtooclosecounterspawn %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
            return;
        }
        GetArrayArray(ga_hNextBotSpawns, iArray > 0 ? GetRandomInt(0, iArray) : iArray, vecSpawn);
    }
    else {
        int iArray = GetArraySize(ga_hFinalBotSpawns) - 1;
        if (iArray < 0)
        {
            // endtime = GetTime();
            // LogMessage("[BM2 RESPAWN] profile_clock fixtooclosecounterspawn %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
            return;
        }
        GetArrayArray(ga_hFinalBotSpawns, iArray > 0 ? GetRandomInt(0, iArray) : iArray, vecSpawn);
    }
    TeleportEntity(client, vecSpawn, NULL_VECTOR, NULL_VECTOR);
    if (IsPlayerAlive(client))
    {
        StuckCheck[client] = 0;
        StartStuckDetection(client);
    }
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock fixtooclosecounterspawn %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
}

public Action Event_Spawn(Event event, const char[] name, bool dontBroadcast)
{
    // int starttime = GetTime();
    // int endtime = 0;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return Plugin_Continue;
    }
    if (!IsFakeClient(client))
    {
        if (!g_iRoundStatus)
        {
            if (g_fSecStartSpawn[0] == 0.0 && g_fSecStartSpawn[1] == 0.0 && g_fSecStartSpawn[2] == 0.0)
            {
                GetClientAbsOrigin(client, g_fSecStartSpawn);
            }
        }
#if DOCTOR
        RemoveRagdoll(client);
        g_iHurtFatal[client]             = 0;
        ga_bPlayerSelectNewClass[client] = false;
        g_beingRevivedByMedic[client]    = false;
        g_timeReviveCheck[client]        = -1;
        g_resupplyCounter[client]        = g_iResupplyDelay;
#endif
        // endtime = GetTime();
        // LogMessage("[BM2 RESPAWN] profile_clock event_spawn %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
        return Plugin_Continue;
    }

    if (g_playersReady && g_botsReady
        && GetClientTeam(client) == TEAM_2_INS)
    {
        if (!g_bCounterAttack)
        {
            TeleportClient(client);
            if (IsPlayerAlive(client))
            {
                StuckCheck[client] = 0;
                StartStuckDetection(client);
            }
        }
        // final counter for launch_control_coop_ws map
        else if (g_bLaunchControl && g_iACP == g_iNCP) {
            if (g_iPushSpawnStatus != 1 && GetArraySize(ga_hNextBotSpawns) > 0)
            {
                ga_hBotSpawns      = ga_hNextBotSpawns.Clone();
                g_iPushSpawnStatus = 1;
            }
            if (GetRandomInt(0, 1) == 1)
            {
                TeleportClient(client);
                if (IsPlayerAlive(client))
                {
                    StuckCheck[client] = 0;
                    StartStuckDetection(client);
                }
            }
        }
        else if (g_fSpawnDistCounterFix != 0.0) {
            // fix too close counter-attack spawns (like final counter on ins_bridgeatremagen_coop)
            FixTooCloseCounterSpawn(client);
        }
    }
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock event_spawn %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
    return Plugin_Continue;
}

public Action Event_SpawnPost(Event event, const char[] name, bool dontBroadcast)
{
    if (g_fSpawnAttackDelay == 0.0)
    {
        return Plugin_Continue;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients)
    {
        if (!IsFakeClient(client))
        {
            return Plugin_Continue;
        }
        SetNextAttack(client);
    }
    return Plugin_Continue;
}

// This delays bot from attacking once spawned
void SetNextAttack(int client)
{
    // int starttime = GetTime();
    // int endtime = 0;
    float flTime = GetGameTime();
    // Loop through entries in m_hMyWeapons.
    for (int offset = 0; offset < 128; offset += 4)
    {
        int weapon = GetEntDataEnt2(client, m_hMyWeapons + offset);
        if (weapon < 1)
        {
            continue;
        }
        SetEntDataFloat(weapon, m_flNextPrimaryAttack, flTime + g_fSpawnAttackDelay);
        SetEntDataFloat(weapon, m_flNextSecondaryAttack, flTime + g_fSpawnAttackDelay);
    }
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock SetNextAttack %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
}

public void OnClientPutInServer(int client)
{
    g_playerPickSquad[client] = 0;
    g_iBonusPoint[client]     = 0;
#if DOCTOR
    g_iHurtFatal[client] = 0;
    ResetMedicStats(client);
#endif
    char sNickname[64];
    Format(sNickname, sizeof(sNickname), "%N", client);
    g_client_org_nickname[client] = sNickname;
}

public Action Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients)
    {
        g_playerPickSquad[client] = 0;
        g_iFreeLives[client]      = 1;
#if DOCTOR
        g_iHurtFatal[client] = 0;
#endif
        UpdateRespawnCvars();
    }
    return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && client <= MaxClients)
    {
        g_playerPickSquad[client]         = 0;
        g_iFreeLives[client]              = 1;
        // Reset player status
        g_client_last_classstring[client] = "";    // reset his class model
#if DOCTOR
        RemoveRagdoll(client);
#endif
        UpdateRespawnCvars();
    }
    return Plugin_Continue;
}

// When round starts, intialize variables
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bCounterAttack = false;
    g_iACP           = 0;
    ClearArray(ga_hBotSpawns);
    ClearArray(ga_hNextBotSpawns);
    ClearArray(ga_hFinalBotSpawns);
    g_iPushSpawnStatus              = -1;
    g_iNextSpawnStatus              = -1;
    g_fSecCounterRespawnPosition[0] = 0.0;
    g_fSecCounterRespawnPosition[1] = 0.0;
    g_fSecCounterRespawnPosition[2] = 0.0;
    // need some delay so we can get starting spawn of a player first
    CreateTimer(0.1, Timer_RoundStartFindBotSpawns);

    // Respawn delay for team ins
    g_iTimerReinforceTime           = g_iReinforceTime;
    g_iTimerCheckStaticEnemy        = g_iCheckStaticEnemy;
    g_iTimerCheckStaticEnemyCounter = g_iCheckStaticEnemyCounter;

    // Reset respawn token
    ResetInsurgencyLives();
    // Warming up revive
#if DOCTOR
    g_iEnableRevive = 0;
#endif
    int iPreRoundFirst = GetConVarInt(FindConVar("mp_timer_preround_first"));
    int iPreRound      = GetConVarInt(FindConVar("mp_timer_preround"));
    if (g_preRoundInitial)
    {
        CreateTimer(float(iPreRoundFirst), PreReviveTimer);
        iPreRoundFirst = iPreRoundFirst + 5;
        CreateTimer(float(iPreRoundFirst), BotsReady_Timer);
        g_preRoundInitial = false;
    }
    else {
        CreateTimer(float(iPreRound), PreReviveTimer);
        iPreRoundFirst = iPreRound + 5;
        CreateTimer(float(iPreRound), BotsReady_Timer);
    }
    return Plugin_Continue;
}

// Round starts
Action PreReviveTimer(Handle timer)
{
    g_iRoundStatus = 1;
#if DOCTOR
    g_iEnableRevive = 1;
#endif
    return Plugin_Continue;
}
// Botspawn trigger
Action BotsReady_Timer(Handle timer)
{
    if (g_TeamSecCount > 0)
    {    // Must check it because a player can glitch it by joining the spectator team.
        g_botsReady = 1;
    }
    else {
        g_iRoundStatus = 0;
#if DOCTOR
        g_iEnableRevive = 0;
#endif
    }
    return Plugin_Continue;
}

#if DOCTOR
// When round ends, intialize variables
public Action Event_RoundEnd_Pre(Event event, const char[] name, bool dontBroadcast)
{
    char sBuf[255];
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)
            || IsFakeClient(client)
            || GetClientTeam(client) != TEAM_1_SEC)
        {
            continue;
        }

        if ((g_iStatRevives[client] > 0 || g_iStatHeals[client] > 0) && StrContains(g_client_last_classstring[client], "medic") > -1)
        {
            Format(sBuf, sizeof(sBuf), "[MEDIC STATS] for %N: HEALS: %d | REVIVES: %d", client, g_iStatHeals[client], g_iStatRevives[client]);
            PrintHintText(client, "%s", sBuf);
            Format(sBuf, sizeof(sBuf), "[MEDIC STATS] for %N: HEALS: \x070088cc%d\x01 | REVIVES: \x070088cc%d", client, g_iStatHeals[client], g_iStatRevives[client]);
            PrintToChatAll("\x01%s", sBuf);
        }
        ResetMedicStats(client);
        g_iFreeLives[client] = 1;
    }
    return Plugin_Continue;
}
#endif

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // Cooldown revive
#if DOCTOR
    g_iEnableRevive = 0;
#endif
    g_fSecCounterRespawnPosition[0] = 0.0;
    g_fSecCounterRespawnPosition[1] = 0.0;
    g_fSecCounterRespawnPosition[2] = 0.0;
    g_iRoundStatus                  = 0;
    g_botsReady                     = 0;
    // Reset respawn token
    ResetInsurgencyLives();
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "healthkit")) > MaxClients && IsValidEntity(ent))
    {
        AcceptEntityInput(ent, "Kill");
    }
    return Plugin_Continue;
}

// Check occouring counter attack when control point captured
public Action Event_ControlPointCaptured_Pre(Event event, const char[] name, bool dontBroadcast)
{
    g_iPushSpawnStatus              = -1;
    g_iNextSpawnStatus              = -1;

    g_iTimerCheckStaticEnemy        = g_iCheckStaticEnemy;
    g_iTimerCheckStaticEnemyCounter = g_iCheckStaticEnemyCounter;
    g_iACP                          = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex") + 1;    // Get active push point

    for (int i = 1; i <= MaxClients; i++)
    {
        g_is_respawning[i] = false;
    }

    // Set counter attack duration to server
    if (g_iACP == g_iNCP)
    {    // Final counter attack
        g_iRemaining_lives_team_ins = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && IsPlayerAlive(i) && IsFakeClient(i) && GetClientTeam(i) == TEAM_2_INS)
            {
                ForcePlayerSuicide(i);
            }
        }
        SetConVarInt(g_cvCounterattackDuration, g_iFinalCounterDurSec, true, false);
    }

    else {    // Normal counter attack
        SetConVarInt(g_cvCounterattackDuration, GetRandomInt(g_iMinCounterDurSec, g_iMaxCounterDurSec), true, false);
    }

    if (g_iCounterattackVanilla)
    {
        CreateTimer(1.0, Timer_FindBotSpawns, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Continue;    // Are we using vanilla counter attack?
    }

    float fRandom = GetRandomFloat(0.0, 1.0);    // Get ramdom value for occuring counter attack
    // Occurs counter attack
    if (fRandom < g_fCounterChance && g_iACP != g_iNCP)
    {
        SetConVarInt(g_cvCounterattackDisable, 0, true, false);
        SetConVarInt(g_cvCounterattackAlways, 1, true, false);
        // Create Counter End timer
        CreateTimer((g_fCounterattackDuration + 1.0), Timer_CounterAttackEnd);
        respawn_sec_on_counter();
        CreateTimer(1.0, Timer_FindBotSpawns, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    // If last capture point
    else if (g_iACP == g_iNCP) {
        SetConVarInt(g_cvCounterattackDisable, 0, true, false);
        SetConVarInt(g_cvCounterattackAlways, 1, true, false);
        // Create Counter End timer
        CreateTimer((g_fCounterattackDuration + 1.0), Timer_CounterAttackEnd);
        respawn_sec_on_counter();
        ClearArray(ga_hBotSpawns);
    }
    // Not occurs counter attack
    else {
        SetConVarInt(g_cvCounterattackDisable, 1, true, false);

        CreateTimer(0.5, Timer_FindBotSpawns);
    }
    return Plugin_Continue;
}

// When control point captured, reset variables
public Action Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    // Reset reinforcement time
    g_iTimerReinforceTime = g_iReinforceTime;
    // Reset respawn tokens
    ResetInsurgencyLives();
    return Plugin_Continue;
}

public Action Event_ControlPointCaptured_Post(Event event, const char[] name, bool dontBroadcast)
{
    UpdateRespawnCvars();
    char cappers[512];
    GetEventString(event, "cappers", cappers, sizeof(cappers));
    int cappersLength = strlen(cappers);
    for (int i = 0; i < cappersLength; i++)
    {
        int clientCapper = cappers[i];
        if (clientCapper > 0 && IsClientInGame(clientCapper) && IsClientConnected(clientCapper) && IsPlayerAlive(clientCapper) && !IsFakeClient(clientCapper))
        {
            float capperPos[3];
            GetClientAbsOrigin(clientCapper, capperPos);
            g_fSecCounterRespawnPosition = capperPos;
            break;
        }
    }
    return Plugin_Continue;
}

// When ammo cache destroyed, update respawn position and reset variables
public Action Event_ObjectDestroyed_Pre(Event event, const char[] name, bool dontBroadcast)
{
    g_iPushSpawnStatus = -1;
    g_iNextSpawnStatus = -1;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_is_respawning[i] = false;
    }

    g_iTimerCheckStaticEnemy        = g_iCheckStaticEnemy;
    g_iTimerCheckStaticEnemyCounter = g_iCheckStaticEnemyCounter;
    g_iACP                          = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex") + 1;    // Get active push point

    // Set counter attack duration to server
    if (g_iACP + 1 == g_iNCP)
    {    // Final counter attack
        SetConVarInt(FindConVar("mp_checkpoint_counterattack_duration_finale"), g_iFinalCounterDurSec, true, false);
    }
    // Normal counter attack
    else {
        SetConVarInt(g_cvCounterattackDuration, GetRandomInt(g_iMinCounterDurSec, g_iMaxCounterDurSec), true, false);
    }

    if (g_iCounterattackVanilla)
    {
        CreateTimer(1.0, Timer_FindBotSpawns, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Continue;    // Are we using vanilla counter attack?
    }

    float fRandom = GetRandomFloat(0.0, 1.0);    // Get ramdom value for occuring counter attack
    if (fRandom < g_fCounterChance && g_iACP != g_iNCP)
    {    // Occurs counter attack
        SetConVarInt(g_cvCounterattackDisable, 0, true, false);
        SetConVarInt(g_cvCounterattackAlways, 1, true, false);
        CreateTimer((g_fCounterattackDuration + 1.0), Timer_CounterAttackEnd);

        CreateTimer(1.0, Timer_FindBotSpawns, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        respawn_sec_on_counter();
    }
    else if (g_iACP == g_iNCP) {    // If last capture point
        SetConVarInt(g_cvCounterattackDisable, 0, true, false);
        SetConVarInt(g_cvCounterattackAlways, 1, true, false);
        CreateTimer((g_fCounterattackDuration + 1.0), Timer_CounterAttackEnd);    // Call counter-attack end timer
        respawn_sec_on_counter();
        ClearArray(ga_hBotSpawns);
    }
    else {    // Not occurs counter attack
        SetConVarInt(g_cvCounterattackDisable, 1, true, false);

        CreateTimer(0.5, Timer_FindBotSpawns);
    }
    return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
    g_iTimerReinforceTime = g_iReinforceTime;    // Reset reinforcement time
    ResetInsurgencyLives();                      // Reset respawn token
    int attacker = GetEventInt(event, "attacker");
    int assister = GetEventInt(event, "assister");
    if (attacker > 0 && IsClientInGame(attacker) && IsClientConnected(attacker) || assister > 0 && IsClientInGame(assister) && IsClientConnected(assister))
    {
        float attackerPos[3];
        GetClientAbsOrigin(attacker, attackerPos);
        g_fSecCounterRespawnPosition = attackerPos;
    }
    return Plugin_Continue;
}

Action Timer_CounterAttackEnd(Handle timer)
{                                                // When counter-attack end, reset reinforcement time
    g_iTimerReinforceTime = g_iReinforceTime;    // Reset reinforcement time
    ResetInsurgencyLives();                      // Reset respawn token
    SetConVarInt(g_cvCounterattackAlways, 0, true, false);
    return Plugin_Continue;
}

// Run this to mark a bot as ready to spawn. Add tokens if you want them to be able to spawn.
void ResetInsurgencyLives()
{
    UpdateRespawnCvars();
    g_iRemaining_lives_team_ins = g_iRespawnLivesTeamIns;
}

public Action Event_PlayerPickSquad_Post(Event event, const char[] name, bool dontBroadcast)
{
    int  client = GetClientOfUserId(event.GetInt("userid"));
    char class_template[64];
    event.GetString("class_template", class_template, sizeof(class_template));
    g_client_last_classstring[client] = class_template;

    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Continue;

    g_playerPickSquad[client] = 1;

#if DOCTOR
    // If player changed squad and remain ragdoll
    int team = GetClientTeam(client);
    if (!IsPlayerAlive(client) && !g_iHurtFatal[client] && team == TEAM_1_SEC)
    {
        RemoveRagdoll(client);
        g_iHurtFatal[client]             = 1;
        ga_bPlayerSelectNewClass[client] = true;
    }
#endif

    char adminVal[9] = "";
    if (GetUserFlagBits(client) & ADMFLAG_BAN)
    {
        adminVal = "[ADMIN]";
    }
    char sNewNickname[64];
    if (StrContains(g_client_last_classstring[client], "medic") > -1)
    {
        if (!StrEqual(adminVal, ""))
        {
            Format(sNewNickname, sizeof(sNewNickname), "%s[MEDIC] %s", adminVal, g_client_org_nickname[client]);
        }
        else {
            Format(sNewNickname, sizeof(sNewNickname), "[MEDIC] %s", g_client_org_nickname[client]);
        }
    }
    else if (StrContains(g_client_last_classstring[client], "recon") > -1) {
        if (!StrEqual(adminVal, ""))
        {
            Format(sNewNickname, sizeof(sNewNickname), "%s[SGT] %s", adminVal, g_client_org_nickname[client]);
        }
        else {
            Format(sNewNickname, sizeof(sNewNickname), "[SGT] %s", g_client_org_nickname[client]);
        }
    }
    else if (StrContains(g_client_last_classstring[client], "support") > -1) {
        if (!StrEqual(adminVal, ""))
        {
            Format(sNewNickname, sizeof(sNewNickname), "%s[MG] %s", adminVal, g_client_org_nickname[client]);
        }
        else {
            Format(sNewNickname, sizeof(sNewNickname), "[MG] %s", g_client_org_nickname[client]);
        }
    }
    else {
        if (!StrEqual(adminVal, ""))
        {
            Format(sNewNickname, sizeof(sNewNickname), "%s %s", adminVal, g_client_org_nickname[client]);
        }
        else {
            Format(sNewNickname, sizeof(sNewNickname), "%s", g_client_org_nickname[client]);
        }
    }

    // Set player nickname
    char sCurNickname[64];
    Format(sCurNickname, sizeof(sCurNickname), "%N", client);
    if (!StrEqual(sCurNickname, sNewNickname))
        SetClientName(client, sNewNickname);
    g_playersReady = true;

    UpdateRespawnCvars();    // Update RespawnCvars when player picks squad
    return Plugin_Continue;
}

#if DOCTOR
// Triggers when player hurt
public Action Event_PlayerHurt_Pre(Event event, const char[] name, bool dontBroadcast)
{
    // int starttime = GetTime();
    // int endtime = 0;
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!IsClientInGame(victim) || IsFakeClient(victim)) return Plugin_Continue;

    int attacker     = GetClientOfUserId(event.GetInt("attacker"));
    int victimHealth = event.GetInt("health");
    int dmg_taken    = event.GetInt("dmg_health");

    if (g_fFatalChance > 0.0 && dmg_taken >= victimHealth)
    {
        int hitgroup               = event.GetInt("hitgroup");

        g_clientDamageDone[victim] = dmg_taken;    // Update last damege (related to 'hurt_fatal')
        char weapon[32];
        event.GetString("weapon", weapon, sizeof(weapon));
        float fRandom = GetRandomFloat(0.0, 1.0);    // Get fatal chance
        // PrintToChatAll("victim %d | victimHealth %d | dmg_taken %d | hitgroup %d | attacker %d",victim,victimHealth,dmg_taken,hitgroup,attacker);
        if (hitgroup == 0)
        {
            if (!attacker)
            {    // fatal chance from anyhting that doesn't broadcast attacker = entityflame(burn plugin) & death from fall
                if (fRandom <= 0.25)
                {
                    g_iHurtFatal[victim] = 1;
                }
            }
            // fire
            else if (StrEqual(weapon, "grenade_anm14", false)
                     || StrEqual(weapon, "grenade_molotov", false)
                     || StrEqual(weapon, "grenade_m203_incid", false)
                     || StrEqual(weapon, "grenade_gp25_incid", false)
                     || StrEqual(weapon, "grenade_m79_incen", false)) {
                if (dmg_taken >= g_iFatalBurnDmg && (fRandom <= g_fFatalChance))
                {
                    g_iHurtFatal[victim] = 1;    // Hurt fatally
                }
            }
            // explosive
            else if (StrEqual(weapon, "grenade_m67", false)
                     || StrEqual(weapon, "grenade_f1", false)
                     || StrEqual(weapon, "grenade_ied", false)
                     || StrEqual(weapon, "grenade_c4", false)
                     || StrEqual(weapon, "rocket_rpg7", false)
                     || StrEqual(weapon, "rocket_at4", false)
                     || StrEqual(weapon, "grenade_gp25_he", false)
                     || StrEqual(weapon, "grenade_m203_he", false)
                     || StrEqual(weapon, "grenade_m26a2", false)
                     || StrEqual(weapon, "grenade_c4_radius", false)
                     || StrEqual(weapon, "grenade_ied_radius", false)
                     || StrEqual(weapon, "grenade_ied_gunshot", false)
                     || StrEqual(weapon, "grenade_ied_fire", false)
                     || StrEqual(weapon, "grenade_ied_fire_bomber", false)
                     || StrEqual(weapon, "grenade_m79", false)) {
                if (dmg_taken >= g_iFatalExplosiveDmg && (fRandom <= g_fFatalChance))
                {
                    g_iHurtFatal[victim] = 1;    // Hurt fatally
                }
            }
        }
        else if (hitgroup == 1) {    // Headshot
            if (dmg_taken >= g_iFatalHeadDmg
                && fRandom <= g_fFatalHeadChance
                && attacker > 0
                && IsClientInGame(attacker)
                && GetClientTeam(attacker) != TEAM_1_SEC)
            {
                g_iHurtFatal[victim] = 1;    // Hurt fatally
            }
        }
        else if (hitgroup == 2 || hitgroup == 3) {    // Chest
            if (dmg_taken >= g_iFatalChestStomach && (fRandom <= g_fFatalChance))
            {
                g_iHurtFatal[victim] = 1;    // Hurt fatally
            }
        }
        else if (hitgroup == 4 || hitgroup == 5 || hitgroup == 6 || hitgroup == 7) {    // Limbs
            if (dmg_taken >= g_iFatalLimbDmg && (fRandom <= g_fFatalChance))
            {
                g_iHurtFatal[victim] = 1;    // Hurt fatally
            }
        }
    }
    if (!g_iHurtFatal[victim])
    {    // Track wound type (minor, moderate, critical)
        if (dmg_taken <= g_iMinorWoundDmg)
        {
            g_playerWoundTime[victim] = g_iMinorReviveTime;
            g_playerWoundType[victim] = 0;
        }
        else if (dmg_taken > g_iMinorWoundDmg && dmg_taken <= g_iModerateWoundDmg) {
            g_playerWoundTime[victim] = g_iModerateReviveTime;
            g_playerWoundType[victim] = 1;
        }
        else if (dmg_taken > g_iModerateWoundDmg) {
            g_playerWoundTime[victim] = g_iCriticalReviveTime;
            g_playerWoundType[victim] = 2;
        }
    }
    else {
        g_playerWoundTime[victim] = -1;
        g_playerWoundType[victim] = -1;
    }
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock Event_PlayerHurt_Pre %i (%N) (START: %i) (END: %i)", victim, victim, starttime, endtime);
    return Plugin_Continue;
}
#endif

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    // int gametime = GetTime();
    // int endtime = 0;
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim < 1 || !IsClientInGame(victim)) return Plugin_Continue;

    int team = GetClientTeam(victim);

    /*
    if (team == TEAM_1_SEC) {
        if (g_iFreeLives[victim] > 0) {
            LogMessage("[BM2 RESPAWN] player has free life, rez 'em (%i) %N",victim, victim);
            g_iFreeLives[victim]--;
            CreateCounterRespawnTimer(victim);
            return Plugin_Continue;
        } else {
            LogMessage("[BM2 RESPAWN] player has no free lifes (%i) %N",victim, victim);
        }
    }
    */

#if DOCTOR
    int dmg_taken = event.GetInt("damagebits");
    if (dmg_taken <= 0)
    {
        g_playerWoundTime[victim] = g_iMinorReviveTime;
        g_playerWoundType[victim] = 0;
    }

    if (g_iReviveEnabled && team == TEAM_1_SEC)
    {
        char sBuffer[32];
        IntToString(GetEntProp(victim, Prop_Send, "m_nBody"), sBuffer, sizeof(sBuffer));
        ga_sPlayerBGroups[victim] = sBuffer;

        /*
        for (int offset = 0; offset < 128; offset += 4) {
            int iWeapon = GetEntDataEnt2(victim, m_hMyWeapons + offset);
            if (iWeapon < 0) {
                continue;
            }
            char sWeapon[32];
            GetEdictClassname(iWeapon, sWeapon, sizeof(sWeapon));
            if (StrContains(sWeapon, "weapon_healthkit") != -1
            && IsValidEntity(iWeapon)) {
                RemovePlayerItem(victim, iWeapon);
                AcceptEntityInput(iWeapon, "kill");
            }
        }
        */
        // Convert ragdoll
        float vecPos[3];
        GetClientAbsOrigin(victim, vecPos);    // Get current position
        vecPos[2] += 10;
        g_fDeadPosition[victim] = vecPos;
        float angPos[3];
        GetClientAbsAngles(victim, angPos);    // Get current angles
        g_fDeadAngle[victim] = angPos;
        if (g_iEnableRevive && g_iRoundStatus)
        {
            CreateTimer(5.0, ConvertDeleteRagdoll, victim);    // Call ragdoll timer

            if (g_iFreeLives[victim] > 0)
            {
                // LogMessage("[BM2 RESPAWN] player has free life, rez 'em (%i) %N",victim, victim);
                g_iFreeLives[victim]--;
                CreateCounterRespawnTimer(victim);
                // endtime = GetTime();
                // LogMessage("[BM2 RESPAWN] Event_PlayerDeath %N (START: %f) (END: %f)", victim, starttime, endtime);
                // LogMessage("[BM2 RESPAWN] profile_clock Event_PlayerDeath %i (%N) (START: %i) (END: %i)", victim, victim, gametime, endtime);
                return Plugin_Continue;
            }    // else {
                 //	LogMessage("[BM2 RESPAWN] player has no free lifes (%i) %N",victim, victim);
                 //}
        }

        if ((StrContains(g_client_last_classstring[victim], "medic") > -1) && (g_iFreeLives[victim] == 0))
        {
            // LogMessage("[BM2 RESPAWN] Got medic kill, send message here");
            PrintToChatAll("A medic was killed, you should probably find and revive them");
        }
    }
#endif
    if (team == TEAM_2_INS)
    {
        bool finalPoint   = g_iACP == g_iNCP;
        bool infiniteBots = (finalPoint && g_iFinalCounterattackType == 2) || (!finalPoint && g_iCounterattackType == 2);
        // LogMessage("[BM2 RESPAWN] got infinitebots: %i",infiniteBots);
        if (g_bCounterAttack && infiniteBots)
        {
            g_iRemaining_lives_team_ins = g_iRespawnLivesTeamIns + 1;
            CreateBotRespawnTimer(victim);
        }
        else if (g_iRemaining_lives_team_ins > 0) {
            CreateBotRespawnTimer(victim);
        }
        // endtime = GetTime();
        // LogMessage("[BM2 RESPAWN] profile_clock Event_PlayerDeath %i (%N) (START: %i) (END: %i)", victim, victim, gametime, endtime);
        return Plugin_Continue;
    }
#if DOCTOR
    char sHint[128],
        woundType[64];

    if (g_playerWoundType[victim] == 0)
        woundType = "MINORLY WOUNDED";
    else if (g_playerWoundType[victim] == 1)
        woundType = "MODERATELY WOUNDED";
    else if (g_playerWoundType[victim] == 2)
        woundType = "CRITICALLY WOUNDED";

    if (g_fFatalChance > 0.0 && g_iHurtFatal[victim])
    {
        Format(sHint, sizeof(sHint), "You were fatally killed for %i damage", g_clientDamageDone[victim]);
        PrintHintText(victim, "%s", sHint);
        Format(sHint, sizeof(sHint), "You were fatally killed for \x070088cc%i\x01 damage", g_clientDamageDone[victim]);
        PrintToChat(victim, "\x01%s", sHint);
        PrintToChatAll("%N was fatally killed (completely dead)", victim);
    }
    else {
        Format(sHint, sizeof(sHint), "You're %s for %i damage, a medic will try to find you!", woundType, g_clientDamageDone[victim]);
        PrintHintText(victim, "%s", sHint);
        Format(sHint, sizeof(sHint), "You're \x070088cc%s\x01 for \x070088cc%i\x01 damage, a medic will try to find you!", woundType, g_clientDamageDone[victim]);
        PrintToChat(victim, "\x01%s", sHint);
    }
#endif
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock Event_PlayerDeath %i (%N) (START: %i) (END: %i)", victim, victim, gametime, endtime);
    return Plugin_Continue;
}

#if DOCTOR
// Convert dead body to new ragdoll
Action ConvertDeleteRagdoll(Handle timer, int client)
{
    // int gametime = GetTime();
    // int endtime = 0;
    if (IsClientInGame(client)
        && g_iRoundStatus
        && !IsPlayerAlive(client)
        && (GetClientTeam(client) == TEAM_1_SEC
            || GetClientTeam(client) == TEAM_2_INS)
        && HasEntProp(client, Prop_Send, "m_hRagdoll"))
    {
        // LogMessage("[BM2 RESPAWN] client died, deleting original ragdoll (%i) %N (%i)", client, client, gametime);
        int clientRagdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");

        if (clientRagdoll > 0
            && IsValidEdict(clientRagdoll)
            && IsValidEntity(clientRagdoll)
            && g_iEnableRevive == 1)
        {
            // int ref = EntIndexToEntRef(clientRagdoll);
            // LogMessage("[BM2 RESPAWN] convertdeleteragdoll (client: %i) %N (ragdoll: %i) (ent ref: %i) (gametime: %i)", client, client, clientRagdoll, ref, gametime);
            AcceptEntityInput(clientRagdoll, "Kill");
            // should g_iClientRagdolls[client] = INVALID_ENT_REFERENCE here???
        }    // else {
        //	LogMessage("[BM2 RESPAWN] convertdeleteragdoll (client: %i) %N (NO RAGDOLL) (gametime: %i)", client, client, gametime);
        //}
        /*
        if (clientRagdoll > 0
            && IsValidEdict(clientRagdoll)
            && IsValidEntity(clientRagdoll)
            && g_iEnableRevive == 1) {
            //This timer safely removes client-side ragdoll
            int ref = EntIndexToEntRef(clientRagdoll);
            int entity = EntRefToEntIndex(ref);
            if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity)) {
                AcceptEntityInput(entity, "Kill");
                clientRagdoll = INVALID_ENT_REFERENCE;
            }
        }
        */
        if (!g_iHurtFatal[client])
        {
            int tempRag = CreateEntityByName("prop_ragdoll");
            if (IsValidEdict(tempRag) && IsValidEntity(tempRag))
            {
                g_iClientRagdolls[client] = EntIndexToEntRef(tempRag);
                char sBuffer[64];
                GetClientModel(client, sBuffer, sizeof(sBuffer));
                if (is_ww2_server.IntValue == 1)
                {
                    SetEntityModel(tempRag, ww2_ragdoll_any);
                }
                else {
                    if (StrContains(g_client_last_classstring[client], "medic") != -1)
                    {
                        SetEntityModel(tempRag, normal_ragdoll_medic);
                    }
                    else {
                        SetEntityModel(tempRag, normal_ragdoll_player);
                    }
                }
                // Give custom ragdoll name for each client, this way other plugins can search for targetname to modify behavior
                Format(sBuffer, sizeof(sBuffer), "playervital_ragdoll_%i", client);
                DispatchKeyValue(tempRag, "targetname", sBuffer);
                DispatchKeyValue(tempRag, "body", ga_sPlayerBGroups[client]);

                Format(sBuffer, sizeof(sBuffer), "%f %f %f", g_fDeadPosition[client][0], g_fDeadPosition[client][1], g_fDeadPosition[client][2] += 15.0);
                DispatchKeyValue(tempRag, "Origin", sBuffer);

                Format(sBuffer, sizeof(sBuffer), "%f %f %f", g_fDeadAngle[client][0] += -90.0, g_fDeadAngle[client][1], g_fDeadAngle[client][2]);
                DispatchKeyValue(tempRag, "Angles", sBuffer);

                DispatchSpawn(tempRag);

                // must be after DispatchSpawn
                DispatchKeyValue(tempRag, "CollisionGroup", "17");

                // GetEntPropVector(tempRag, Prop_Send, "m_vecOrigin", g_fRagdollPosition[client]);
                g_fRagdollPosition[client]             = g_fDeadPosition[client];

                g_iReviveRemainingTime[client]         = g_playerWoundTime[client];
                g_iReviveNonMedicRemainingTime[client] = g_iNonMedicReviveTime;
            }
        }
        // endtime = GetTime();
        // LogMessage("[BM2 RESPAWN] profile_clock convertdeleteragdoll %i (%N) (START: %i) (END: %i)", client, client, gametime, endtime);
        // LogMessage("[BM2 RESPAWN] convertdeleteragdoll END (client: %i) %N (ragdoll: %i) (START: %f) (END: %f)", client, client, clientRagdoll, gametime, now);
    }
    return Plugin_Continue;
}

bool hasCorrectWeapon(const char[] sWeapon, bool melee = true)
{
    if (melee)
    {
        if (StrContains(sWeapon, "weapon_defib") != -1
            || StrContains(sWeapon, "weapon_knife") != -1
            || StrContains(sWeapon, "weapon_kabar") != -1
            || StrContains(sWeapon, "weapon_katana") != -1)
        {
            // player has one of the above weapons
            return true;
        }
    }
    else {
        if (StrContains(sWeapon, "weapon_healthkit") != -1)
        {
            // player has one of the above
            return true;
        }
    }
    return false;
}

void RemoveRagdoll(int client)
{    // Remove ragdoll
    int entity = EntRefToEntIndex(g_iClientRagdolls[client]);
    if (entity != INVALID_ENT_REFERENCE && IsValidEdict(entity) && IsValidEntity(entity))
    {
        AcceptEntityInput(entity, "Kill");
    }
    g_iClientRagdolls[client] = INVALID_ENT_REFERENCE;
}

void CreateReviveTimer(int client)
{    // This handles revives by medics
    CreateTimer(0.0, RespawnPlayerRevive, client);
}
#endif

// Respawn bot
void CreateBotRespawnTimer(int client)
{
    if (client > MaxClients || client <= 0) return;

    if (!g_is_respawning[client])
    {
        CreateTimer(g_fDelayTeamIns + GetURandomFloat(), RespawnBot, client);
    }    // else {
         //	LogMessage("[BM2 RESPAWN] not creating respawnbot timer, already respawning (%i) %N",client,client);
         //}

    /*
    if (StrContains(g_client_last_classstring[client], "bomber") != -1
        || StrContains(g_client_last_classstring[client], "tank") != -1) {
        if (g_iCqcMapEnabled && g_bCounterAttack) {
            if (StrContains(g_client_last_classstring[client], "bomber") > -1) {
                CreateTimer((g_fDelayTeamInsSpecial / 3.0), RespawnBot, client);
            } else if (StrContains(g_client_last_classstring[client], "tank") > -1) {
                CreateTimer((g_fDelayTeamInsSpecial / 4.0), RespawnBot, client);
            }
        } else {
            if (StrContains(g_client_last_classstring[client], "bomber") > -1) {
                CreateTimer((g_fDelayTeamInsSpecial * 2.0), RespawnBot, client);
            } else if (StrContains(g_client_last_classstring[client], "tank") > -1) {
                CreateTimer((g_fDelayTeamInsSpecial), RespawnBot, client);
            }
        }
    } else {
        CreateTimer(g_fDelayTeamIns, RespawnBot, client);
    }
    */
}

#if DOCTOR
Action RespawnPlayerRevive(Handle timer, int client)
{    // Revive player
    if (!IsClientInGame(client))
    {
        return Plugin_Stop;
    }
    if (IsPlayerAlive(client) || !g_iRoundStatus)
    {
        return Plugin_Stop;
    }

    SDKCall(g_hForceRespawn, client);                        // Call forcerespawn fucntion
    SetEntProp(client, Prop_Send, "m_iDesiredStance", 2);    // spawn player in prone position

    int iHealth = GetClientHealth(client);
    if (g_revivedByMedic[client])
    {
        if (g_playerWoundType[client] == 0)
            iHealth = g_iMedicMinorReviveHp;
        else if (g_playerWoundType[client] == 1)
            iHealth = g_iMedicModerateReviveHp;
        else if (g_playerWoundType[client] == 2)
            iHealth = g_iMedicCriticalReviveHp;
    }
    else {
        iHealth = g_iNonMedicReviveHp;
    }
    SetEntityHealth(client, iHealth);

    RemoveRagdoll(client);    // Remove network ragdoll

    RespawnPlayerRevivePost(client);
    return Plugin_Continue;
}

void RespawnPlayerRevivePost(int client)
{
    TeleportEntity(client, g_fRagdollPosition[client], NULL_VECTOR, NULL_VECTOR);
    // Reset ragdoll position
    g_fRagdollPosition[client][0] = 0.0;
    g_fRagdollPosition[client][1] = 0.0;
    g_fRagdollPosition[client][2] = 0.0;
}
#endif

Action RespawnBot(Handle timer, int client)
{
    // int starttime = GetTime();
    // int endtime = 0;
    if (!IsClientInGame(client) || IsPlayerAlive(client) || !g_iRoundStatus)
    {
        return Plugin_Stop;
    }
    g_is_respawning[client] = true;
    if (g_last_bot_respawn_time == GetTime())
    {
        // int clientId = GetClientUserId(client);
        // float gametime = GetGameTime();
        // LogMessage("[BM2 RESPAWN] g_last_bot_respawn_time is equal, push spawn back one second, (client_id: %i) (%i) %N %f",clientId, client, client, gametime);
        CreateTimer(g_fDelayTeamIns, RespawnBot, client);
        return Plugin_Continue;
    }

    char sModelName[64];
    GetClientModel(client, sModelName, sizeof(sModelName));
    if (StrEqual(sModelName, ""))
    {    // check if model is blank
        return Plugin_Stop;
    }
    g_last_bot_respawn_time = GetTime();
    if (g_iRemaining_lives_team_ins > 0)
    {
        g_iRemaining_lives_team_ins--;

        if (g_iRemaining_lives_team_ins <= 0)
            g_iRemaining_lives_team_ins = 0;
    }

    SDKCall(g_hForceRespawn, client);
    // LogMessage("[BM2 RESPAWN] respawnbot made sdkcall: (%i) %N", client, client);
    g_is_respawning[client] = false;
    // endtime = GetTime();
    // LogMessage("[BM2 RESPAWN] profile_clock respawnbot %i (%N) (START: %i) (END: %i)", client, client, starttime, endtime);
    // return
    return Plugin_Continue;
}

#if DOCTOR
// Handles reviving for medics and non-medics
Action Timer_ReviveMonitor(Handle timer)
{
    if (!g_iRoundStatus)
    {
        return Plugin_Continue;
    }

    float flalivePlayerPosition[3],
        fDistance,
        fReviveDistance = 75.0;

    int deadPlayer,
        deadPlayerRagdoll,
        ActiveWeapon,
        CurrentTime;

    char sWeapon[32],
        sBuf[255],
        woundType[64],
        discordString[128];

    for (int alivePlayer = 1; alivePlayer <= MaxClients; alivePlayer++)
    {
        if (!IsClientInGame(alivePlayer)
            || GetClientTeam(alivePlayer) != TEAM_1_SEC
            || !IsPlayerAlive(alivePlayer))
        {
            continue;
        }

        deadPlayer = g_iNearestBody[alivePlayer];
        if (deadPlayer <= 0
            || !IsClientInGame(deadPlayer)
            || IsPlayerAlive(deadPlayer)
            || g_iHurtFatal[deadPlayer]
            || deadPlayer == alivePlayer
            || GetClientTeam(alivePlayer) != GetClientTeam(deadPlayer))
        {
            continue;
        }

        // Jareds pistols only code to verify alivePlayer is carrying knife
        ActiveWeapon = GetEntPropEnt(alivePlayer, Prop_Data, "m_hActiveWeapon");
        if (ActiveWeapon < 0)
        {
            continue;
        }

        deadPlayerRagdoll = INVALID_ENT_REFERENCE;
        deadPlayerRagdoll = EntRefToEntIndex(g_iClientRagdolls[deadPlayer]);

        if (deadPlayerRagdoll == INVALID_ENT_REFERENCE
            || !IsValidEdict(deadPlayerRagdoll)
            || !IsValidEntity(deadPlayerRagdoll))
        {
            continue;
        }

        GetClientAbsOrigin(alivePlayer, flalivePlayerPosition);
        GetEntPropVector(deadPlayerRagdoll, Prop_Send, "m_vecOrigin", g_fRagdollPosition[deadPlayer]);

        fDistance = GetVectorDistance(g_fRagdollPosition[deadPlayer], flalivePlayerPosition);

        if (fDistance > fReviveDistance
            || !ClientCanSeeVector(alivePlayer, g_fRagdollPosition[deadPlayer], fReviveDistance))
        {
            continue;
        }

        if (g_playerWoundType[deadPlayer] == 0)
            woundType = "minor wound";
        else if (g_playerWoundType[deadPlayer] == 1)
            woundType = "moderate wound";
        else if (g_playerWoundType[deadPlayer] == 2)
            woundType = "critical wound";

        GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));

        if (StrContains(g_client_last_classstring[alivePlayer], "medic") != -1)
        {
            /* I'm a medic */

            if (!hasCorrectWeapon(sWeapon))
            {
                continue;
            }

            if (g_iReviveRemainingTime[deadPlayer] > 0)
            {
                Format(sBuf, sizeof(sBuf), "Reviving %N in: %i seconds (%s)", deadPlayer, g_iReviveRemainingTime[deadPlayer], woundType);
                PrintHintText(alivePlayer, "%s", sBuf);
                Format(sBuf, sizeof(sBuf), "%N is reviving you in: %i seconds (%s)", alivePlayer, g_iReviveRemainingTime[deadPlayer], woundType);
                PrintHintText(deadPlayer, "%s", sBuf);
                g_iReviveRemainingTime[deadPlayer]--;
                if (!g_beingRevivedByMedic[deadPlayer])
                {
                    Format(sBuf, sizeof(sBuf), "%N is reviving %N", alivePlayer, deadPlayer);
                    PrintToChatAll(sBuf);
                }
                g_beingRevivedByMedic[deadPlayer] = true;
                CurrentTime                       = GetTime();
                g_timeReviveCheck[deadPlayer]     = CurrentTime;
            }
            else {
                Format(sBuf, sizeof(sBuf), "You revived %N from a %s", deadPlayer, woundType);
                PrintHintText(alivePlayer, "%s", sBuf);
                Format(sBuf, sizeof(sBuf), "%N revived you from a %s", alivePlayer, woundType);
                PrintHintText(deadPlayer, "%s", sBuf);

                PlayVictimReviveSound(deadPlayer);
                EmitSoundToAll("weapons/defibrillator/defibrillator_revive.wav", alivePlayer, SNDCHAN_AUTO, _, _, 0.3);

                g_iStatRevives[alivePlayer]++;
                g_iBonusPoint[alivePlayer] += revive_point_bonus.IntValue;
                medic_bonus_life_check(alivePlayer);

                Check_NearbyMedicsRevive(alivePlayer, deadPlayer);
                g_revivedByMedic[deadPlayer] = true;
                CreateReviveTimer(deadPlayer);
                SendForwardMedicRevive(alivePlayer, deadPlayer);
                Format(discordString, sizeof(discordString), "revived %N", deadPlayer);
                send_to_discord(alivePlayer, discordString);
            }
        }
        else {
            /* I'm not a medic */

            if (!hasCorrectWeapon(sWeapon, false))
            {
                continue;
            }

            if (g_iReviveNonMedicRemainingTime[deadPlayer] > 0)
            {
                Format(sBuf, sizeof(sBuf), "Reviving %N in: %i seconds (%s)", deadPlayer, g_iReviveNonMedicRemainingTime[deadPlayer], woundType);
                PrintHintText(alivePlayer, "%s", sBuf);
                Format(sBuf, sizeof(sBuf), "%N is reviving you in: %i seconds (%s)", alivePlayer, g_iReviveNonMedicRemainingTime[deadPlayer], woundType);
                PrintHintText(deadPlayer, "%s", sBuf);
                g_iReviveNonMedicRemainingTime[deadPlayer]--;
            }
            else {
                Format(sBuf, sizeof(sBuf), "You revived %N from a %s", deadPlayer, woundType);
                PrintHintText(alivePlayer, "%s", sBuf);
                Format(sBuf, sizeof(sBuf), "%N revived you from a %s", alivePlayer, woundType);
                PrintHintText(deadPlayer, "%s", sBuf);

                PlayVictimReviveSound(deadPlayer);
                g_iStatRevives[alivePlayer]++;
                g_iBonusPoint[alivePlayer] += revive_point_bonus.IntValue;
                medic_bonus_life_check(alivePlayer);

                Check_NearbyMedicsRevive(alivePlayer, deadPlayer);
                g_revivedByMedic[deadPlayer] = false;
                CreateReviveTimer(deadPlayer);

                /*
                int iAmmoType = GetEntProp(ActiveWeapon, Prop_Data, "m_iPrimaryAmmoType"),
                    iAmmo = GetEntProp(alivePlayer, Prop_Data, "m_iAmmo", _, iAmmoType);
                if (iAmmo > 0) {
                    SetEntProp(alivePlayer, Prop_Send, "m_iAmmo", iAmmo-1, _, iAmmoType);
                } else {
                    RemovePlayerItem(alivePlayer,ActiveWeapon);
                    ChangePlayerWeaponSlot(alivePlayer, 2);
                }
                */
                RemovePlayerItem(alivePlayer, ActiveWeapon);
                // LogMessage("[RESPAWN] Changing %N weapon to slot 2 now", alivePlayer);
                CreateTimer(0.1, Timer_ChangeWeaponFromHK, alivePlayer, TIMER_FLAG_NO_MAPCHANGE);
                // ChangePlayerWeaponSlot(alivePlayer, 2);
                SendForwardMedicRevive(alivePlayer, deadPlayer);
                Format(discordString, sizeof(discordString), "revived %N", deadPlayer);
                send_to_discord(alivePlayer, discordString);
            }
        }
    }
    return Plugin_Continue;
}

public Action Timer_ChangeWeaponFromHK(Handle timer, int client)
{
    if ((IsClientInGame(client)) && (IsPlayerAlive(client)))
    {
        ChangePlayerWeaponSlot(client, 2);
    }
    return Plugin_Continue;
}

public Action getDeadCounts(Handle timer)
{
    int current_revivables    = 0;
    int current_nonrevivables = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)
            || IsFakeClient(client))
        {
            continue;
        }

        if (!IsPlayerAlive(client))
        {
            if (g_playerWoundType[client] > -1)
            {
                current_revivables++;
            }
            else {
                current_nonrevivables++;
            }
        }
    }
    SendForwardDeadCount(current_revivables, current_nonrevivables);
    return Plugin_Continue;
}

public Action SendForwardDeadCount(int revivable, int fatal)
{
    Action result;
    Call_StartForward(DeadCountForward);
    Call_PushCell(revivable);
    Call_PushCell(fatal);
    Call_Finish(result);
    return result;
}

public Action SendForwardMedicRevive(int iMedic, int iInjured)
{    // tug stats forward
    Action result;
    Call_StartForward(MedicRevivedForward);
    Call_PushCell(iMedic);
    Call_PushCell(iInjured);
    Call_Finish(result);
    return result;
}

public Action SendForwardMedicHealed(int iMedic, int iInjured)
{    // tug stats forward
    Action result;
    Call_StartForward(MedicHealedForward);
    Call_PushCell(iMedic);
    Call_PushCell(iInjured);
    Call_Finish(result);
    return result;
}

public Action SendForwardResult(int iMedic, int iInjured, int revive)
{    // tug stats forward
    Action result;
    Call_StartForward(MedicRevivedForward);
    Call_PushCell(iMedic);
    Call_PushCell(iInjured);
    Call_PushCell(revive);
    Call_Finish(result);
    return result;
}

// Handles medic functions (Inspecting health, healing)
Action Timer_MedicMonitor(Handle timer)
{
    if (!g_iRoundStatus)
    {
        return Plugin_Continue;
    }

    bool bCanHealPaddle   = false,
         bCanHealMedpack  = false;

    float fReviveDistance = 80.0,
          vecOriginatingPlayer[3],
          vecTargetPlayer[3],
          tDistance;

    int ActiveWeapon,
        iHealth,
        targetPlayer;

    char sWeapon[32],
        sBuf[255];

    for (int originatingPlayer = 1; originatingPlayer <= MaxClients; originatingPlayer++)
    {
        if (!IsClientInGame(originatingPlayer)
            || !IsPlayerAlive(originatingPlayer)
            || GetClientTeam(originatingPlayer) != TEAM_1_SEC)
        {
            continue;
        }

        ActiveWeapon = GetEntPropEnt(originatingPlayer, Prop_Data, "m_hActiveWeapon");
        if (ActiveWeapon < 0)
        {
            continue;
        }

        bCanHealPaddle  = false;
        bCanHealMedpack = false;

        GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));

        if (hasCorrectWeapon(sWeapon))
        {
            bCanHealPaddle  = true;
            bCanHealMedpack = false;
        }
        if (hasCorrectWeapon(sWeapon, false))
        {
            bCanHealPaddle  = false;
            bCanHealMedpack = true;
        }

        if (!bCanHealPaddle && !bCanHealMedpack)
        {
            continue;
        }

        if (StrContains(g_client_last_classstring[originatingPlayer], "medic") != -1)
        {
            /* I'm a medic */

            targetPlayer = TraceClientViewEntity(originatingPlayer);
            if (targetPlayer > 0
                && targetPlayer <= MaxClients
                && IsClientInGame(targetPlayer)
                && IsPlayerAlive(targetPlayer)
                && GetClientTeam(targetPlayer) == TEAM_1_SEC)
            {
                GetClientAbsOrigin(originatingPlayer, vecOriginatingPlayer);
                GetClientAbsOrigin(targetPlayer, vecTargetPlayer);
                tDistance = GetVectorDistance(vecOriginatingPlayer, vecTargetPlayer);

                iHealth   = GetClientHealth(targetPlayer);
                if (tDistance < 750.0)
                {
                    PrintHintText(originatingPlayer, "%N\nHP: %i", targetPlayer, iHealth);
                }

                if (tDistance > fReviveDistance
                    || !ClientCanSeeVector(originatingPlayer, vecTargetPlayer, fReviveDistance))
                {
                    continue;
                }

                if (iHealth < 100)
                {
                    iHealth += bCanHealPaddle && !bCanHealMedpack ? g_iHealAmountPaddles : g_iHealAmountMedpack;

                    if (iHealth >= 100)
                    {
                        g_iStatHeals[originatingPlayer]++;

                        iHealth = 100;
                        g_iBonusPoint[originatingPlayer] += full_heal_point_bonus.IntValue;
                        PrintHintText(targetPlayer, "You were healed by %N (HP: %i)", originatingPlayer, iHealth);
                        Format(sBuf, sizeof(sBuf), "You fully healed %N", targetPlayer);
                        PrintHintText(originatingPlayer, "%s", sBuf);
                        Format(sBuf, sizeof(sBuf), "You fully healed \x070088cc%N", targetPlayer);
                        PrintToChat(originatingPlayer, "\x01%s", sBuf);
                        SendForwardMedicHealed(originatingPlayer, targetPlayer);
                    }
                    else {
                        // PrintHintText(targetPlayer, "DON'T MOVE! %N is healing you.(HP: %i)", originatingPlayer, iHealth);
                        char originating_player_name[64];
                        Format(originating_player_name, sizeof(originating_player_name), "%N", originatingPlayer);
                        PrintHintText(targetPlayer, "%T", "do_not_move_getting_healed", targetPlayer, originating_player_name, iHealth);
                        // PrintHintText(targetPlayer, "%T", "do_not_move_getting_healed", targetPlayer, originatingPlayer, iHealth);
                        if (g_should_ask_to_heal)
                        {
                            // LogMessage("[GG Respawn] yelling at player to let medic heal them");
                            EmitSoundToAll(let_me_heal_you[GetRandomInt(0, letme_heal_sounds_count - 1)], originatingPlayer, SNDCHAN_VOICE, _, _, 1.0);
                            // EmitSoundToAll("tug/medic_letme_heal1.ogg", originatingPlayer, SNDCHAN_VOICE, _, _, 1.0);
                            g_should_ask_to_heal = false;
                            CreateTimer(4.0, Timer_should_ask_to_heal, _, TIMER_FLAG_NO_MAPCHANGE);
                        }
                    }
                    SetEntityHealth(targetPlayer, iHealth);
                    PrintHintText(originatingPlayer, "%N\nHP: %i\n\nHealing with %s for: %i", targetPlayer, iHealth, bCanHealPaddle && !bCanHealMedpack ? "paddle" : "medpack", bCanHealPaddle && !bCanHealMedpack ? g_iHealAmountPaddles : g_iHealAmountMedpack);
                }
            }
            else {
                iHealth = GetClientHealth(originatingPlayer);
                if (iHealth < g_iMedicHealSelfMax)
                {
                    iHealth += bCanHealPaddle && !bCanHealMedpack ? g_iHealAmountPaddles : g_iHealAmountMedpack;

                    if (iHealth >= g_iMedicHealSelfMax)
                    {
                        iHealth = g_iMedicHealSelfMax;
                        PrintHintText(originatingPlayer, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_iMedicHealSelfMax);
                    }
                    else {
                        PrintHintText(originatingPlayer, "Healing Self (HP: %i) | MAX: %i", iHealth, g_iMedicHealSelfMax);
                    }
                    SetEntityHealth(originatingPlayer, iHealth);
                }
            }
        }
        else {
            /* I'm not a medic */

            if (!bCanHealMedpack)
            {
                continue;
            }

            targetPlayer = TraceClientViewEntity(originatingPlayer);
            if (targetPlayer > 0
                && targetPlayer <= MaxClients
                && IsClientInGame(targetPlayer)
                && IsPlayerAlive(targetPlayer)
                && GetClientTeam(targetPlayer) == TEAM_1_SEC)
            {
                GetClientAbsOrigin(originatingPlayer, vecOriginatingPlayer);
                GetClientAbsOrigin(targetPlayer, vecTargetPlayer);
                tDistance = GetVectorDistance(vecOriginatingPlayer, vecTargetPlayer);

                if (tDistance > fReviveDistance
                    || !ClientCanSeeVector(originatingPlayer, vecTargetPlayer, fReviveDistance))
                {
                    continue;
                }

                iHealth = GetClientHealth(targetPlayer);
                if (tDistance < 750.0)
                {
                    PrintHintText(originatingPlayer, "%N\nHP: %i", targetPlayer, iHealth);
                }

                if (iHealth < g_iNonMedicMaxHealOther)
                {
                    iHealth += g_iNonMedicHealAmt;

                    if (iHealth >= g_iNonMedicMaxHealOther)
                    {
                        g_iStatHeals[originatingPlayer]++;

                        iHealth = g_iNonMedicMaxHealOther;
                        SendForwardMedicHealed(originatingPlayer, targetPlayer);
                        g_iBonusPoint[originatingPlayer] += full_heal_point_bonus.IntValue;
                        PrintHintText(targetPlayer, "Non-Medic %N can only heal you for %i HP!)", originatingPlayer, iHealth);
                        Format(sBuf, sizeof(sBuf), "You max healed %N", targetPlayer);
                        PrintHintText(originatingPlayer, "%s", sBuf);
                        Format(sBuf, sizeof(sBuf), "You max healed \x070088cc%N", targetPlayer);
                        PrintToChat(originatingPlayer, "\x01%s", sBuf);
                    }
                    else {
                        PrintHintText(targetPlayer, "DON'T MOVE! %N is healing you.(HP: %i)", originatingPlayer, iHealth);
                        if (g_should_ask_to_heal)
                        {
                            // LogMessage("[GG Respawn] yelling at player to let medic heal them");
                            EmitSoundToAll(let_me_heal_you[GetRandomInt(0, letme_heal_sounds_count - 1)], originatingPlayer, SNDCHAN_VOICE, _, _, 1.0);
                            // EmitSoundToAll("tug/medic_letme_heal1.ogg", originatingPlayer, SNDCHAN_VOICE, _, _, 1.0);
                            g_should_ask_to_heal = false;
                            CreateTimer(4.0, Timer_should_ask_to_heal, _, TIMER_FLAG_NO_MAPCHANGE);
                        }
                    }
                    SetEntityHealth(targetPlayer, iHealth);
                    PrintHintText(originatingPlayer, "%N\nHP: %i\n\nHealing.", targetPlayer, iHealth);
                }
                else {
                    if (iHealth < g_iNonMedicMaxHealOther)
                    {
                        PrintHintText(originatingPlayer, "%N\nHP: %i", targetPlayer, iHealth);
                    }
                    else if (iHealth >= g_iNonMedicMaxHealOther) {
                        PrintHintText(originatingPlayer, "%N\nHP: %i (MAX YOU CAN HEAL)", targetPlayer, iHealth);
                    }
                }
            }
            else {
                iHealth = GetClientHealth(originatingPlayer);
                if (iHealth < g_iNonMedicHealSelfMax)
                {
                    iHealth += g_iNonMedicHealAmt;
                    if (iHealth >= g_iNonMedicHealSelfMax)
                    {
                        iHealth = g_iNonMedicHealSelfMax;
                        PrintHintText(originatingPlayer, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_iNonMedicHealSelfMax);
                    }
                    else {
                        PrintHintText(originatingPlayer, "Healing Self (HP: %i) | MAX: %i", iHealth, g_iNonMedicHealSelfMax);
                    }
                    SetEntityHealth(originatingPlayer, iHealth);
                }
            }
        }
    }
    return Plugin_Continue;
}

/*
Action Timer_AmmoResupply(Handle timer) {
    if (!g_iRoundStatus) {
        return Plugin_Continue;
    }

    int		ActiveWeapon,
            validAmmoCache;

    char	sWeapon[32],
            sBuf[255];

    for (int client = 1; client <= MaxClients; client++) {

        if (!IsClientInGame(client)
            || !IsPlayerAlive(client)
            || GetClientTeam(client) != TEAM_1_SEC
            ) {
            continue;
        }

        ActiveWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
        if (ActiveWeapon < 0) {
            continue;
        }

        GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));

        if (GetClientButtons(client) & INS_RELOAD && hasCorrectWeapon(sWeapon)) {

            validAmmoCache = -1;
            validAmmoCache = FindValidProp_InDistance(client);
            if (validAmmoCache == -1) {
                continue;
            }

            g_resupplyCounter[client] -= 1;
            if (g_ammoResupplyAmt[validAmmoCache] <= 0) {
                g_ammoResupplyAmt[validAmmoCache] = (g_TeamSecCount / 3);
                if (g_ammoResupplyAmt[validAmmoCache] <= 1) {
                    g_ammoResupplyAmt[validAmmoCache] = 1;
                }
            }

            Format(sBuf, sizeof(sBuf), "Resupplying ammo in %d seconds | Supply left: %d", g_resupplyCounter[client], g_ammoResupplyAmt[validAmmoCache]);
            PrintHintText(client, "%s", sBuf);
            if (g_resupplyCounter[client] <= 0) {
                g_resupplyCounter[client] = g_iResupplyDelay;
                AmmoResupply_Player(client);
                g_ammoResupplyAmt[validAmmoCache] -= 1;
                if (g_ammoResupplyAmt[validAmmoCache] <= 0 && validAmmoCache != -1) {
                    AcceptEntityInput(validAmmoCache, "kill");
                }
                Format(sBuf, sizeof(sBuf), "Rearmed! Ammo Supply left: %d", g_ammoResupplyAmt[validAmmoCache]);
                PrintHintText(client, "%s", sBuf);
                Format(sBuf, sizeof(sBuf), "Rearmed! Ammo Supply left: \x070088cc%d", g_ammoResupplyAmt[validAmmoCache]);
                PrintToChat(client, "\x01%s", sBuf);
            }
        }
    }
    return Plugin_Continue;
}
*/
/*
void AmmoResupply_Player(int client) {
    float plyrOrigin[3], tempOrigin[3];
    GetClientAbsOrigin(client,plyrOrigin);
    tempOrigin = plyrOrigin;
    tempOrigin[2] = -5000.0;

    int clientRagdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");	// Get dead body
    //This safely removes client-side ragdoll
    if (clientRagdoll > 0 && IsValidEdict(clientRagdoll) && IsValidEntity(clientRagdoll)) {
        // Get dead body's entity
        int ref = EntIndexToEntRef(clientRagdoll);
        int entity = EntRefToEntIndex(ref);
        if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity)) {
            // Remove dead body's entity
            AcceptEntityInput(entity, "Kill");
            clientRagdoll = INVALID_ENT_REFERENCE;
        }
    }
    ForceRespawnPlayer(client, client);
    TeleportEntity(client, plyrOrigin, NULL_VECTOR, NULL_VECTOR);
    PrintHintText(client, "Ammo Resupplied");
}
*/
#endif

void RemoveWeapons(int client, bool keepPrimary = false, bool keepSecondary = false, bool keepGrenades = false)
{
    int weaponToRemove = -1;

    if (!keepPrimary
        && (weaponToRemove = GetPlayerWeaponSlot(client, 0)) != -1
        && IsValidEntity(weaponToRemove))
    {
        RemovePlayerItem(client, weaponToRemove);
        AcceptEntityInput(weaponToRemove, "kill");
    }
    weaponToRemove = -1;

    if (!keepSecondary
        && (weaponToRemove = GetPlayerWeaponSlot(client, 1)) != -1
        && IsValidEntity(weaponToRemove))
    {
        RemovePlayerItem(client, weaponToRemove);
        AcceptEntityInput(weaponToRemove, "kill");
    }
    weaponToRemove = -1;

    if (!keepGrenades
        && (weaponToRemove = GetPlayerWeaponSlot(client, 3)) != -1
        && IsValidEntity(weaponToRemove))
    {
        do
        {
            RemovePlayerItem(client, weaponToRemove);
            AcceptEntityInput(weaponToRemove, "kill");
        }
        while ((weaponToRemove = GetPlayerWeaponSlot(client, 3)) != -1 && IsValidEntity(weaponToRemove));
    }
}

#if DOCTOR
/*
int FindValidProp_InDistance(int client) {	//Find Valid Prop

    int prop;
    while ((prop = FindEntityByClassname(prop, "prop_dynamic_override")) != -1) {
        char propModelName[128];
        GetEntPropString(prop, Prop_Data, "m_ModelName", propModelName, 128);
        if (StrEqual(propModelName, "models/sernix/ammo_cache/ammo_cache_small.mdl")
        || StrContains(propModelName, "models/sernix/ammo_cache/ammo_cache_small.mdl") > -1) {
            float tDistance = (GetEntitiesDistance(client, prop));
            if (tDistance <= g_fAmmoResupplyRange) {
                return prop;
            }
        }
    }
    return -1;
}
*/
/*
float GetEntitiesDistance(int ent1, int ent2) {
    float orig1[3], orig2[3];
    GetEntPropVector(ent1, Prop_Send, "m_vecOrigin", orig1);
    GetEntPropVector(ent2, Prop_Send, "m_vecOrigin", orig2);
    return GetVectorDistance(orig1, orig2);
}
*/
Action Timer_NearestBody(Handle timer)
{
    if (!g_iRoundStatus)
    {
        return Plugin_Continue;
    }

    float flAlivePlayerPosition[3],
        flAlivePlayerAngle[3],
        flLastPlayerDistance,
        fTempDistance,
        flShortestDistanceToPlayer,
        beamPosition[3];

    int closestDeadPlayer,
        closestDeadPlayerWithoutMedic,
        amountOfHurtPlayers,
        CurrentTime,
        clientRagdoll;

    char sDirection[64],
        sDistance[64],
        sHeight[64];

    bool is_medic = false;
    for (int alivePlayer = 1; alivePlayer <= MaxClients; alivePlayer++)
    {
        if (!IsClientInGame(alivePlayer)
            || GetClientTeam(alivePlayer) != TEAM_1_SEC
            || !IsPlayerAlive(alivePlayer))
        {
            continue;
        }

        is_medic                      = (StrContains(g_client_last_classstring[alivePlayer], "medic") != -1);

        flLastPlayerDistance          = 0.0;
        flShortestDistanceToPlayer    = 0.0;
        closestDeadPlayer             = 0;
        closestDeadPlayerWithoutMedic = 0;
        amountOfHurtPlayers           = 0;
        GetClientAbsOrigin(alivePlayer, flAlivePlayerPosition);

        for (int deadPlayer = 1; deadPlayer <= MaxClients; deadPlayer++)
        {
            if (!IsClientInGame(deadPlayer)
                || IsPlayerAlive(deadPlayer)
                || g_iHurtFatal[deadPlayer]
                || deadPlayer == alivePlayer
                || GetClientTeam(alivePlayer) != GetClientTeam(deadPlayer))
            {
                continue;
            }

            if (g_beingRevivedByMedic[deadPlayer])
            {
                CurrentTime = GetTime();
                if ((CurrentTime - g_timeReviveCheck[deadPlayer]) >= 2)
                {
                    g_beingRevivedByMedic[deadPlayer] = false;
                }
            }

            clientRagdoll = INVALID_ENT_REFERENCE;
            clientRagdoll = EntRefToEntIndex(g_iClientRagdolls[deadPlayer]);

            if (clientRagdoll == INVALID_ENT_REFERENCE
                || !IsValidEdict(clientRagdoll)
                || !IsValidEntity(clientRagdoll))
            {
                continue;
            }

            fTempDistance = GetVectorDistance(flAlivePlayerPosition, g_fRagdollPosition[deadPlayer]);

            if (flLastPlayerDistance == 0.0
                || fTempDistance < flLastPlayerDistance)
            {
                flLastPlayerDistance = fTempDistance;
                closestDeadPlayer    = deadPlayer;
            }

            if (!g_beingRevivedByMedic[deadPlayer]
                && (flShortestDistanceToPlayer == 0.0
                    || fTempDistance < flShortestDistanceToPlayer))
            {
                flShortestDistanceToPlayer    = fTempDistance;
                closestDeadPlayerWithoutMedic = deadPlayer;
            }

            amountOfHurtPlayers++;
        }

        // set the closest body for this client
        g_iNearestBody[alivePlayer] = closestDeadPlayer != 0 ? closestDeadPlayer : -1;

        if (closestDeadPlayerWithoutMedic != 0)
        {
            GetClientAbsAngles(alivePlayer, flAlivePlayerAngle);

            // show dead nav if player is medic
            if (is_medic)
            {
                char name[64];
                GetClientName(closestDeadPlayerWithoutMedic, name, sizeof(name));
                // Get direction string (if it cause server lag, remove this)
                sDirection = GetDirectionString(flAlivePlayerAngle, flAlivePlayerPosition, g_fRagdollPosition[closestDeadPlayerWithoutMedic]);
                sDistance  = GetDistanceString(flShortestDistanceToPlayer);
                sHeight    = GetHeightString(flAlivePlayerPosition, g_fRagdollPosition[closestDeadPlayerWithoutMedic]);
                // PrintCenterText(alivePlayer, "Nearest dead[%d]: %N ( %s | %s | %s )", amountOfHurtPlayers, closestDeadPlayerWithoutMedic, sDistance, sDirection, sHeight);
                PrintCenterText(alivePlayer, "%T", "medic_nearest_dead", alivePlayer, amountOfHurtPlayers, name, sDistance, sDirection, sHeight);
            }
            beamPosition = g_fRagdollPosition[closestDeadPlayerWithoutMedic];
            beamPosition[2] += 0.3;
            if (fTempDistance >= 140)
            {
                TE_SetupBeamRingPoint(beamPosition, 1.0, Revive_Indicator_Radius, g_iBeaconBeam, g_iBeaconHalo, 0, 15, 5.0, 3.0, 5.0, { 255, 0, 0, 255 }, 1, FBEAM_FADEIN | FBEAM_FADEOUT);
                TE_SendToClient(alivePlayer);
            }
        }
    }
    return Plugin_Continue;
}
/**
 * Get direction string for nearest dead body
 *
 * @param fClientAngles[3]		Client angle
 * @param fClientPosition[3]	Client position
 * @param fTargetPosition[3]	Target position
 * @Return						direction string.
 */
char[] GetDirectionString(float fClientAngles[3], float fClientPosition[3], float fTargetPosition[3])
{
    float fTempAngles[3], fTempPoints[3];
    char  sDirection[64];
    // Angles from origin
    MakeVectorFromPoints(fClientPosition, fTargetPosition, fTempPoints);
    GetVectorAngles(fTempPoints, fTempAngles);
    float fDiff = fClientAngles[1] - fTempAngles[1];    // Differenz
    // Correct it
    if (fDiff < -180)
        fDiff = 360 + fDiff;

    if (fDiff > 180)
        fDiff = 360 - fDiff;

    // Now geht the direction
    // Up
    if (fDiff >= -22.5 && fDiff < 22.5)
        Format(sDirection, sizeof(sDirection), "FWD");    //"\xe2\x86\x91");
    // right up
    else if (fDiff >= 22.5 && fDiff < 67.5)
        Format(sDirection, sizeof(sDirection), "FWD-RIGHT");    //"\xe2\x86\x97");
    // right
    else if (fDiff >= 67.5 && fDiff < 112.5)
        Format(sDirection, sizeof(sDirection), "RIGHT");    //"\xe2\x86\x92");
    // right down
    else if (fDiff >= 112.5 && fDiff < 157.5)
        Format(sDirection, sizeof(sDirection), "BACK-RIGHT");    //"\xe2\x86\x98");
    // down
    else if (fDiff >= 157.5 || fDiff < -157.5)
        Format(sDirection, sizeof(sDirection), "BACK");    //"\xe2\x86\x93");
    // down left
    else if (fDiff >= -157.5 && fDiff < -112.5)
        Format(sDirection, sizeof(sDirection), "BACK-LEFT");    //"\xe2\x86\x99");
    // left
    else if (fDiff >= -112.5 && fDiff < -67.5)
        Format(sDirection, sizeof(sDirection), "LEFT");    //"\xe2\x86\x90");
    // left up
    else if (fDiff >= -67.5 && fDiff < -22.5)
        Format(sDirection, sizeof(sDirection), "FWD-LEFT");    //"\xe2\x86\x96");
    return sDirection;
}

char[] GetDistanceString(float fDistance)
{                                                 // Return distance string
    float fTempDistance = fDistance * 0.01905;    // Distance to meters
    char  sResult[64];
    if (g_iReviveDistanceMetric)
    {    // Distance to feet?
        fTempDistance = fTempDistance * 3.2808399;
        Format(sResult, sizeof(sResult), "%.0f feet", fTempDistance);    // Feet
    }
    else {
        Format(sResult, sizeof(sResult), "%.0f meter", fTempDistance);    // Meter
    }
    return sResult;
}
/**
 * Get height string for nearest dead body
 *
 * @param fClientPosition[3]	Client position
 * @param fTargetPosition[3]	Target position
 * @Return						height string.
 */
char[] GetHeightString(float fClientPosition[3], float fTargetPosition[3])
{
    // char s[11], unit[1];
    char  s[11], unit[2];
    float verticalDifference, fTempDistance;
    verticalDifference = FloatAbs(fClientPosition[2] - fTargetPosition[2]);
    fTempDistance      = verticalDifference * 0.01905;    // Distance to meters
    if (g_iReviveDistanceMetric)
    {
        fTempDistance = fTempDistance * 3.2808399;    // Distance to feet
        unit          = "'";
    }
    else {
        unit = "m";
    }
    if (fClientPosition[2] + 64 < fTargetPosition[2])
    {
        Format(s, sizeof(s), "ABOVE %.0f%s", fTempDistance, unit);
    }
    else if (fClientPosition[2] - 64 > fTargetPosition[2]) {
        Format(s, sizeof(s), "BELOW %.0f%s", fTempDistance, unit);
    }
    else {
        s = "LEVEL";
    }
    return s;
}
#endif

int GetTeamSecCount()
{    // Get tesm2 player count
    int clients = 0, iTeam;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            iTeam = GetClientTeam(i);
            if (iTeam == TEAM_1_SEC && !IsFakeClient(i))
                clients++;
        }
    }
    return clients;
}

#if DOCTOR
int TraceClientViewEntity(int client)
{    // Trace client's view entity
    float m_vecOrigin[3], m_angRotation[3];
    GetClientEyePosition(client, m_vecOrigin);
    GetClientEyeAngles(client, m_angRotation);
    Handle tr      = TR_TraceRayFilterEx(m_vecOrigin, m_angRotation, MASK_VISIBLE, RayType_Infinite, TRDontHitSelf, client);
    int    pEntity = -1;
    if (TR_DidHit(tr))
    {
        pEntity = TR_GetEntityIndex(tr);
        delete tr;
        return pEntity;
    }
    delete tr;
    return -1;
}
#endif

bool TRDontHitSelf(int entity, int mask, any data)
{    // Don't ray trace ourselves -_-"		// Check is hit self
    return (1 <= entity <= MaxClients) && (entity != data);
}
/*
########################LUA HEALING INTEGRATION######################
#	This portion of the script adds in health packs from Lua		#
##############################START##################################
#####################################################################
*/
#if DOCTOR

public Action Event_GrenadeThrown(Event event, const char[] name, bool dontBroadcast)
{
    int client  = GetClientOfUserId(event.GetInt("userid"));
    int nade_id = event.GetInt("entityid");
    if (nade_id > -1 && client > -1)
    {
        if (IsPlayerAlive(client))
        {
            char grenade_name[32];
            GetEntityClassname(nade_id, grenade_name, sizeof(grenade_name));
            if (StrEqual(grenade_name, "healthkit"))
            {
                switch (GetRandomInt(1, 18))
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
    }
    return Plugin_Continue;
}
#endif

/*
public void OnEntityDestroyed(int entity) {
    if (entity > MaxClients) {
        char classname[255];
        GetEntityClassname(entity, classname, 255);
        if ((StrContains(classname, "ammo_cache_small") > -1)) {
            g_ammoResupplyAmt[entity] = 0;
        }
    }
}*/
public void OnEntityCreated(int entity, const char[] classname)
{
#if DOCTOR
    if (StrEqual(classname, "healthkit"))
    {
        DataPack hDatapack;
        g_healthPack_Amount[entity] = g_iMedpackHealthAmount;
        CreateDataTimer(Healthkit_Timer_Tickrate, Healthkit, hDatapack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        hDatapack.WriteCell(entity);
        hDatapack.WriteFloat(GetGameTime() + Healthkit_Timer_Timeout);
        g_fLastHeight[entity]      = -9999.0;
        g_iTimeCheckHeight[entity] = -9999;
        SDKHook(entity, SDKHook_VPhysicsUpdate, HealthkitGroundCheck);
        CreateTimer(0.1, HealthkitGroundCheckTimer, EntIndexToEntRef(entity), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        return;
    }
#endif
    if (StrEqual(classname, "grenade_m67") || StrEqual(classname, "grenade_f1") || StrEqual(classname, "grenade_m26a2"))
    {
        CreateTimer(0.5, GrenadeScreamCheckTimer, EntIndexToEntRef(entity), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    else if (StrEqual(classname, "grenade_molotov") || StrEqual(classname, "grenade_anm14")) {
        CreateTimer(0.2, FireScreamCheckTimer, EntIndexToEntRef(entity), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    else if (StrEqual(classname, "ins_nightvision")) {
        switch (GetRandomInt(0, 1))
        {
            case 0: SetEntData(entity, g_iNvgToggle, false);
            case 1: SetEntData(entity, g_iNvgToggle, true);
        }
    }
}

Action FireScreamCheckTimer(Handle timer, int entref)
{
    float fGrenOrigin[3],
        fPlayerOrigin[3],
        fPlayerEyeOrigin[3];

    int owner,
        entity = EntRefToEntIndex(entref),
        teamOwner;

    if (entity != INVALID_ENT_REFERENCE
        && entity > 0
        && IsValidEntity(entity)
        && HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fGrenOrigin);
        owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    }
    else {
        KillTimer(timer);
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)
            || owner < 1
            || owner > MaxClients
            || !IsClientInGame(owner)
            || !IsPlayerAlive(client)
            || GetClientTeam(owner) == GetClientTeam(client))
        {
            continue;
        }

        GetClientEyePosition(client, fPlayerEyeOrigin);
        GetClientAbsOrigin(client, fPlayerOrigin);
        if (GetVectorDistance(fPlayerOrigin, fGrenOrigin) <= 300
            && g_plyrFireScreamCoolDown[client] <= 0)
        {
            teamOwner = GetClientTeam(owner);
            if (teamOwner == TEAM_2_INS)
            {
                PlayerFireScreamRand(client);
            }
            else if (teamOwner == TEAM_1_SEC) {
                BotFireScreamRand(client);
            }
            g_plyrFireScreamCoolDown[client] = GetRandomInt(20, 30);
        }
    }
    if (!IsValidEntity(entity) || !(entity > 0))
    {
        KillTimer(timer);
    }
    return Plugin_Continue;
}

Action GrenadeScreamCheckTimer(Handle timer, int entref)
{
    float fGrenOrigin[3],
        fPlayerOrigin[3],
        fPlayerEyeOrigin[3];

    int owner,
        entity = EntRefToEntIndex(entref),
        teamOwner;

    if (entity != INVALID_ENT_REFERENCE
        && entity > 0
        && IsValidEntity(entity)
        && HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
    {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fGrenOrigin);
        owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    }
    else {
        KillTimer(timer);
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)
            || owner < 1
            || owner > MaxClients
            || !IsClientInGame(owner)
            || !IsPlayerAlive(client)
            || GetClientTeam(owner) == GetClientTeam(client))
        {
            continue;
        }

        GetClientEyePosition(client, fPlayerEyeOrigin);
        GetClientAbsOrigin(client, fPlayerOrigin);
        if (GetVectorDistance(fPlayerOrigin, fGrenOrigin) <= 240
            && g_plyrGrenScreamCoolDown[client] <= 0)
        {
            teamOwner = GetClientTeam(owner);
            if (teamOwner == TEAM_2_INS)
            {
                PlayerGrenadeScreamRand(client);
            }
            else if (teamOwner == TEAM_1_SEC) {
                BotGrenadeScreamRand(client);
            }
            g_plyrGrenScreamCoolDown[client] = GetRandomInt(6, 12);
        }
    }
    if (!IsValidEntity(entity) || !(entity > 0))
    {
        KillTimer(timer);
    }
    return Plugin_Continue;
}

#if DOCTOR

public Action HealthkitGroundCheck(int entity, int activator, int caller, UseType type, float value)
{
    float fOrigin[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOrigin);
    int iRoundHeight = RoundFloat(fOrigin[2]);
    if (iRoundHeight != g_iTimeCheckHeight[entity])
    {
        g_iTimeCheckHeight[entity] = iRoundHeight;
        g_fTimeCheck[entity]       = GetGameTime();
    }
    return Plugin_Continue;
}

Action HealthkitGroundCheckTimer(Handle timer, int entref)
{
    int entity = EntRefToEntIndex(entref);
    if (entity != INVALID_ENT_REFERENCE && entity > MaxClients && IsValidEntity(entity))
    {
        float fGameTime = GetGameTime();
        if (fGameTime - g_fTimeCheck[entity] >= 1.0)
        {
            float fOrigin[3];
            GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOrigin);
            int iRoundHeight = RoundFloat(fOrigin[2]);
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
    return Plugin_Continue;
}

public Action OnEntityPhysicsUpdate(int entity, int activator, int caller, UseType type, float value)
{
    TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, view_as<float>({ 0.0, 0.0, 0.0 }));
    return Plugin_Continue;
}

Action Healthkit(Handle timer, DataPack hDatapack)
{
    hDatapack.Reset();
    int   healthPack = hDatapack.ReadCell();
    float fEndTime   = hDatapack.ReadFloat();
    float fGameTime  = GetGameTime();
    if (healthPack > 0
        && IsValidEntity(healthPack)
        && fGameTime > fEndTime)
    {
        RemoveHealthkit(healthPack);
        KillTimer(timer);
        return Plugin_Stop;
    }
    if (g_healthPack_Amount[healthPack] > 0)
    {
        if (healthPack > 0 && IsValidEntity(healthPack))
        {
            float fOrigin[3],
                fAng[3],
                fResetVelocity[3] = { 0.0, 0.0, 0.0 },
                fPlayerOrigin[3];

            int ActiveWeapon,
                iHealth;

            char sWeapon[32];

            GetEntPropVector(healthPack, Prop_Send, "m_vecOrigin", fOrigin);
            fOrigin[2] += 1.0;
            TE_SetupBeamRingPoint(fOrigin, 1.0, Healthkit_Radius * 1.95, g_iBeaconBeam, g_iBeaconHalo, 0, 30, 5.0, 3.0, 0.0, { 0, 200, 0, 255 }, 1, (FBEAM_FADEOUT));
            TE_SendToAll();
            fOrigin[2] -= 16.0;

            if (g_fLastHeight[healthPack] == -9999.0)
            {
                g_fLastHeight[healthPack] = 0.0;
            }

            if (fOrigin[2] != g_fLastHeight[healthPack])
            {
                g_fLastHeight[healthPack] = fOrigin[2];
            }
            else {
                GetEntPropVector(healthPack, Prop_Send, "m_angRotation", fAng);
                if (fAng[1] > 89.0 || fAng[1] < -89.0)
                    fAng[1] = 90.0;
                if (fAng[2] > 89.0 || fAng[2] < -89.0)
                {
                    fAng[2] = 0.0;
                    fOrigin[2] -= 6.0;
                    TeleportEntity(healthPack, fOrigin, fAng, fResetVelocity);
                    fOrigin[2] += 6.0;
                    EmitSoundToAll("ui/sfx/cl_click.wav", healthPack, SNDCHAN_VOICE, _, _, 1.0);
                }
            }

            for (int client = 1; client <= MaxClients; client++)
            {
                if (!IsClientInGame(client)
                    || !IsPlayerAlive(client)
                    || GetClientTeam(client) != TEAM_1_SEC)
                {
                    continue;
                }

                if (StrContains(g_client_last_classstring[client], "medic") != -1)
                {
                    /* I'm a medic */

                    ActiveWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
                    if (ActiveWeapon < 0)
                    {
                        continue;
                    }

                    GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
                    if (!hasCorrectWeapon(sWeapon))
                    {
                        continue;
                    }

                    GetClientEyePosition(client, fPlayerOrigin);
                    if (GetVectorDistance(fPlayerOrigin, fOrigin) > Healthkit_Radius)
                    {
                        continue;
                    }

                    iHealth = GetClientHealth(client);
                    if (Check_NearbyMedics(client))
                    {
                        if (iHealth < 100)
                        {
                            iHealth += g_iHealAmountPaddles;
                            g_healthPack_Amount[healthPack] -= g_iHealAmountPaddles;
                            if (iHealth >= 100)
                            {
                                iHealth = 100;
                                PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                                PrintHintText(client, "A medic assisted in healing you (HP: %i)", iHealth);
                            }
                            else {
                                PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                                PrintHintText(client, "Self area healing (HP: %i)", iHealth);
                            }
                            SetEntityHealth(client, iHealth);
                        }
                    }
                    else {
                        if (iHealth < g_iMedicHealSelfMax)
                        {
                            iHealth += g_iHealAmountPaddles;
                            g_healthPack_Amount[healthPack] -= g_iHealAmountPaddles;
                            if (iHealth >= g_iMedicHealSelfMax)
                            {
                                iHealth = g_iMedicHealSelfMax;
                                PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                                PrintHintText(client, "You area healed yourself (HP: %i) | MAX: %i", iHealth, g_iMedicHealSelfMax);
                            }
                            else {
                                PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                                PrintHintText(client, "Self area healing (HP: %i) | MAX %i", iHealth, g_iMedicHealSelfMax);
                            }
                        }
                        else {
                            PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                            PrintHintText(client, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_iMedicHealSelfMax);
                        }
                    }
                }
                else {
                    /* I'm not a medic */

                    GetClientEyePosition(client, fPlayerOrigin);
                    if (GetVectorDistance(fPlayerOrigin, fOrigin) > Healthkit_Radius)
                    {
                        continue;
                    }

                    if (Check_NearbyMedics(client))
                    {
                        iHealth = GetClientHealth(client);
                        if (iHealth < 100)
                        {
                            iHealth += g_iHealAmountPaddles;
                            g_healthPack_Amount[healthPack] -= g_iHealAmountPaddles;
                            if (iHealth >= 100)
                            {
                                iHealth = 100;
                                PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                                PrintHintText(client, "A medic assisted in healing you (HP: %i)", iHealth);
                            }
                            else {
                                PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                                PrintHintText(client, "Medic area healing you (HP: %i)", iHealth);
                                switch (GetRandomInt(1, 6))
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
                    else {
                        ActiveWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
                        if (ActiveWeapon < 0)
                        {
                            continue;
                        }
                        GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
                        iHealth = GetClientHealth(client);

                        if (!hasCorrectWeapon(sWeapon))
                        {
                            if (iHealth < g_iNonMedicHealSelfMax)
                            {
                                PrintHintText(client, "No medics nearby! Pull knife out to heal! (HP: %i)", iHealth);
                            }
                            continue;
                        }

                        if (iHealth < g_iNonMedicHealSelfMax)
                        {
                            iHealth += g_iNonMedicHealAmt;
                            g_healthPack_Amount[healthPack] -= g_iNonMedicHealAmt;
                            if (iHealth >= g_iNonMedicHealSelfMax)
                            {
                                iHealth = g_iNonMedicHealSelfMax;
                                PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                                PrintHintText(client, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_iNonMedicHealSelfMax);
                            }
                            else {
                                PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                                PrintHintText(client, "Healing Self (HP: %i) | MAX: %i", iHealth, g_iNonMedicHealSelfMax);
                            }
                            SetEntityHealth(client, iHealth);
                        }
                        else {
                            PrintCenterText(client, "Medical Pack HP Left: %i", g_healthPack_Amount[healthPack]);
                            PrintHintText(client, "You healed yourself (HP: %i) | MAX: %i", iHealth, g_iNonMedicHealSelfMax);
                        }
                    }
                }
            }
        }
        else {
            RemoveHealthkit(healthPack);
            KillTimer(timer);
        }
    }
    else if (g_healthPack_Amount[healthPack] <= 0) {
        RemoveHealthkit(healthPack);
        KillTimer(timer);
    }
    return Plugin_Continue;
}

void RemoveHealthkit(int entity)
{
    if (entity > MaxClients && IsValidEntity(entity))
    {
        AcceptEntityInput(entity, "Kill");
    }
}

bool Check_NearbyMedics(int client)
{
    float clientPosition[3],
        medicPosition[3],
        fDistance;

    int  ActiveWeapon;

    char sWeapon[32];

    for (int friendlyMedic = 1; friendlyMedic <= MaxClients; friendlyMedic++)
    {
        if (!IsClientInGame(friendlyMedic)
            || !IsPlayerAlive(friendlyMedic)
            || client == friendlyMedic
            || StrContains(g_client_last_classstring[friendlyMedic], "medic") == -1)
        {
            continue;
        }

        ActiveWeapon = GetEntPropEnt(friendlyMedic, Prop_Data, "m_hActiveWeapon");
        if (ActiveWeapon < 0)
        {
            continue;
        }

        GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
        if (!hasCorrectWeapon(sWeapon) && !hasCorrectWeapon(sWeapon, false))
        {
            continue;
        }

        GetClientAbsOrigin(client, clientPosition);
        GetClientAbsOrigin(friendlyMedic, medicPosition);
        fDistance = GetVectorDistance(medicPosition, clientPosition);

        if (fDistance <= Healthkit_Radius)
        {
            return true;
        }
    }
    return false;
}

void Check_NearbyMedicsRevive(int client, int iInjured)
{
    float medicPosition[3],
        fDistance;

    int  ActiveWeapon;

    char sWeapon[32],
        woundType[64],
        sBuf[255];

    for (int assistingMedic = 1; assistingMedic <= MaxClients; assistingMedic++)
    {
        if (!IsClientInGame(assistingMedic)
            || !IsPlayerAlive(assistingMedic)
            || client == assistingMedic
            || StrContains(g_client_last_classstring[assistingMedic], "medic") == -1)
        {
            continue;
        }

        ActiveWeapon = GetEntPropEnt(assistingMedic, Prop_Data, "m_hActiveWeapon");
        if (ActiveWeapon < 0)
        {
            continue;
        }

        GetEdictClassname(ActiveWeapon, sWeapon, sizeof(sWeapon));
        if (!hasCorrectWeapon(sWeapon))
        {
            continue;
        }

        GetClientAbsOrigin(assistingMedic, medicPosition);
        fDistance = GetVectorDistance(medicPosition, g_fRagdollPosition[iInjured]);

        if (fDistance <= 65.0)
        {
            if (g_playerWoundType[iInjured] == 0)
                woundType = "minor wound";
            else if (g_playerWoundType[iInjured] == 1)
                woundType = "moderate wound";
            else if (g_playerWoundType[iInjured] == 2)
                woundType = "critical wound";

            g_iStatRevives[assistingMedic]++;
            medic_bonus_life_check(assistingMedic);

            Format(sBuf, sizeof(sBuf), "You revived(assisted) %N from a %s", iInjured, woundType);
            PrintHintText(assistingMedic, "%s", sBuf);
        }
    }
}

/*
########################LUA HEALING INTEGRATION######################
#	This portion of the script adds in health packs from Lua		#
##############################END####################################
#####################################################################
*/
public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1) return Plugin_Continue;
    if (IsClientInGame(client)
        && !IsFakeClient(client)
        && (GetClientTeam(client) == TEAM_SPEC
            || GetClientTeam(client) == SPECTATOR_TEAM))
    {
        RemoveRagdoll(client);
    }
    return Plugin_Continue;
}

public Action fatal_cmd(int client, int args)
{
    if (!IsPlayerAlive(client) && !g_iHurtFatal[client])
    {
        g_iHurtFatal[client] = 1;
        RemoveRagdoll(client);
        PrintToChat(client, "Changed your death to fatal.");
    }
    return Plugin_Handled;
}

void ResetMedicStats(int client)
{
    g_iStatRevives[client] = 0;
    g_iStatHeals[client]   = 0;
}
#endif

int countAliveInsurgents()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i)
            && IsPlayerAlive(i)
            && GetClientTeam(i) == TEAM_2_INS)
        {
            count++;
        }
    }
    return count;
}

#if DOCTOR
void PlayVictimReviveSound(int client)
{
    switch (GetRandomInt(1, 20))
    {
        case 1: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 2: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks2.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 3: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 4: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks4.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 5: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks5.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 6: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks6.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 7: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks7.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 8: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks8.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 9: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks9.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 10: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks10.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 11: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks11.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 12: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks12.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 13: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks13.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 14: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks14.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 15: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks15.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 16: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks16.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 17: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks17.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 18: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks18.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 19: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks19.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
        case 20: EmitSoundToAll("lua_sounds/medic/thx/medic_thanks20.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
    }
}
#endif

bool IsInfiniteCounterAttack()
{
    if (g_iACP == g_iNCP)
    {
        if (g_iFinalCounterattackType == 2)
        {
            // LogMessage("[BM2 RESPAWN] got infinite counterattack");
            return true;
        }
    }
    else if (g_iCounterattackType == 2) {
        // LogMessage("[BM2 RESPAWN] got infinite counterattack");
        return true;
    }
    // LogMessage("[BM2 RESPAWN] got not infinite counterattack");
    return false;
}

public void OnPluginEnd()
{
    delete ga_hMapSpawns;
    delete ga_hBotSpawns;
    delete ga_hNextBotSpawns;
    delete ga_hFinalBotSpawns;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//									BOT STUCK DETECTION
//	https://github.com/IT-KiLLER/Sourcemod-plugins/blob/master/Plugins/stuck/stuck.sp
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

void StartStuckDetection(int client)
{
    StuckCheck[client]++;
    isStuck[client] = false;
    CheckIfPlayerCanMove(client, 0, 500.0, 0.0, 0.0);
    isStuck[client] = CheckIfPlayerIsStuck(client);    // Check if player stuck in prop
}

bool CheckIfPlayerIsStuck(int client)
{
    float vecMin[3], vecMax[3], vecOrigin[3];
    GetClientMins(client, vecMin);
    GetClientMaxs(client, vecMax);
    GetClientAbsOrigin(client, vecOrigin);
    TR_TraceHullFilter(vecOrigin, vecOrigin, vecMin, vecMax, MASK_SOLID, TraceEntityFilterSolid);
    return TR_DidHit();    // head in wall ?
}

bool TraceEntityFilterSolid(int entity, int contentsMask)
{
    return entity > MaxClients;
}

// In few case there are issues with IsPlayerStuck() like clip
void CheckIfPlayerCanMove(int client, int testID, float X = 0.0, float Y = 0.0, float Z = 0.0)
{
    float vecVelo[3], vecOrigin[3];
    GetClientAbsOrigin(client, vecOrigin);
    vecVelo[0] = X;
    vecVelo[1] = Y;
    vecVelo[2] = Z;
    SetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", vecVelo);

    DataPack TimerDataPack;
    CreateDataTimer(0.1, TimerWait, TimerDataPack);
    TimerDataPack.WriteCell(client);
    TimerDataPack.WriteCell(testID);
    TimerDataPack.WriteFloat(vecOrigin[0]);
    TimerDataPack.WriteFloat(vecOrigin[1]);
    TimerDataPack.WriteFloat(vecOrigin[2]);
}

Action TimerWait(Handle timer, DataPack data)
{
    float vecOrigin[3], vecOriginAfter[3];
    data.Reset();
    int client   = data.ReadCell();
    int testID   = data.ReadCell();
    vecOrigin[0] = data.ReadFloat();
    vecOrigin[1] = data.ReadFloat();
    vecOrigin[2] = data.ReadFloat();
    if (IsClientInGame(client) && IsPlayerAlive(client))
    {
        GetClientAbsOrigin(client, vecOriginAfter);
        // Can't move
        if (GetVectorDistance(vecOrigin, vecOriginAfter, false) < 10.0)
        {
            if (testID == 0)
                CheckIfPlayerCanMove(client, 1, 0.0, 0.0, -500.0);    // Jump
            else if (testID == 1)
                CheckIfPlayerCanMove(client, 2, -500.0, 0.0, 0.0);
            else if (testID == 2)
                CheckIfPlayerCanMove(client, 3, 0.0, 500.0, 0.0);
            else if (testID == 3)
                CheckIfPlayerCanMove(client, 4, 0.0, -500.0, 0.0);
            else if (testID == 4)
                CheckIfPlayerCanMove(client, 5, 0.0, 0.0, 300.0);
            else
                FixPlayerPosition(client);
        }
    }
    return Plugin_Continue;
}

void FixPlayerPosition(int client)
{
    // UnStuck player stuck in prop
    if (isStuck[client])
    {
        float pos_Z = 0.1;
        while (pos_Z <= RadiusSize && !TryFixPosition(client, 10.0, pos_Z))
        {
            pos_Z = -pos_Z;
            if (pos_Z > 0.0)
                pos_Z += Step;
        }
        if (!CheckIfPlayerIsStuck(client) && StuckCheck[client] < 7)    // If client was stuck => new check
            StartStuckDetection(client);
    }
    // UnStuck player stuck in clip (invisible wall)
    else {
        // if it is a clip on the sky, it will try to find the ground !
        Handle trace = INVALID_HANDLE;
        float  vecOrigin[3], vecAngle[3];
        GetClientAbsOrigin(client, vecOrigin);
        vecAngle[0] = 90.0;
        trace       = TR_TraceRayFilterEx(vecOrigin, vecAngle, MASK_SOLID, RayType_Infinite, TraceEntityFilterSolid);
        if (!TR_DidHit(trace))
        {
            delete trace;
            return;
        }

        TR_GetEndPosition(vecOrigin, trace);
        delete trace;
        vecOrigin[2] += 10.0;
        TeleportEntity(client, vecOrigin, NULL_VECTOR, Ground_Velocity);

        // If client was stuck in invisible wall => new check
        if (StuckCheck[client] < 7)
        {
            StartStuckDetection(client);
        }
        else {
            ForcePlayerSuicide(client);
            AddLifeForStaticKilling(client);
        }
    }
}

bool TryFixPosition(int client, float Radius, float pos_Z)
{
    float DegreeAngle, vecPosition[3], vecOrigin[3], vecAngle[3];
    GetClientAbsOrigin(client, vecOrigin);
    GetClientEyeAngles(client, vecAngle);
    vecPosition[2] = vecOrigin[2] + pos_Z;

    DegreeAngle    = -180.0;
    while (DegreeAngle < 180.0)
    {
        vecPosition[0] = vecOrigin[0] + Radius * Cosine(DegreeAngle * FLOAT_PI / 180);    // convert angle in radian
        vecPosition[1] = vecOrigin[1] + Radius * Sine(DegreeAngle * FLOAT_PI / 180);

        TeleportEntity(client, vecPosition, vecAngle, Ground_Velocity);
        if (!CheckIfPlayerIsStuck(client))
            return true;
        DegreeAngle += 10.0;    // + 10°
    }
    TeleportEntity(client, vecOrigin, vecAngle, Ground_Velocity);
    if (Radius <= RadiusSize)
        return TryFixPosition(client, Radius + Step, pos_Z);
    return false;
}
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//							END OF BOT STUCK DETECTION
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
public Action cmd_BotSpawnDebug(int client, int args)
{
    if (!g_iRoundStatus)
    {
        ReplyToCommand(client, "Use it after round start");
        return Plugin_Handled;
    }

    float fVecCP[3],
        fNextVecCP[3],
        fDuration  = 60.0;

    int iArraySize = 0;

    iArraySize     = GetArraySize(ga_hBotSpawns);
    if (iArraySize > 0)
    {
        ShowSprites(client, ga_hBotSpawns, iArraySize, fDuration);
    }
    ReplyToCommand(client, "ga_hBotSpawns: %d g_iPushSpawnStatus: %d", iArraySize, g_iPushSpawnStatus);

    iArraySize = GetArraySize(ga_hNextBotSpawns);
    if (iArraySize > 0)
    {
        ShowSprites(client, ga_hNextBotSpawns, iArraySize, fDuration);
    }
    ReplyToCommand(client, "ga_hNextBotSpawns: %d g_iNextSpawnStatus: %d", iArraySize, g_iNextSpawnStatus);

    iArraySize = GetArraySize(ga_hFinalBotSpawns);
    if (iArraySize > 0)
    {
        ShowSprites(client, ga_hFinalBotSpawns, iArraySize, fDuration);
    }
    ReplyToCommand(client, "ga_hFinalBotSpawns: %d", iArraySize);

    Ins_ObjectiveResource_GetPropVector("m_vCPPositions", fVecCP, (g_iACP == g_iNCP) ? g_iACP - 1 : g_iACP);
    Ins_ObjectiveResource_GetPropVector("m_vCPPositions", fNextVecCP, (g_iACP + 1 >= g_iNCP) ? g_iNCP - 2 : g_iACP + 1);
    TE_SetupBeamPoints(fVecCP, fNextVecCP, g_iBeaconBeam, g_iBeaconHalo, 0, 15, fDuration, 3.0, 5.0, 90, 0.0, { 255, 153, 0, 255 }, 1);
    TE_SendToClient(client);

    ReplyToCommand(client, "g_iACP: %d g_iNCP: %d", g_iACP, g_iNCP);
    ReplyToCommand(client, "sm_botspawn_objmax: %f sm_botspawn_capped: %f",
                   g_fSpawnMaxRange, g_fSpawnDistFromCapped);
    ReplyToCommand(client, "sm_botspawn_next: %f sm_botspawn_counterfix: %f",
                   g_fSpawnPercentNext, g_fSpawnDistCounterFix);
    return Plugin_Handled;
}

void ShowSprites(int client, ArrayList array, int size, float fDuration)
{
    float fVecSpawn[3];
    for (int i = 0; i < size; i++)
    {
        GetArrayArray(array, i, fVecSpawn);
        fVecSpawn[2] += 15.0;
        TE_SetupGlowSprite(fVecSpawn, g_iBeaconBeam, fDuration, 0.5, 200);
        TE_SendToClient(client);
    }
}

Action Timer_FindBotSpawns(Handle timer)
{
    if (!g_iRoundStatus)
    {
        KillTimer(timer);
    }
    else if (!g_bCounterAttack) {
        FindBotSpawnPoints();
        KillTimer(timer);
    }
    return Plugin_Continue;
}

Action Timer_RoundStartFindBotSpawns(Handle timer)
{
    FindBotSpawnPoints();
    return Plugin_Continue;
}

bool IsSecNearObj()
{
    if (g_fStopSpawnDist == 0.0)
    {
        return false;
    }
    float fPlayerVec[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i)
            && IsPlayerAlive(i)
            && !IsFakeClient(i)
            && GetClientTeam(i) == TEAM_1_SEC)
        {
            GetClientAbsOrigin(i, fPlayerVec);
            if (GetDistanceToCapturePoint(fPlayerVec, g_iACP) <= g_fStopSpawnDist)
            {
                return true;
            }
        }
    }
    return false;
}

void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
#if DOCTOR
    if (convar == g_cvReviveEnabled)
    {
        g_iReviveEnabled = g_cvReviveEnabled.IntValue;
    }
    else if (convar == g_cvFatalChance) {
        g_fFatalChance = g_cvFatalChance.FloatValue;
    }
    else if (convar == g_cvFatalHeadChance) {
        g_fFatalHeadChance = g_cvFatalHeadChance.FloatValue;
    }
    else if (convar == g_cvFatalLimbDmg) {
        g_iFatalLimbDmg = g_cvFatalLimbDmg.IntValue;
    }
    else if (convar == g_cvFatalHeadDmg) {
        g_iFatalHeadDmg = g_cvFatalHeadDmg.IntValue;
    }
    else if (convar == g_cvFatalBurnDmg) {
        g_iFatalBurnDmg = g_cvFatalBurnDmg.IntValue;
    }
    else if (convar == g_cvFatalExplosiveDmg) {
        g_iFatalExplosiveDmg = g_cvFatalExplosiveDmg.IntValue;
    }
    else if (convar == g_cvFatalChestStomach) {
        g_iFatalChestStomach = g_cvFatalChestStomach.IntValue;
    }
    else if (convar == g_cvReviveDistanceMetric) {
        g_iReviveDistanceMetric = g_cvReviveDistanceMetric.IntValue;
    }
    else if (convar == g_cvHealAmountMedpack) {
        g_iHealAmountMedpack = g_cvHealAmountMedpack.IntValue;
    }
    else if (convar == g_cvHealAmountPaddles) {
        g_iHealAmountPaddles = g_cvHealAmountPaddles.IntValue;
    }
    else if (convar == g_cvNonMedicHealAmt) {
        g_iNonMedicHealAmt = g_cvNonMedicHealAmt.IntValue;
    }
    else if (convar == g_cvNonMedicReviveHp) {
        g_iNonMedicReviveHp = g_cvNonMedicReviveHp.IntValue;
    }
    else if (convar == g_cvMedicMinorReviveHp) {
        g_iMedicMinorReviveHp = g_cvMedicMinorReviveHp.IntValue;
    }
    else if (convar == g_cvMedicModerateReviveHp) {
        g_iMedicModerateReviveHp = g_cvMedicModerateReviveHp.IntValue;
    }
    else if (convar == g_cvMedicCriticalReviveHp) {
        g_iMedicCriticalReviveHp = g_cvMedicCriticalReviveHp.IntValue;
    }
    else if (convar == g_cvMinorWoundDmg) {
        g_iMinorWoundDmg = g_cvMinorWoundDmg.IntValue;
    }
    else if (convar == g_cvModerateWoundDmg) {
        g_iModerateWoundDmg = g_cvModerateWoundDmg.IntValue;
    }
    else if (convar == g_cvMedicHealSelfMax) {
        g_iMedicHealSelfMax = g_cvMedicHealSelfMax.IntValue;
    }
    else if (convar == g_cvNonMedicHealSelfMax) {
        g_iNonMedicHealSelfMax = g_cvNonMedicHealSelfMax.IntValue;
    }
    else if (convar == g_cvNonMedicMaxHealOther) {
        g_iNonMedicMaxHealOther = g_cvNonMedicMaxHealOther.IntValue;
    }
    else if (convar == g_cvMinorReviveTime) {
        g_iMinorReviveTime = g_cvMinorReviveTime.IntValue;
    }
    else if (convar == g_cvModerateReviveTime) {
        g_iModerateReviveTime = g_cvModerateReviveTime.IntValue;
    }
    else if (convar == g_cvCriticalReviveTime) {
        g_iCriticalReviveTime = g_cvCriticalReviveTime.IntValue;
    }
    else if (convar == g_cvNonMedicReviveTime) {
        g_iNonMedicReviveTime = g_cvNonMedicReviveTime.IntValue;
    }
    else if (convar == g_cvMedpackHealthAmount) {
        g_iMedpackHealthAmount = g_cvMedpackHealthAmount.IntValue;
    }
    // else if (convar == g_cvAmmoResupplyRange) {
    //	g_fAmmoResupplyRange = g_cvAmmoResupplyRange.FloatValue;
    // }
    else if (convar == g_cvResupplyDelay) {
        g_iResupplyDelay = g_cvResupplyDelay.IntValue;
    }
    else if (convar == g_cvSpawnAttackDelay) {
        g_fSpawnAttackDelay = g_cvSpawnAttackDelay.FloatValue;
    }
#endif
#if !DOCTOR
    if (convar == g_cvSpawnAttackDelay)
    {
        g_fSpawnAttackDelay = g_cvSpawnAttackDelay.FloatValue;
    }
#endif
    else if (convar == g_cvDelayTeamIns) {
        g_fDelayTeamIns = g_cvDelayTeamIns.FloatValue;
    }
    // else if (convar == g_cvDelayTeamInsSpecial) {
    //	g_fDelayTeamInsSpecial = g_cvDelayTeamInsSpecial.FloatValue;
    // }
    else if (convar == g_cvLivesTeamInsPlayerMultiplier) {
        g_iLivesTeamInsPlayerMultiplier = g_cvLivesTeamInsPlayerMultiplier.IntValue;
    }
    else if (convar == g_cvCounterChance) {
        g_fCounterChance = g_cvCounterChance.FloatValue;
    }
    else if (convar == g_cvCounterattackType) {
        g_iCounterattackType = g_cvCounterattackType.IntValue;
    }
    else if (convar == g_cvFinalCounterattackType) {
        g_iFinalCounterattackType = g_cvFinalCounterattackType.IntValue;
    }
    else if (convar == g_cvMinCounterDurSec) {
        g_iMinCounterDurSec = g_cvMinCounterDurSec.IntValue;
    }
    else if (convar == g_cvMaxCounterDurSec) {
        g_iMaxCounterDurSec = g_cvMaxCounterDurSec.IntValue;
    }
    else if (convar == g_cvFinalCounterDurSec) {
        g_iFinalCounterDurSec = g_cvFinalCounterDurSec.IntValue;
    }
    else if (convar == g_cvCounterattackVanilla) {
        g_iCounterattackVanilla = g_cvCounterattackVanilla.IntValue;
    }
    else if (convar == g_cvReinforceTime) {
        g_iReinforceTime = g_cvReinforceTime.IntValue;
    }
    else if (convar == g_cvReinforceTimeSubsequent) {
        g_iReinforceTimeSubsequent = g_cvReinforceTimeSubsequent.IntValue;
    }
    else if (convar == g_cvReinforceMultiplier) {
        g_iReinforceMultiplier = g_cvReinforceMultiplier.IntValue;
    }
    else if (convar == g_cvReinforceMltiplierBase) {
        g_iReinforceMltiplierBase = g_cvReinforceMltiplierBase.IntValue;
    }
    else if (convar == g_cvCheckStaticEnemy) {
        g_iCheckStaticEnemy = g_cvCheckStaticEnemy.IntValue;
    }
    else if (convar == g_cvCheckStaticEnemyCounter) {
        g_iCheckStaticEnemyCounter = g_cvCheckStaticEnemyCounter.IntValue;
    }
    else if (convar == g_cvSpawnMaxRange) {
        g_fSpawnMaxRange = g_cvSpawnMaxRange.FloatValue;
    }
    else if (convar == g_cvSpawnPercentNext) {
        g_fSpawnPercentNext = g_cvSpawnPercentNext.FloatValue;
    }
    else if (convar == g_cvSpawnDistFromCapped) {
        g_fSpawnDistFromCapped = g_cvSpawnDistFromCapped.FloatValue;
    }
    else if (convar == g_cvSpawnDistCounterFix) {
        g_fSpawnDistCounterFix = g_cvSpawnDistCounterFix.FloatValue;
    }
    else if (convar == g_cvStopSpawnDist) {
        g_fStopSpawnDist = g_cvStopSpawnDist.FloatValue;
    }
    else if (convar == g_cvCounterattackDuration) {
        g_fCounterattackDuration = g_cvCounterattackDuration.FloatValue;
    }
}

public bool is_too_close(float bot_pos[3])
{
    float player_pos[3];
    float distance_between;
    for (int player_iter = 1; player_iter <= MaxClients; player_iter++)
    {
        if (!IsClientInGame(player_iter))
        {
            continue;
        }
        if (IsFakeClient(player_iter))
        {
            continue;
        }
        GetClientAbsOrigin(player_iter, view_as<float>(player_pos));
        distance_between = GetVectorDistance(bot_pos, player_pos);

        if (distance_between < 1000.0)
        {
            // LogMessage("[GG Respawn] TOO CLOSE triggered // Distance between bawt and %N = %f", player_iter, distance_between);
            return true;
        }
    }

    return false;
}

void respawn_sec_on_counter()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }
        if (IsPlayerAlive(client))
        {
            continue;
        }
        if (IsFakeClient(client))
        {
            continue;
        }
        // they haven't chosen a class yet
        if (StrEqual(g_client_last_classstring[client], "", false))
        {
            continue;
        }
        // yet another class check...
        if (g_playerPickSquad[client] != 1)
        {
            continue;
        }
        // catch those in spec
        int client_team = GetClientTeam(client);
        if (client_team != TEAM_1_SEC)
        {
            continue;
        }
        CreateCounterRespawnTimer(client);
    }
}

public void CreateCounterRespawnTimer(int client)
{
    if (g_iRoundStatus == 0)
    {
        return;
    }
    PrintHintText(client, "Respawning you in 5 seconds");
    CreateTimer(5.25, RespawnPlayerCounter, client);
}

public Action RespawnPlayerEnableDamage(Handle timer, any client)
{
    if (IsValidEntity(client))
    {
        SetEntProp(client, Prop_Data, "m_takedamage", 2, 1);
    }
    return Plugin_Continue;
}

public Action pruneRagdollsAfterCounterStart(Handle Timer, any client)
{
    int playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);
    if (playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
    {
        LogMessage("[BM RESPAWN] removing ragdoll for %N (POST COUNTER START)", client);
        RemoveRagdoll(client);
    }
    return Plugin_Continue;
}

public Action RespawnPlayerCounter(Handle Timer, any client)
{
    // Exit if client is not in game
    if (!IsClientInGame(client))
    {
        return Plugin_Stop;
    }
    if (IsPlayerAlive(client) || g_iRoundStatus == 0)
    {
        return Plugin_Stop;
    }

    // Call forcerespawn fucntion
    SDKCall(g_hForceRespawn, client);

    // Get player's ragdoll
    int playerRag = EntRefToEntIndex(g_iClientRagdolls[client]);

    // Remove network ragdoll
    if (playerRag > 0 && IsValidEdict(playerRag) && IsValidEntity(playerRag))
    {
        LogMessage("[BM RESPAWN] removing ragdoll for %N", client);
        RemoveRagdoll(client);
    }
    // if player died within 5seconds of counterattack start, their ragdoll did not exist, yet
    // this check might also nuke someone's ragdoll who died within the first 5 seconds of a counterattack
    // CreateTimer(4.0, pruneRagdollsAfterCounterStart, client, TIMER_FLAG_NO_MAPCHANGE);

    // take no damage
    SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);
    // re-enable damage 2 sec after respawning
    CreateTimer(2.0, RespawnPlayerEnableDamage, client);

    // Teleport to active counter attack point
    // PrintToServer("[REVIVE_DEBUG] called RespawnPlayerPost for client %N (%d)",client,client);
    if (g_fSecCounterRespawnPosition[0] != 0.0 && g_fSecCounterRespawnPosition[1] != 0.0 && g_fSecCounterRespawnPosition[2] != 0.0)
    {
        float mangle_position[3] = { 0.0, ... };
        mangle_position          = g_fSecCounterRespawnPosition;
        mangle_position[0]       = mangle_position[0] + GetURandomFloat();
        TeleportEntity(client, g_fSecCounterRespawnPosition, NULL_VECTOR, NULL_VECTOR);
    }

    // Reset ragdoll position
    g_fRagdollPosition[client][0] = 0.0;
    g_fRagdollPosition[client][1] = 0.0;
    g_fRagdollPosition[client][2] = 0.0;
    return Plugin_Continue;
}

void medic_bonus_life_check(int client)
{
    if (g_iStatRevives[client] == 0)
    {
        return;
    }
    if (g_iStatRevives[client] % 3 == 0)
    {
        g_iFreeLives[client]++;
        char reward_text[128];
        Format(reward_text, sizeof(reward_text), "Awarded 1 life for reviving 3 players (You now have %i extra lives)", g_iFreeLives[client]);
        PrintToChat(client, "%s", reward_text);
    }
}
