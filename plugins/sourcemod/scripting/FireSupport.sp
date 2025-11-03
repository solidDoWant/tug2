//(C) 2020 rrrfffrrr <rrrfffrrr@naver.com>
// Enhanced by Assistant 2025

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "[INS] Fire support - Enhanced",
    author      = "rrrfffrrr, Assistant",
    description = "Fire support with multiple weapons and team-specific settings",
    version     = "1.2.0",
    url         = "https://github.com/solidDoWant/tug2/tree/master/plugins/sourcemod"
};

#include <sourcemod>
#include <datapack>
#include <float>
#include <sdktools>
#include <sdktools_trace>
#include <sdktools_functions>
#include <sdkhooks>
#include <timers>
#include <morecolors>

const int   TEAM_SPECTATE     = 1;
const int   TEAM_SECURITY     = 2;
const int   TEAM_INSURGENT    = 3;

const float MATH_PI           = 3.14159265359;

const int   MAX_SUPPORT_TYPES = 10;

float       UP_VECTOR[3]      = { -90.0, 0.0, 0.0 };
float       DOWN_VECTOR[3]    = { 90.0, 0.0, 0.0 };

Handle      cGameConfig;
Handle      fCreateRocket;

int         gBeamSprite;

// Support type configuration
enum struct SupportType
{
    char  weapon[64];
    float spread;
    int   shells;
    float delay;
    float duration;          // Total time for all shells to land
    float jitter;            // Random variance in time between shells (0.0 to 1.0)
    char  projectile[64];    // Projectile type to spawn
    char  throwSound[PLATFORM_MAX_PATH];
    char  successSound[PLATFORM_MAX_PATH];
    char  failSound[PLATFORM_MAX_PATH];
    char  successMessage[256];
    char  failMessage[256];
    char  projectileMessage[256];    // Message displayed when each projectile fires
    char  completionMessage[256];    // Message displayed when fire support completes (format: {kills} {player_name})
    int   securityCount;             // Usage limit for Security team (0 = unlimited)
    float securityDelay;             // Cooldown for Security team
    int   insurgentCount;            // Usage limit for Insurgent team (0 = unlimited)
    float insurgentDelay;            // Cooldown for Insurgent team
    bool  spawnSmoke;                // Whether to spawn smoke on impact
    char  smokeType[64];             // Type of smoke grenade to spawn (e.g., "smokegrenade_projectile")
}

SupportType gSupportTypes[MAX_SUPPORT_TYPES];
int         gNumSupportTypes;

ConVar      gCvarClass;
ConVar      gCvarEnableCmd;
ConVar      gCvarEnableWeapon;

bool        IsEnabled[MAXPLAYERS + 1];
bool        IsEnabledTeam[4][MAX_SUPPORT_TYPES];            // [team][supportType] - per-type cooldown tracking
int         CountAvailableSupport[4][MAX_SUPPORT_TYPES];    // [team][supportType]

// Active fire support tracking
// Note: Entity references accumulate during the round as entities are created.
// When entities die naturally (rockets explode, smoke dissipates), the references
// remain in the arrays until round cleanup. This is intentional - the memory cost
// is negligible (~4 bytes per reference, typically <1KB per round), and using
// OnEntityDestroyed() to clean eagerly would add ~1000 callbacks/second overhead.
// Arrays are cleared on round start, which is sufficient for normal gameplay.
ArrayList   gActiveRockets;          // List of active rocket entity references
ArrayList   gActiveSmokeGrenades;    // List of active smoke grenade entity references
int         gCurrentRound;           // Current round number, incremented on each round_start

// Pending fire support triggered by grenades
// Stores DataPacks indexed by grenade entity index
// Fire support triggers when grenade becomes stationary (velocity < threshold for sufficient time)
Handle      gPendingFireSupport[2048];    // Max entities = 2048

// Grenade stationary tracking
// Stores how many consecutive checks the grenade has been stationary
// When this reaches STATIONARY_CHECKS_REQUIRED, fire support triggers
int         gGrenadeStationaryChecks[2048];    // Consecutive stationary checks per grenade

const float STATIONARY_VELOCITY_THRESHOLD = 10.0;    // Units per second - grenade considered stationary below this
const int   STATIONARY_CHECKS_REQUIRED    = 3;       // Number of consecutive 0.1s checks (0.3s total) before triggering

// Fire support target offset
// Raises the target point above ground level to ensure proper sky tracing and avoid ground clipping
// 20 units ≈ 15 inches (38cm) - roughly knee height, well above ground but below player center
const float FIRE_SUPPORT_HEIGHT_OFFSET    = 20.0;

// Fire support kill tracking
// Maps rocket entity index to fire support info (client, supportType, sessionIndex)
// Used to attribute kills to the correct fire support session and track kill counts
Handle      gRocketFireSupportInfo[2048];    // DataPack: client, supportType, sessionIndex

// Active fire support sessions
// Tracks ongoing fire support calls to count kills
// Structure: ArrayList of DataPacks containing: client, team, supportType, enemyKills, friendlyKills, roundNumber
ArrayList   gActiveFireSupport;

public void OnPluginStart()
{
    cGameConfig = LoadGameConfigFile("insurgency.games");
    if (cGameConfig == INVALID_HANDLE)
    {
        SetFailState("Fatal Error: Missing File \"insurgency.games\"!");
    }

    StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetFromConf(cGameConfig, SDKConf_Signature, "CBaseRocketMissile::CreateRocketMissile");
    PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef);
    PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_ByValue);
    fCreateRocket = EndPrepSDKCall();
    if (fCreateRocket == INVALID_HANDLE)
    {
        SetFailState("Fatal Error: Unable to find CBaseRocketMissile::CreateRocketMissile");
    }

    // ConVars
    gCvarClass        = CreateConVar("sm_firesupport_class", "", "Set fire support specialist class. Leave empty to allow all classes.", FCVAR_PROTECTED);
    gCvarEnableCmd    = CreateConVar("sm_firesupport_enable_cmd", "0", "Player can call fire support using sm_firesupport_call.", FCVAR_PROTECTED);
    gCvarEnableWeapon = CreateConVar("sm_firesupport_enable_weapon", "1", "Player can call fire support using weapon.", FCVAR_PROTECTED);

    RegConsoleCmd("sm_firesupport_call", CmdCallFS, "Call fire support where you looking at.", 0);
    RegAdminCmd("sm_firesupport_ad_call", CmdCallAFS, 0);
    RegAdminCmd("sm_firesupport_reload", CmdReloadConfig, ADMFLAG_CONFIG, "Reload fire support configuration");

    HookEvent("weapon_fire", Event_WeaponFire);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    HookEvent("player_death", Event_PlayerDeath);

    // Initialize tracking arrays
    gActiveRockets       = new ArrayList();
    gActiveSmokeGrenades = new ArrayList();
    gActiveFireSupport   = new ArrayList();
    gCurrentRound        = 0;

    // Initialize pending fire support array and stationary tracking
    for (int i = 0; i < sizeof(gPendingFireSupport); i++)
    {
        gPendingFireSupport[i]      = null;
        gGrenadeStationaryChecks[i] = 0;
        gRocketFireSupportInfo[i]   = null;
    }

    InitSupportCount();
    LoadSupportConfig();
}

