#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION     "1.1.0"
#define PLUGIN_DESCRIPTION "Fucking fuck yeah"

#pragma newdecls required

public Plugin myinfo =
{
    name        = "[GG2 FUCKYEAH] Fuck Yeah",
    author      = "Casey Weed (Battleroid) || zachm",
    description = PLUGIN_DESCRIPTION,
    version     = PLUGIN_VERSION
};

Handle g_CvarEnabled;
Handle g_CvarYellChance;

// Insurgency's team numbers. Same values gg2_heavy_ammo uses.
#define TEAM_SPEC          1
#define TEAM_SEC           2
#define TEAM_INS           3

// list of specific files that are decent
//
// EVERY ONE OF THESE IS A SECURITY LINE - see the paths. The game ships no insurgent equivalent for
// them, so this only ever plays for the security team; see the team gate in Fuck(). If insurgent
// lines are ever added, they need their own list and a team-indexed pick, not an append here.
char   FuckingSounds[][] = {
    "player/voice/radial/security/leader/suppressed/target5.ogg",
    "player/voice/radial/security/subordinate/unsuppressed/enemydown_knifekill3.ogg",
    "player/voice/radial/security/subordinate/unsuppressed/enemydown_knifekill1.ogg",
    "player/voice/responses/security/subordinate/suppressed/target1.ogg",
    "player/voice/responses/security/subordinate/suppressed/target2.ogg",
    "player/voice/responses/security/subordinate/suppressed/target3.ogg",
    "player/voice/responses/security/subordinate/suppressed/target4.ogg",
    "player/voice/responses/security/subordinate/suppressed/target5.ogg",
    "player/voice/responses/security/subordinate/suppressed/target6.ogg",
    "player/voice/responses/security/subordinate/suppressed/target7.ogg",
    "player/voice/responses/security/subordinate/suppressed/target8.ogg",
    "player/voice/responses/security/subordinate/suppressed/target9.ogg",
    "player/voice/responses/security/subordinate/suppressed/target10.ogg",
    "player/voice/responses/security/subordinate/suppressed/target11.ogg",
    "player/voice/responses/security/subordinate/suppressed/target12.ogg",
    "player/voice/responses/security/subordinate/suppressed/target13.ogg"
};

// whether or not the player has an active cooldown, end time for cooldown
float  PlayerTimeDone[MAXPLAYERS + 1];
int    PlayerLastSoundNumber[MAXPLAYERS + 1] = { -1, ... };

// length of time to wait before yelling can occur again (in seconds)
Handle CooldownPeriod;

// Per-player opt-out, toggled with !fy. An opted-out player neither yells on their own kills nor
// hears anyone else's yells. Saved in player_fy_opt_out in the insurgency-stats database so it
// survives map changes and reconnects; g_OptOut mirrors it for connected players. Until a player's
// row has loaded (or if they have none) they are opted in.
bool     g_OptOut[MAXPLAYERS + 1];
// Chosen but not yet saved. A load must not overwrite it, and a reconnect writes it rather than
// re-reading - otherwise a database hiccup would silently flip the player back.
bool     g_OptOutDirty[MAXPLAYERS + 1];

Database g_hDb = null;
bool     g_bDbConnecting = false;
// Bumped on every successful connect. A query that fails with a connection error on an older handle
// is simply retried on the new one instead of starting yet another reconnect.
int      g_iDbGeneration = 0;

public void OnPluginStart()
{
    // cvars
    CreateConVar("fy_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_NOTIFY | 0 | FCVAR_DONTRECORD);
    g_CvarEnabled    = CreateConVar("fy_enabled", "1", "Fuck Yeah Enabled [0/1]", FCVAR_NOTIFY | 0);
    g_CvarYellChance = CreateConVar("fy_chance", "0.5", "Chance of Yelling [0-1]", FCVAR_NOTIFY | 0, true, 0.0, true, 1.0);
    CooldownPeriod   = CreateConVar("fy_cooldown", "1.0", "Cooldown period between yells [>0.0]", FCVAR_NOTIFY | 0, true, 0.0, false);

    // commands (debug)
    RegConsoleCmd("fuckyeah", Command_FuckTest, "Test Fuck Yeah plugin.");
    // sm_ prefixed commands are reachable as both !fy and /fy.
    RegConsoleCmd("sm_fy", Command_Toggle, "Turn the kill voice lines on or off for yourself. Usage: !fy [on|off]");

    // The connect callback also loads everyone already connected, for a late load.
    ConnectDatabase();

    // events
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

    // notify
    if (GetConVarBool(g_CvarEnabled))
    {
        float percentage = GetConVarFloat(g_CvarYellChance) * 100;
        PrintToServer("[FY] Started with %0.2f% yell chance!", percentage);
        PrintToServer("[FY] CooldownPeriod is %0.2f", GetConVarFloat(CooldownPeriod));
    }

    AutoExecConfig(true, "fuckyeah");
}

public void OnMapStart()
{
    for (int i = 0; i < sizeof(FuckingSounds); i++)
    {
        PrecacheSound(FuckingSounds[i]);
    }

    PrintToServer("[FY] Done caching %d sounds", sizeof(FuckingSounds));

    // The retry timer does not survive a map change, so pick a failed connection back up here.
    if (g_hDb == null) ConnectDatabase();
}

public void OnClientConnected(int client)
{
    g_OptOut[client]      = false;
    g_OptOutDirty[client] = false;
}

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client)) return;

    // Toggled before the SteamID was available, so that save could not run yet.
    if (g_OptOutDirty[client]) SaveOptOut(client);
    else LoadOptOut(client);
}