public void OnMapStart()
{
    gBeamSprite = PrecacheModel("sprites/laserbeam.vmt");
    PrecacheSounds();

    // Clear tracking arrays on map start (arrays are already initialized in OnPluginStart)
    if (gActiveRockets != null)
    {
        gActiveRockets.Clear();
    }
    if (gActiveSmokeGrenades != null)
    {
        gActiveSmokeGrenades.Clear();
    }
    gCurrentRound = 0;

    // Clear pending fire support and stationary tracking
    for (int i = 0; i < sizeof(gPendingFireSupport); i++)
    {
        if (gPendingFireSupport[i] != null)
        {
            delete gPendingFireSupport[i];
            gPendingFireSupport[i] = null;
        }
        gGrenadeStationaryChecks[i] = 0;
    }
}

public void OnEntityDestroyed(int entity)
{
    // Check if this entity has pending fire support
    if (entity >= 0 && entity < sizeof(gPendingFireSupport))
    {
        if (gPendingFireSupport[entity] != null)
        {
            // Grenade destroyed before becoming stationary (e.g., hit by explosion, removed by game)
            // Clean up without triggering fire support
            DataPack pack = view_as<DataPack>(gPendingFireSupport[entity]);
            delete pack;
            gPendingFireSupport[entity]      = null;
            gGrenadeStationaryChecks[entity] = 0;
        }
    }

    // Check if this entity has rocket fire support info
    if (entity >= 0 && entity < sizeof(gRocketFireSupportInfo))
    {
        if (gRocketFireSupportInfo[entity] != null)
        {
            // Rocket destroyed, clean up the associated info
            DataPack pack = view_as<DataPack>(gRocketFireSupportInfo[entity]);
            delete pack;
            gRocketFireSupportInfo[entity] = null;
        }
    }

    // Note: Fire support is triggered by Timer_TrackGrenadePosition when grenade becomes stationary,
    // not by entity destruction. This handler just cleans up if grenade is destroyed prematurely.
}

public void OnClientConnected(int client)
{
    IsEnabled[client] = false;
}

void LoadSupportConfig()
{
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/firesupport.cfg");

    KeyValues kv = new KeyValues("FireSupport");

    if (!kv.ImportFromFile(configPath))
    {
        LogError("Failed to load config file: %s - Creating default config", configPath);
        CreateDefaultConfig(configPath);
        delete kv;
        kv = new KeyValues("FireSupport");
        kv.ImportFromFile(configPath);
    }

    gNumSupportTypes = 0;

    if (kv.GotoFirstSubKey())
    {
        do
        {
            if (gNumSupportTypes >= MAX_SUPPORT_TYPES)
            {
                LogError("Maximum support types (%d) reached, ignoring remaining entries", MAX_SUPPORT_TYPES);
                break;
            }

            kv.GetString("weapon", gSupportTypes[gNumSupportTypes].weapon, 64, "");
            gSupportTypes[gNumSupportTypes].spread   = kv.GetFloat("spread", 800.0);
            gSupportTypes[gNumSupportTypes].shells   = kv.GetNum("shells", 20);
            gSupportTypes[gNumSupportTypes].delay    = kv.GetFloat("delay", 10.0);
            gSupportTypes[gNumSupportTypes].duration = kv.GetFloat("duration", 20.0);
            gSupportTypes[gNumSupportTypes].jitter   = kv.GetFloat("jitter", 0.0);
            kv.GetString("projectile", gSupportTypes[gNumSupportTypes].projectile, 64, "rocket_rpg7");
            kv.GetString("throw_sound", gSupportTypes[gNumSupportTypes].throwSound, PLATFORM_MAX_PATH, "");
            kv.GetString("success_sound", gSupportTypes[gNumSupportTypes].successSound, PLATFORM_MAX_PATH, "");
            kv.GetString("fail_sound", gSupportTypes[gNumSupportTypes].failSound, PLATFORM_MAX_PATH, "");
            kv.GetString("success_message", gSupportTypes[gNumSupportTypes].successMessage, 256, "");
            kv.GetString("fail_message", gSupportTypes[gNumSupportTypes].failMessage, 256, "");
            kv.GetString("projectile_message", gSupportTypes[gNumSupportTypes].projectileMessage, 256, "");
            kv.GetString("completion_message", gSupportTypes[gNumSupportTypes].completionMessage, 256, "");
            gSupportTypes[gNumSupportTypes].securityCount  = kv.GetNum("security_count", 0);
            gSupportTypes[gNumSupportTypes].securityDelay  = kv.GetFloat("security_delay", 0.0);
            gSupportTypes[gNumSupportTypes].insurgentCount = kv.GetNum("insurgent_count", 0);
            gSupportTypes[gNumSupportTypes].insurgentDelay = kv.GetFloat("insurgent_delay", 0.0);
            gSupportTypes[gNumSupportTypes].spawnSmoke     = view_as<bool>(kv.GetNum("spawn_smoke", 0));
            kv.GetString("smoke_type", gSupportTypes[gNumSupportTypes].smokeType, 64, "grenade_m18");

            LogMessage("Loaded support type %d: weapon=%s, spread=%.1f, shells=%d, delay=%.1f, duration=%.1f, jitter=%.2f, projectile=%s, sec_count=%d, sec_delay=%.1f, ins_count=%d, ins_delay=%.1f, spawn_smoke=%d, smoke_type=%s",
                       gNumSupportTypes,
                       gSupportTypes[gNumSupportTypes].weapon,
                       gSupportTypes[gNumSupportTypes].spread,
                       gSupportTypes[gNumSupportTypes].shells,
                       gSupportTypes[gNumSupportTypes].delay,
                       gSupportTypes[gNumSupportTypes].duration,
                       gSupportTypes[gNumSupportTypes].jitter,
                       gSupportTypes[gNumSupportTypes].projectile,
                       gSupportTypes[gNumSupportTypes].securityCount,
                       gSupportTypes[gNumSupportTypes].securityDelay,
                       gSupportTypes[gNumSupportTypes].insurgentCount,
                       gSupportTypes[gNumSupportTypes].insurgentDelay,
                       gSupportTypes[gNumSupportTypes].spawnSmoke,
                       gSupportTypes[gNumSupportTypes].smokeType);

            gNumSupportTypes++;
        }
        while (kv.GotoNextKey());
        kv.GoBack();
    }

    delete kv;

    if (gNumSupportTypes == 0)
    {
        LogError("No support types loaded! Plugin may not function correctly.");
    }
}

void CreateDefaultConfig(const char[] path)
{
    KeyValues kv = new KeyValues("FireSupport");

    // Security Forces - M18 US Smoke Grenade (limited uses, no cooldown)
    kv.JumpToKey("security_smoke", true);
    kv.SetString("weapon", "m18_us");
    kv.SetFloat("spread", 600.0);
    kv.SetNum("shells", 15);
    kv.SetFloat("delay", 8.0);
    kv.SetFloat("duration", 20.0);
    kv.SetFloat("jitter", 0.3);
    kv.SetString("projectile", "rocket_rpg7");
    kv.SetString("throw_sound", "weapons/smokegrenade/smoke_emit.wav");
    kv.SetString("success_sound", "weapons/m203/m203_reload_clipin.wav");
    kv.SetString("fail_sound", "buttons/button11.wav");
    kv.SetString("success_message", "[Fire Support] Artillery strike inbound on your position!");
    kv.SetString("fail_message", "[Fire Support] Unable to call artillery - invalid target location!");
    kv.SetString("projectile_message", "");                                                                                                   // No message by default
    kv.SetString("completion_message", "{olivedrab}[Fire Support]{default} Strike complete: {1} enemies, {3} friendlies - called by {2}");    // Format: {1}=enemies {2}=player {3}=friendlies
    kv.SetNum("security_count", 5);                                                                                                           // Security: 5 uses per round
    kv.SetFloat("security_delay", 0.0);                                                                                                       // Security: no cooldown
    kv.SetNum("insurgent_count", 0);                                                                                                          // Insurgent: unlimited (can't normally get this weapon)
    kv.SetFloat("insurgent_delay", 0.0);                                                                                                      // Insurgent: no cooldown
    kv.SetNum("spawn_smoke", 1);                                                                                                              // Spawn smoke on impact
    kv.SetString("smoke_type", "grenade_m18");
    kv.GoBack();

    // Insurgent Forces - M18 INS Smoke Grenade (unlimited uses, long cooldown)
    kv.JumpToKey("insurgent_smoke", true);
    kv.SetString("weapon", "m18_ins");
    kv.SetFloat("spread", 700.0);
    kv.SetNum("shells", 18);
    kv.SetFloat("delay", 10.0);
    kv.SetFloat("duration", 25.0);
    kv.SetFloat("jitter", 0.3);
    kv.SetString("projectile", "rocket_rpg7");
    kv.SetString("throw_sound", "weapons/smokegrenade/smoke_emit.wav");
    kv.SetString("success_sound", "weapons/c4/c4_beep1.wav");
    kv.SetString("fail_sound", "buttons/button11.wav");
    kv.SetString("success_message", "[Fire Support] Mortar strike authorized!");
    kv.SetString("fail_message", "[Fire Support] Cannot request mortar support - no line of sight!");
    kv.SetString("projectile_message", "");                                                                                              // No message by default
    kv.SetString("completion_message", "{deeppink}ICOM Chatter:{default} Mortar complete: {1} infidels, {3} brothers killed by {2}");    // Format: {1}=enemies {2}=player {3}=friendlies
    kv.SetNum("security_count", 0);                                                                                                      // Security: unlimited (can't normally get this weapon)
    kv.SetFloat("security_delay", 0.0);                                                                                                  // Security: no cooldown
    kv.SetNum("insurgent_count", 0);                                                                                                     // Insurgent: unlimited uses
    kv.SetFloat("insurgent_delay", 120.0);                                                                                               // Insurgent: 120 second cooldown
    kv.SetNum("spawn_smoke", 1);                                                                                                         // Spawn smoke on impact
    kv.SetString("smoke_type", "grenade_m18");
    kv.GoBack();

    kv.Rewind();
    kv.ExportToFile(path);
    delete kv;

    LogMessage("Created default config at: %s", path);
}

void PrecacheSounds()
{
    for (int i = 0; i < gNumSupportTypes; i++)
    {
        if (!StrEqual(gSupportTypes[i].throwSound, ""))
        {
            PrecacheSound(gSupportTypes[i].throwSound, true);
        }
        if (!StrEqual(gSupportTypes[i].successSound, ""))
        {
            PrecacheSound(gSupportTypes[i].successSound, true);
        }
        if (!StrEqual(gSupportTypes[i].failSound, ""))
        {
            PrecacheSound(gSupportTypes[i].failSound, true);
        }
    }
}