public Action Command_Toggle(int client, int args)
{
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Handled;

    bool wantOptOut;
    if (args == 0)
    {
        // No argument: toggle.
        wantOptOut = !g_OptOut[client];
    }
    else
    {
        char arg[8];
        GetCmdArg(1, arg, sizeof(arg));
        if (StrEqual(arg, "on", false) || StrEqual(arg, "1", false) || StrEqual(arg, "yes", false))
        {
            wantOptOut = false;
        }
        else if (StrEqual(arg, "off", false) || StrEqual(arg, "0", false) || StrEqual(arg, "no", false))
        {
            wantOptOut = true;
        }
        else
        {
            PrintToChat(client, "[FY] Usage: !fy [on|off]");
            return Plugin_Handled;
        }
    }

    SetOptOut(client, wantOptOut);
    return Plugin_Handled;
}

void SetOptOut(int client, bool optOut)
{
    if (optOut == g_OptOut[client])
    {
        PrintToChat(client, "[FY] Kill voice lines are already %s for you.", optOut ? "OFF" : "ON");
        return;
    }

    // Applies immediately; the save happens in the background.
    g_OptOut[client]      = optOut;
    g_OptOutDirty[client] = true;
    SaveOptOut(client);
    PrintToChat(client, "[FY] Kill voice lines are now %s for you. Type !fy to turn them %s.",
                optOut ? "OFF" : "ON", optOut ? "back on" : "off");
}

// ---------------------------------------------------------------------------------------------
// Database. Same pattern as d_dy_pull_rag: the pooled connection to the stats database is dropped
// when idle, so every query treats a connection error as "reconnect and try again" rather than as
// a real failure.
// ---------------------------------------------------------------------------------------------

void ConnectDatabase()
{
    if (g_bDbConnecting) return;

    g_bDbConnecting = true;
    delete g_hDb;
    Database.Connect(OnDatabaseConnected, "insurgency-stats");
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    g_bDbConnecting = false;

    if (db == null)
    {
        LogError("[FY] Could not connect to insurgency-stats: %s - everyone hears the voice lines until it is back", error);
        CreateTimer(30.0, Timer_RetryConnect, _, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    g_hDb = db;
    g_iDbGeneration++;
    LoadAllOptOuts();
}

public Action Timer_RetryConnect(Handle timer)
{
    if (g_hDb == null) ConnectDatabase();
    return Plugin_Stop;
}

bool IsConnectionError(const char[] error)
{
    static const char markers[][] = {
        "server closed the connection",
        "no connection to the server",
        "connection not open",
        "could not send data to server",
        "could not receive data from server",
        "terminating connection",
        "SSL SYSCALL error",
    };

    for (int i = 0; i < sizeof(markers); i++)
        if (StrContains(error, markers[i], false) != -1) return true;

    return false;
}

// A query failed with a connection error. If the handle it ran on has already been replaced, run it
// again on the new one; otherwise this is the first to notice, so reconnect - the connect callback
// re-runs everything that is outstanding.
bool RetryOnNewConnection(int generation)
{
    if (generation != g_iDbGeneration && g_hDb != null) return true;

    ConnectDatabase();
    return false;
}

// Everyone in game: write what is unsaved, read the rest.
void LoadAllOptOuts()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsClientAuthorized(i)) continue;

        if (g_OptOutDirty[i]) SaveOptOut(i);
        else LoadOptOut(i);
    }
}

void LoadOptOut(int client)
{
    if (g_hDb == null)
    {
        ConnectDatabase();    // the connect callback loads everyone
        return;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    char query[256];
    // ::int because the pgsql driver hands FetchInt a BOOLEAN's text form, which reads as 0.
    g_hDb.Format(query, sizeof(query), "SELECT opt_out::int FROM player_fy_opt_out WHERE steam_id = %s", steamId);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iDbGeneration);
    g_hDb.Query(OnOptOutLoaded, query, pack);
}

public void OnOptOutLoaded(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int client     = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    delete pack;

    if (client == 0) return;

    if (results == null)
    {
        if (IsConnectionError(error))
        {
            if (RetryOnNewConnection(generation)) LoadOptOut(client);
            return;
        }

        LogError("[FY] Could not load opt-out for %N: %s", client, error);
        return;
    }

    // Chosen while this was in flight - the choice wins over what was stored before it.
    if (g_OptOutDirty[client]) return;

    g_OptOut[client] = results.FetchRow() && results.FetchInt(0) != 0;
}