public Action Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!gCvarEnableWeapon.BoolValue)
    {
        return Plugin_Handled;
    }

    int team = GetClientTeam(client);

    // Check if client is valid and on a valid team
    if ((team != TEAM_SECURITY && team != TEAM_INSURGENT) || !IsPlayerAlive(client))
    {
        return Plugin_Handled;
    }

    // For human players, check the IsEnabled flag
    // For bots, skip this check (bots don't trigger Event_PlayerPickSquad)
    if (!IsFakeClient(client) && !IsEnabled[client])
    {
        return Plugin_Handled;
    }

    char weapon[64];
    GetClientWeapon(client, weapon, sizeof(weapon));

    // Find matching support type
    int supportType = -1;
    for (int i = 0; i < gNumSupportTypes; i++)
    {
        if (StrContains(weapon, gSupportTypes[i].weapon, false) != -1)
        {
            supportType = i;
            break;
        }
    }

    if (supportType == -1)
    {
        return Plugin_Handled;
    }

    // Check if this support type is on cooldown
    if (!IsEnabledTeam[team][supportType])
    {
        return Plugin_Handled;
    }

    // Check team-specific limits for this support type
    int maxCount = (team == TEAM_SECURITY) ? gSupportTypes[supportType].securityCount : gSupportTypes[supportType].insurgentCount;
    if (maxCount > 0 && CountAvailableSupport[team][supportType] < 1)
    {
        return Plugin_Handled;
    }

    // Play throw sound
    PlaySoundToTeam(team, gSupportTypes[supportType].throwSound);

    // Find the grenade entity that was just thrown by this client
    // We need to wait a frame for the entity to be created
    DataPack pack = new DataPack();
    pack.WriteCell(client);
    pack.WriteCell(team);
    pack.WriteCell(supportType);

    CreateTimer(0.1, Timer_FindThrownGrenade, pack, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Continue;
}

// Timer to find the grenade that was just thrown
public Action Timer_FindThrownGrenade(Handle timer, DataPack pack)
{
    pack.Reset();
    int client        = pack.ReadCell();
    int team          = pack.ReadCell();
    int supportType   = pack.ReadCell();

    // Search for the most recent grenade entity owned by this client
    int grenadeEntity = -1;
    int maxEntities   = GetMaxEntities();

    for (int entity = MaxClients + 1; entity < maxEntities; entity++)
    {
        if (!IsValidEntity(entity))
            continue;

        char classname[64];
        GetEntityClassname(entity, classname, sizeof(classname));

        // Check if this is a grenade projectile
        if (StrContains(classname, "grenade_", false) != 0)
            continue;

        // Check if this grenade's owner is our client
        int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
        if (owner != client)
            continue;

        // Found a grenade owned by this client
        grenadeEntity = entity;
        break;    // Use the first one we find (most likely the one just thrown)
    }

    if (grenadeEntity == -1)
    {
        // Couldn't find the grenade, fire support fails
        PlaySoundToTeam(team, gSupportTypes[supportType].failSound);
        PrintMessageToTeam(team, gSupportTypes[supportType].failMessage);
        delete pack;
        return Plugin_Handled;
    }

    // Store the fire support data associated with this grenade
    // When the grenade detonates (OnEntityDestroyed), we'll trigger fire support
    DataPack grenadeData = new DataPack();
    grenadeData.WriteCell(client);
    grenadeData.WriteCell(team);
    grenadeData.WriteCell(supportType);

    // Store current grenade position (will update in a repeating timer)
    // NOTE: We add +20 units to Z coordinate for the following reasons:
    // 1. Avoids tracing through the grenade entity itself when checking for sky
    // 2. Prevents ground clipping issues when grenade is at exact ground level
    // 3. Ensures the sky trace starts from a point clearly above ground
    // The stored position will be used by GetSkyPos() to trace upward to find the skybox
    float pos[3];
    GetEntPropVector(grenadeEntity, Prop_Send, "m_vecOrigin", pos);
    pos[2] += FIRE_SUPPORT_HEIGHT_OFFSET;    // Raise target point above grenade
    grenadeData.WriteFloat(pos[0]);
    grenadeData.WriteFloat(pos[1]);
    grenadeData.WriteFloat(pos[2]);

    gPendingFireSupport[grenadeEntity] = view_as<Handle>(grenadeData);

    // Start a repeating timer to track grenade position until it detonates
    DataPack trackPack                 = new DataPack();
    trackPack.WriteCell(grenadeEntity);
    CreateTimer(0.1, Timer_TrackGrenadePosition, trackPack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    delete pack;
    return Plugin_Handled;
}

// Timer to continuously update the grenade's position and detect when it becomes stationary
public Action Timer_TrackGrenadePosition(Handle timer, DataPack pack)
{
    pack.Reset();
    int grenadeEntity = pack.ReadCell();

    // Check if grenade still exists
    if (!IsValidEntity(grenadeEntity))
    {
        delete pack;
        return Plugin_Stop;
    }

    // Check if we still have fire support pending for this grenade
    if (gPendingFireSupport[grenadeEntity] == null)
    {
        delete pack;
        return Plugin_Stop;
    }

    // Update the stored position
    DataPack grenadeData = view_as<DataPack>(gPendingFireSupport[grenadeEntity]);

    // Read existing data
    grenadeData.Reset();
    int   client      = grenadeData.ReadCell();
    int   team        = grenadeData.ReadCell();
    int   supportType = grenadeData.ReadCell();
    float lastPos[3];
    lastPos[0] = grenadeData.ReadFloat();
    lastPos[1] = grenadeData.ReadFloat();
    lastPos[2] = grenadeData.ReadFloat();

    // Get current position
    float pos[3];
    GetEntPropVector(grenadeEntity, Prop_Send, "m_vecOrigin", pos);

    // Calculate distance moved since last check (0.1 seconds ago)
    // Note: lastPos already has offset, but pos doesn't yet, so we calculate
    // movement using raw positions before applying the offset
    float dx       = pos[0] - lastPos[0];
    float dy       = pos[1] - lastPos[1];
    float dz       = (pos[2] + FIRE_SUPPORT_HEIGHT_OFFSET) - lastPos[2];    // Compare with offset applied
    float distance = SquareRoot(dx * dx + dy * dy + dz * dz);

    // Calculate effective velocity (distance / time)
    // Timer runs every 0.1s, so multiply by 10 to get units/second
    float speed    = distance * 10.0;

    // Apply offset to fire support target position (see notes in Timer_FindThrownGrenade)
    // This raises the target point above ground level for proper sky tracing
    pos[2] += FIRE_SUPPORT_HEIGHT_OFFSET;

    // Check if grenade is stationary
    if (speed < STATIONARY_VELOCITY_THRESHOLD)
    {
        gGrenadeStationaryChecks[grenadeEntity]++;

        // If grenade has been stationary for sufficient time, trigger fire support
        if (gGrenadeStationaryChecks[grenadeEntity] >= STATIONARY_CHECKS_REQUIRED)
        {
            // Grenade is settled! Trigger fire support
            delete grenadeData;
            gPendingFireSupport[grenadeEntity]      = null;
            gGrenadeStationaryChecks[grenadeEntity] = 0;

            // Trigger fire support at the grenade's position
            bool validLocation                      = CallFireSupport(client, pos, supportType, team);

            if (validLocation)
            {
                // Success
                PlaySoundToTeam(team, gSupportTypes[supportType].successSound);
                PrintMessageToTeam(team, gSupportTypes[supportType].successMessage);

                // Decrease count if limited
                int maxCount = (team == TEAM_SECURITY) ? gSupportTypes[supportType].securityCount : gSupportTypes[supportType].insurgentCount;
                if (maxCount > 0)
                {
                    CountAvailableSupport[team][supportType]--;

                    // Print remaining usage to team
                    int  remaining = CountAvailableSupport[team][supportType];
                    char remainingMsg[128];
                    Format(remainingMsg, sizeof(remainingMsg), "{olivedrab}[Fire Support]{default} %d use(s) remaining for this strike type.", remaining);
                    PrintMessageToTeam(team, remainingMsg);
                }

                // Apply cooldown for this specific support type
                float cooldown = (team == TEAM_SECURITY) ? gSupportTypes[supportType].securityDelay : gSupportTypes[supportType].insurgentDelay;
                if (cooldown > 0.0)
                {
                    IsEnabledTeam[team][supportType] = false;

                    // Use DataPack to pass both team and supportType to timer
                    DataPack cooldownPack            = new DataPack();
                    cooldownPack.WriteCell(team);
                    cooldownPack.WriteCell(supportType);
                    CreateTimer(cooldown, Timer_EnableTeamSupport, cooldownPack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
                }
            }
            else
            {
                // Failure
                PlaySoundToTeam(team, gSupportTypes[supportType].failSound);
                PrintMessageToTeam(team, gSupportTypes[supportType].failMessage);
            }

            // Stop tracking this grenade
            delete pack;
            return Plugin_Stop;
        }
    }
    else
    {
        // Grenade is still moving, reset the stationary counter
        gGrenadeStationaryChecks[grenadeEntity] = 0;
    }

    // Recreate the pack with updated position
    delete grenadeData;
    grenadeData = new DataPack();
    grenadeData.WriteCell(client);
    grenadeData.WriteCell(team);
    grenadeData.WriteCell(supportType);
    grenadeData.WriteFloat(pos[0]);
    grenadeData.WriteFloat(pos[1]);
    grenadeData.WriteFloat(pos[2]);

    gPendingFireSupport[grenadeEntity] = view_as<Handle>(grenadeData);

    // Reset pack position for next iteration
    pack.Reset();

    return Plugin_Continue;
}

// Timer callback to process fire support after trigger delay (OLD - now handled by OnEntityDestroyed)
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // Clean up all active fire support from previous round
    CleanupActiveFireSupport();

    // Reset support counts for new round
    InitSupportCount();

    // Increment round number - this will cause all old timers to self-terminate
    gCurrentRound++;

    return Plugin_Continue;
}

public Action Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    char template[64];
    event.GetString("class_template", template, sizeof(template), "");
    char class[64];
    gCvarClass.GetString(class, sizeof(class));

    // If class CVar is empty or not set, allow all classes to use fire support
    if (StrEqual(class, ""))
    {
        IsEnabled[client] = true;
    }
    else {
        IsEnabled[client] = (StrContains(template, class, false) > -1);
    }

    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim   = GetClientOfUserId(event.GetInt("userid"));

    // Check if this kill was from a fire support rocket
    // We need to match both the weapon AND the attacker (owner of the rocket)
    for (int i = 0; i < sizeof(gRocketFireSupportInfo); i++)
    {
        if (gRocketFireSupportInfo[i] != null)
        {
            DataPack pack = view_as<DataPack>(gRocketFireSupportInfo[i]);
            pack.Reset();
            int  rocketOwner   = pack.ReadCell();    // Client who called fire support
            int  supportType   = pack.ReadCell();
            int  sessionIndex  = pack.ReadCell();

            // Match if: weapon matches projectile type AND attacker matches rocket owner
            bool weaponMatches = (StrContains(weapon, gSupportTypes[supportType].projectile, false) != -1 || StrContains(weapon, "rpg", false) != -1 || StrContains(weapon, "rocket", false) != -1 || StrContains(weapon, "grenade", false) != -1);

            if (weaponMatches && attacker == rocketOwner)
            {
                // Get the session directly using sessionIndex
                if (sessionIndex >= 0 && sessionIndex < gActiveFireSupport.Length)
                {
                    DataPack sessionPack = view_as<DataPack>(gActiveFireSupport.Get(sessionIndex));
                    sessionPack.Reset();
                    int sessionClient      = sessionPack.ReadCell();
                    int sessionTeam        = sessionPack.ReadCell();
                    int sessionSupportType = sessionPack.ReadCell();
                    int enemyKills         = sessionPack.ReadCell();
                    int friendlyKills      = sessionPack.ReadCell();
                    int sessionRound       = sessionPack.ReadCell();

                    // Verify this is the correct session (round check)
                    if (sessionRound == gCurrentRound)
                    {
                        // Determine if this is an enemy or friendly kill
                        bool isEnemyKill = false;
                        if (ValidateClient(victim))
                        {
                            int victimTeam = GetClientTeam(victim);
                            isEnemyKill    = (victimTeam != sessionTeam);
                        }

                        // Increment appropriate kill count
                        if (isEnemyKill)
                        {
                            enemyKills++;
                        }
                        else
                        {
                            friendlyKills++;
                        }

                        delete sessionPack;

                        DataPack newPack = new DataPack();
                        newPack.WriteCell(sessionClient);
                        newPack.WriteCell(sessionTeam);
                        newPack.WriteCell(sessionSupportType);
                        newPack.WriteCell(enemyKills);
                        newPack.WriteCell(friendlyKills);
                        newPack.WriteCell(sessionRound);

                        gActiveFireSupport.Set(sessionIndex, newPack);
                    }
                }
                break;
            }
        }
    }

    return Plugin_Continue;
}