void SaveOptOut(int client)
{
    if (g_hDb == null)
    {
        ConnectDatabase();    // stays dirty; the connect callback writes it
        return;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    bool optOut = g_OptOut[client];

    char query[384];
    g_hDb.Format(query, sizeof(query),
                 "INSERT INTO player_fy_opt_out (steam_id, opt_out) VALUES (%s, %s) ON CONFLICT (steam_id) DO UPDATE SET opt_out = EXCLUDED.opt_out, updated_at = CURRENT_TIMESTAMP",
                 steamId, optOut ? "TRUE" : "FALSE");

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iDbGeneration);
    pack.WriteCell(optOut);
    g_hDb.Query(OnOptOutSaved, query, pack);
}

public void OnOptOutSaved(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int  client     = GetClientOfUserId(pack.ReadCell());
    int  generation = pack.ReadCell();
    bool optOut     = pack.ReadCell();
    delete pack;

    if (client == 0) return;

    if (results == null)
    {
        if (IsConnectionError(error))
        {
            if (RetryOnNewConnection(generation)) SaveOptOut(client);
            return;
        }

        LogError("[FY] Could not save opt-out for %N: %s", client, error);
        PrintToChat(client, "[FY] Couldn't save that, so it only lasts until you disconnect.");
        g_OptOutDirty[client] = false;
        return;
    }

    // Only clean if nothing newer was chosen while this write was in flight.
    if (g_OptOut[client] == optOut) g_OptOutDirty[client] = false;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    RemoveCooldown(client);
    return Plugin_Continue;
}

public Action Command_FuckTest(int client, int args)
{
    Fuck(client);
    return Plugin_Handled;
}

public Action Fuck(int client)
{
    if (!GetConVarBool(g_CvarEnabled)) return Plugin_Stop;

    if (client == 0 || client > MaxClients) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;
    if (!IsClientInGame(client)) return Plugin_Continue;

    // Security only. Every file in FuckingSounds is a security voice line and the game ships no
    // insurgent counterpart, so an insurgent kill used to emit a security voice out of the killer's
    // own body - audible to everyone, and wrong for the team that made the kill. Gated here rather
    // than at the player_death caller so the "fuckyeah" test command obeys it too.
    if (GetClientTeam(client) != TEAM_SEC) return Plugin_Continue;

    // An opted-out player's own kills stay silent.
    if (g_OptOut[client]) return Plugin_Continue;

    int numSoundsAvailable = sizeof(FuckingSounds) - 1;    // Inclusive, starting from zero
    int lastSoundNumber    = PlayerLastSoundNumber[client];
    if (lastSoundNumber != -1)
    {
        // Removing another item prevents the same sound from being picked twice
        numSoundsAvailable--;
    }

    int soundNumber = GetRandomInt(0, numSoundsAvailable);
    if (soundNumber >= lastSoundNumber && lastSoundNumber != -1)
    {
        // Shift the pick upwards by one when the picked number is on the interval at or above
        // the last picked sound. This shouldn't go out of bounds and should still be a uniformly
        // random choice between all the sounds except for the most recently played one.
        soundNumber++;
    }

    // Everyone except opted-out players. Same as EmitSoundToAll, which also skips bots.
    int clients[MAXPLAYERS];
    int numClients = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || g_OptOut[i]) continue;
        clients[numClients++] = i;
    }
    if (numClients == 0) return Plugin_Continue;

    EmitSound(clients, numClients, FuckingSounds[soundNumber], client);
    PlayerLastSoundNumber[client] = soundNumber;

    return Plugin_Continue;
}

public Action SetCooldown(int client)
{
    // set timeDone for client
    float timeDone         = GetGameTime() + GetConVarFloat(CooldownPeriod);
    PlayerTimeDone[client] = timeDone;

    return Plugin_Continue;
}

public Action RemoveCooldown(int client)
{
    PlayerTimeDone[client] = 0.0;

    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (victim == 0) return Plugin_Continue;

    int killer = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (killer == 0) return Plugin_Continue;

    // Reset cooldown for victim
    if (victim > 0 && !IsFakeClient(victim) && IsClientInGame(victim))
    {
        RemoveCooldown(victim);
    }

    // Skip if the killer is a bot
    if (killer == 0 || !IsClientInGame(killer) || IsFakeClient(killer) || victim == killer) return Plugin_Continue;

    // Skip if the victim and killer are on the same team
    int victimTeam = GetClientTeam(victim);
    int killerTeam = GetClientTeam(killer);
    if (victimTeam == killerTeam) return Plugin_Continue;

    // Get killer timeDone and check if it is still active
    if (GetGameTime() < PlayerTimeDone[killer]) return Plugin_Continue;

    // Play sound at the player if RNG passes
    float yellRoll = GetRandomFloat(0.0, 1.0);
    if (yellRoll > GetConVarFloat(g_CvarYellChance)) return Plugin_Continue;

    Fuck(killer);
    SetCooldown(killer);
    return Plugin_Continue;
}