Action CmdCallFS(int client, int args)
{
    if (!gCvarEnableCmd.BoolValue)
    {
        return Plugin_Handled;
    }

    int team = GetClientTeam(client);
    if (!IsEnabled[client] || (team != TEAM_SECURITY && team != TEAM_INSURGENT) || !IsPlayerAlive(client))
    {
        return Plugin_Handled;
    }

    // Use first support type for command (index 0)
    int supportType = 0;
    if (gNumSupportTypes < 1)
    {
        CPrintToChat(client, "{olivedrab}[Fire Support]{default} No fire support types configured.");
        return Plugin_Handled;
    }

    if (!IsEnabledTeam[team][supportType])
    {
        CPrintToChat(client, "{olivedrab}[Fire Support]{default} Fire support on cooldown.");
        return Plugin_Handled;
    }

    int maxCount = (team == TEAM_SECURITY) ? gSupportTypes[supportType].securityCount : gSupportTypes[supportType].insurgentCount;
    if (maxCount > 0 && CountAvailableSupport[team][supportType] < 1)
    {
        CPrintToChat(client, "{olivedrab}[Fire Support]{default} No fire support available.");
        return Plugin_Handled;
    }

    float ground[3];
    if (GetAimGround(client, ground))
    {
        // Raise target point above ground (same offset used for grenade-triggered fire support)
        ground[2] += FIRE_SUPPORT_HEIGHT_OFFSET;

        if (CallFireSupport(client, ground, supportType, team))
        {
            if (maxCount > 0)
            {
                CountAvailableSupport[team][supportType]--;

                // Print remaining usage
                int remaining = CountAvailableSupport[team][supportType];
                CPrintToChat(client, "{olivedrab}[Fire Support]{default} %d use(s) remaining for this strike type.", remaining);
            }

            float cooldown = (team == TEAM_SECURITY) ? gSupportTypes[supportType].securityDelay : gSupportTypes[supportType].insurgentDelay;
            if (cooldown > 0.0)
            {
                IsEnabledTeam[team][supportType] = false;

                DataPack pack                    = new DataPack();
                pack.WriteCell(team);
                pack.WriteCell(supportType);
                CreateTimer(cooldown, Timer_EnableTeamSupport, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
            }
        }
    }
    return Plugin_Handled;
}

Action CmdCallAFS(int client, int args)
{
    float ground[3];
    if (GetAimGround(client, ground))
    {
        ground[2] += FIRE_SUPPORT_HEIGHT_OFFSET;
        int team = GetClientTeam(client);
        CallFireSupport(client, ground, 0, team);
    }
    return Plugin_Handled;
}

Action CmdReloadConfig(int client, int args)
{
    LoadSupportConfig();
    PrecacheSounds();
    ReplyToCommand(client, "{olivedrab}[Fire Support]{default} Configuration reloaded. %d support types loaded.", gNumSupportTypes);
    return Plugin_Handled;
}

void PlaySoundToTeam(int team, const char[] sound)
{
    if (StrEqual(sound, ""))
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == team)
        {
            EmitSoundToClient(i, sound, SOUND_FROM_PLAYER, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
        }
    }
}

void PrintMessageToTeam(int team, const char[] message)
{
    if (StrEqual(message, ""))
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == team)
        {
            CPrintToChat(i, message);
        }
    }
}

/// FireSupport
// Coordinate System Explanation:
// - ground[3]: Target position (already has +20 Z offset applied by caller)
// - GetSkyPos() traces upward from ground[3] to find the skybox ceiling
// - sky[3]: Position at the skybox (top of the map)
// - Missiles spawn at sky[3] and fall down toward ground[3]
// - The -20 offset on sky[2] prevents missiles from spawning too close to skybox ceiling
public bool CallFireSupport(int client, float ground[3], int supportType, int team)
{
    if (supportType < 0 || supportType >= gNumSupportTypes)
    {
        return false;
    }

    float sky[3];
    if (GetSkyPos(client, ground, sky))
    {
        // Lower missile spawn point slightly below skybox ceiling to prevent clipping
        sky[2] -= FIRE_SUPPORT_HEIGHT_OFFSET;

        float    time        = gSupportTypes[supportType].delay;
        int      shells      = gSupportTypes[supportType].shells;
        float    spread      = gSupportTypes[supportType].spread;
        float    duration    = gSupportTypes[supportType].duration;
        float    jitter      = gSupportTypes[supportType].jitter;

        // Create fire support session for kill tracking
        DataPack sessionPack = new DataPack();
        sessionPack.WriteCell(client);
        sessionPack.WriteCell(team);
        sessionPack.WriteCell(supportType);
        sessionPack.WriteCell(0);    // Initial enemy kill count
        sessionPack.WriteCell(0);    // Initial friendly kill count
        sessionPack.WriteCell(gCurrentRound);
        gActiveFireSupport.Push(sessionPack);
        int      sessionIndex = gActiveFireSupport.Length - 1;

        DataPack pack         = new DataPack();
        pack.WriteCell(client);
        pack.WriteCell(shells);
        pack.WriteCell(shells);    // Store original shell count for timing calculations
        pack.WriteFloat(sky[0]);
        pack.WriteFloat(sky[1]);
        pack.WriteFloat(sky[2]);
        pack.WriteFloat(spread);
        pack.WriteFloat(duration);
        pack.WriteFloat(jitter);
        pack.WriteCell(supportType);
        pack.WriteCell(gCurrentRound);    // Store round number for validation
        pack.WriteCell(team);
        pack.WriteCell(sessionIndex);    // Index into gActiveFireSupport for this session

        ShowDelayEffect(ground, sky, time);

        // First shell fires after the initial delay, subsequent shells use timeBetweenShells
        // Note: No TIMER_DATA_HNDL_CLOSE because we reuse the pack for subsequent shells
        CreateTimer(time, Timer_LaunchMissile, pack, TIMER_FLAG_NO_MAPCHANGE);
        return true;
    }

    return false;
}

void InitSupportCount()
{
    // Initialize counts for each support type based on their individual settings
    for (int i = 0; i < MAX_SUPPORT_TYPES; i++)
    {
        if (i < gNumSupportTypes)
        {
            CountAvailableSupport[TEAM_SECURITY][i]  = gSupportTypes[i].securityCount;
            CountAvailableSupport[TEAM_INSURGENT][i] = gSupportTypes[i].insurgentCount;
            IsEnabledTeam[TEAM_SECURITY][i]          = true;
            IsEnabledTeam[TEAM_INSURGENT][i]         = true;
        }
        else {
            // Initialize unused slots
            CountAvailableSupport[TEAM_SECURITY][i]  = 0;
            CountAvailableSupport[TEAM_INSURGENT][i] = 0;
            IsEnabledTeam[TEAM_SECURITY][i]          = true;
            IsEnabledTeam[TEAM_INSURGENT][i]         = true;
        }
    }
}

void ShowDelayEffect(float ground[3], float sky[3], float time)
{
    TE_SetupBeamPoints(ground, sky, gBeamSprite, 0, 0, 1, time, 1.0, 0.0, 5, 0.0, { 255, 0, 0, 255 }, 10);
    TE_SendToAll();
    TE_SetupBeamRingPoint(ground, 500.0, 0.0, gBeamSprite, 0, 0, 1, time, 5.0, 0.0, { 255, 0, 0, 255 }, 10, 0);
    TE_SendToAll();
}

public Action Timer_LaunchMissile(Handle timer, DataPack pack)
{
    pack.Reset();
    int         client = pack.ReadCell();

    DataPackPos cursor = pack.Position;
    int         shells = pack.ReadCell();
    pack.Position      = cursor;
    pack.WriteCell(shells - 1);

    int   originalShells = pack.ReadCell();    // Read original shell count for timing

    float baseX          = pack.ReadFloat();
    float baseY          = pack.ReadFloat();
    float baseZ          = pack.ReadFloat();
    float spread         = pack.ReadFloat();
    float duration       = pack.ReadFloat();
    float jitter         = pack.ReadFloat();
    int   supportType    = pack.ReadCell();
    int   fireRound      = pack.ReadCell();    // Read the round this fire support was created in
    int   team           = pack.ReadCell();
    int   sessionIndex   = pack.ReadCell();    // Index into gActiveFireSupport for this session

    // Check if this fire support is from a previous round
    if (fireRound != gCurrentRound)
    {
        delete pack;    // Manually close the pack since we're stopping early
        return Plugin_Stop;
    }

    float dir    = GetURandomFloat() * MATH_PI * 8.0;
    float length = GetURandomFloat() * spread;

    float pos[3];
    pos[0] = baseX + Cosine(dir) * length;
    pos[1] = baseY + Sine(dir) * length;
    pos[2] = baseZ;

    if (ValidateClient(client))
    {
        int rocket = SDKCall(fCreateRocket, client, gSupportTypes[supportType].projectile, pos, DOWN_VECTOR);

        // Track rocket for cleanup
        if (rocket > 0 && IsValidEntity(rocket))
        {
            gActiveRockets.Push(EntIndexToEntRef(rocket));

            // Store fire support info for this rocket to track kill counts
            DataPack rocketInfo = new DataPack();
            rocketInfo.WriteCell(client);
            rocketInfo.WriteCell(supportType);
            rocketInfo.WriteCell(sessionIndex);
            gRocketFireSupportInfo[rocket] = view_as<Handle>(rocketInfo);

            // Hook smoke spawning if enabled for this support type
            if (gSupportTypes[supportType].spawnSmoke)
            {
                // Store support type index in the entity for later retrieval
                SetEntProp(rocket, Prop_Data, "m_iHammerID", supportType);

                // Hook the rocket's touch event
                SDKHook(rocket, SDKHook_Touch, OnRocketTouch);
            }
        }

        // Print projectile message to team if configured
        if (!StrEqual(gSupportTypes[supportType].projectileMessage, ""))
        {
            PrintMessageToTeam(team, gSupportTypes[supportType].projectileMessage);
        }

        if (shells > 1)
        {
            // Calculate base time between shells using ORIGINAL shell count
            float timeBetweenShells = duration / float(originalShells - 1);

            // Apply jitter: random variance of ±jitter fraction
            // jitter of 0.3 means ±30% variance
            float jitterAmount      = (GetURandomFloat() * 2.0 - 1.0) * jitter * timeBetweenShells;
            float nextDelay         = timeBetweenShells + jitterAmount;

            // Ensure delay is always positive
            if (nextDelay < 0.01)
            {
                nextDelay = 0.01;
            }

            // Reuse the same pack for the next shell
            CreateTimer(nextDelay, Timer_LaunchMissile, pack, TIMER_FLAG_NO_MAPCHANGE);
        }
        else
        {
            // This was the last shell - display completion message if configured
            if (!StrEqual(gSupportTypes[supportType].completionMessage, ""))
            {
                // Get the fire support session to retrieve kill count
                DataPack sessionPack = view_as<DataPack>(gActiveFireSupport.Get(sessionIndex));
                if (sessionPack != null)
                {
                    sessionPack.Reset();
                    int sessionClient = sessionPack.ReadCell();
                    int sessionTeam   = sessionPack.ReadCell();
                    sessionPack.ReadCell();    // sessionType - not needed for completion message
                    int  enemyKills    = sessionPack.ReadCell();
                    int  friendlyKills = sessionPack.ReadCell();

                    // Get player name
                    char playerName[64];
                    if (ValidateClient(sessionClient))
                    {
                        GetClientName(sessionClient, playerName, sizeof(playerName));
                    }
                    else
                    {
                        strcopy(playerName, sizeof(playerName), "Unknown");
                    }

                    // Format the completion message
                    char message[256];
                    strcopy(message, sizeof(message), gSupportTypes[supportType].completionMessage);

                    // Replace placeholders:
                    // {1} = enemy kills
                    // {2} = player name
                    // {3} = friendly kills
                    char enemyKillsStr[16];
                    char friendlyKillsStr[16];
                    IntToString(enemyKills, enemyKillsStr, sizeof(enemyKillsStr));
                    IntToString(friendlyKills, friendlyKillsStr, sizeof(friendlyKillsStr));
                    ReplaceString(message, sizeof(message), "{1}", enemyKillsStr, false);
                    ReplaceString(message, sizeof(message), "{2}", playerName, false);
                    ReplaceString(message, sizeof(message), "{3}", friendlyKillsStr, false);

                    // Send message to team
                    PrintMessageToTeam(sessionTeam, message);

                    // Note: Don't delete or erase the session here!
                    // Other rockets may still reference this sessionIndex.
                    // Sessions are cleaned up at round end in CleanupActiveFireSupport()
                }
            }

            // Clean up the pack
            delete pack;
        }
    }
    else
    {
        // Client invalid, clean up the pack
        delete pack;
    }
    return Plugin_Handled;
}

public Action Timer_EnableTeamSupport(Handle timer, DataPack pack)
{
    pack.Reset();
    int team                         = pack.ReadCell();
    int supportType                  = pack.ReadCell();
    IsEnabledTeam[team][supportType] = true;
    return Plugin_Handled;
}

/// UTILS
bool GetAimGround(int client, float vec[3])
{
    float pos[3];
    float dir[3];
    GetClientEyePosition(client, pos);
    GetClientEyeAngles(client, dir);
    Handle ray = TR_TraceRayFilterEx(pos, dir, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceWorldOnly, client);

    if (TR_DidHit(ray))
    {
        TR_GetEndPosition(pos, ray);
        CloseHandle(ray);

        ray = TR_TraceRayFilterEx(pos, DOWN_VECTOR, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceWorldOnly, client);
        if (TR_DidHit(ray))
        {
            TR_GetEndPosition(vec, ray);
            CloseHandle(ray);
            return true;
        }
        CloseHandle(ray);
    }
    else {
        CloseHandle(ray);
    }

    return false;
}

bool GetSkyPos(int client, float pos[3], float vec[3])
{
    Handle ray = TR_TraceRayFilterEx(pos, UP_VECTOR, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceWorldOnly, client);

    if (TR_DidHit(ray))
    {
        char surface[64];
        TR_GetSurfaceName(ray, surface, sizeof(surface));
        if (StrEqual(surface, "TOOLS/TOOLSSKYBOX", false))
        {
            TR_GetEndPosition(vec, ray);
            CloseHandle(ray);
            return true;
        }
    }

    CloseHandle(ray);
    return false;
}

public bool TraceWorldOnly(int entity, int mask, any data)
{
    if (entity == data || entity > 0)
        return false;
    return true;
}

public bool ValidateClient(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return false;
    }

    if (!IsClientInGame(client))
        return false;

    return true;
}

/// FIRE SUPPORT CLEANUP
void CleanupActiveFireSupport()
{
    // Kill all active rockets
    int rocketsKilled = 0;
    for (int i = 0; i < gActiveRockets.Length; i++)
    {
        int rocketRef = gActiveRockets.Get(i);
        int rocket    = EntRefToEntIndex(rocketRef);
        if (rocket != INVALID_ENT_REFERENCE && IsValidEntity(rocket))
        {
            AcceptEntityInput(rocket, "Kill");
            rocketsKilled++;
        }
    }
    gActiveRockets.Clear();

    // Kill all active smoke grenades
    int smokeKilled = 0;
    for (int i = 0; i < gActiveSmokeGrenades.Length; i++)
    {
        int smokeRef = gActiveSmokeGrenades.Get(i);
        int smoke    = EntRefToEntIndex(smokeRef);
        if (smoke != INVALID_ENT_REFERENCE && IsValidEntity(smoke))
        {
            AcceptEntityInput(smoke, "Kill");
            smokeKilled++;
        }
    }
    gActiveSmokeGrenades.Clear();

    // Clean up pending fire support (grenades that haven't become stationary yet)
    for (int i = 0; i < sizeof(gPendingFireSupport); i++)
    {
        if (gPendingFireSupport[i] != null)
        {
            delete gPendingFireSupport[i];
            gPendingFireSupport[i] = null;
        }
        gGrenadeStationaryChecks[i] = 0;
    }

    // Clean up rocket fire support info
    for (int i = 0; i < sizeof(gRocketFireSupportInfo); i++)
    {
        if (gRocketFireSupportInfo[i] != null)
        {
            delete gRocketFireSupportInfo[i];
            gRocketFireSupportInfo[i] = null;
        }
    }

    // Clean up fire support sessions
    for (int i = 0; i < gActiveFireSupport.Length; i++)
    {
        DataPack sessionPack = view_as<DataPack>(gActiveFireSupport.Get(i));
        if (sessionPack != null)
        {
            delete sessionPack;
        }
    }
    gActiveFireSupport.Clear();

    // Timers will self-terminate when they check round number or entity validity
}

/// SMOKE SPAWNING
void SpawnSmokeGrenade(float pos[3], const char[] smokeType)
{
    if (StrEqual(smokeType, ""))
    {
        return;
    }

    // Try to create the smoke entity
    int smokeEntity = CreateEntityByName(smokeType);
    if (smokeEntity == -1)
    {
        LogError("Failed to create smoke entity of type: %s", smokeType);
        return;
    }

    // Set owner to world (no owner)
    SetEntPropEnt(smokeEntity, Prop_Send, "m_hOwnerEntity", -1);

    // Spawn and activate the grenade projectile
    DispatchSpawn(smokeEntity);
    ActivateEntity(smokeEntity);

    // Track smoke grenade for cleanup
    gActiveSmokeGrenades.Push(EntIndexToEntRef(smokeEntity));

    // Set velocity to zero so it doesn't roll
    float zeroVel[3] = { 0.0, 0.0, 0.0 };

    // Teleport to position with zero velocity
    TeleportEntity(smokeEntity, pos, NULL_VECTOR, zeroVel);

    // Make the grenade model invisible (but keep smoke visible)
    SetEntityRenderMode(smokeEntity, RENDER_TRANSCOLOR);
    SetEntityRenderColor(smokeEntity, 0, 0, 0, 0);    // Fully transparent

    // The grenade will detonate on its own based on its normal fuse time
    // Auto-cleanup after 45 seconds (longer to ensure smoke dissipates)
    SetVariantString("OnUser1 !self:Kill::45:1");
    AcceptEntityInput(smokeEntity, "AddOutput");
    AcceptEntityInput(smokeEntity, "FireUser1");
}

public void OnRocketTouch(int rocket, int other)
{
    // Get the support type index stored in the rocket entity
    int supportType = GetEntProp(rocket, Prop_Data, "m_iHammerID");

    if (supportType < 0 || supportType >= gNumSupportTypes)
    {
        return;
    }

    if (!gSupportTypes[supportType].spawnSmoke)
    {
        return;
    }

    // Get rocket position
    float impactPos[3];
    GetEntPropVector(rocket, Prop_Send, "m_vecOrigin", impactPos);

    // Spawn smoke at impact location
    SpawnSmokeGrenade(impactPos, gSupportTypes[supportType].smokeType);

    // Unhook to prevent multiple calls
    SDKUnhook(rocket, SDKHook_Touch, OnRocketTouch);
}
