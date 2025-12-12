#include <sourcemod>
#include <sdktools>
#include <dbi>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION     "0.0.1.1"
#define PLUGIN_DESCRIPTION "Stats system IMPROVED // SIMPLIFIED"
#define TEAM_NONE          0
#define TEAM_SPEC          1
#define TEAM_1_SEC         2
#define TEAM_2_INS         3

Database  g_Database = null;

char      g_SteamID[MAXPLAYERS + 1][32];

int       g_iStartScore[MAXPLAYERS + 1];
char      g_escaped_map_name[257];
char      bawt_steam_id[64] = "STEAM_ID_STOP_IGNORING_RETVALS";

// In-memory stat cache - flushed to DB at round end and player disconnect
int       g_cache_kills[MAXPLAYERS + 1];
int       g_cache_deaths[MAXPLAYERS + 1];
int       g_cache_suicides[MAXPLAYERS + 1];
int       g_cache_headshot_given[MAXPLAYERS + 1];
int       g_cache_headshot_taken[MAXPLAYERS + 1];
int       g_cache_suppressions[MAXPLAYERS + 1];
int       g_cache_caps[MAXPLAYERS + 1];
int       g_cache_killstreak[MAXPLAYERS + 1];
int       g_cache_killstreak_max[MAXPLAYERS + 1];

// Per-player and per-bot weapon kill tracking: weapon_name -> kill_count
StringMap g_cache_weapon_kills[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "[GG2 MSTATS2] Simplified",
    author      = "zachm & Bot Chris",
    version     = PLUGIN_VERSION,
    description = PLUGIN_DESCRIPTION,
    url         = "http://tug.gg"
};

public void OnPluginStart()
{
    Database.Connect(OnDatabaseConnected, "insurgency-stats");

    HookEvent("player_activate", Event_PlayerActivate);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_hurt", Event_PlayerHurt);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured);
    HookEvent("object_destroyed", Event_ObjectDestroyed);
    HookEvent("player_suppressed", Event_PlayerSuppressed);

    CreateTimer(3.0, LoadPlayerIDs);

    AutoExecConfig(true, "gg2_mstats2");
}

int GetGameState()
{
    return GameRules_GetProp("m_iGameState");
}

public bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

public Action Event_PlayerActivate(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Continue;

    CreateTimer(1.0, Timer_RecordStartingScore, client, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

Action Timer_RecordStartingScore(Handle timer, int client)
{
    if (!IsValidPlayer(client)) return Plugin_Continue;

    g_iStartScore[client] = GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iPlayerScore", _, client);
    return Plugin_Continue;
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[GG2 MSTATS2] Failed to connect to database: %s", error);
        SetFailState("Database connection failed");
        return;
    }

    g_Database = db;
    LogMessage("[GG2 MSTATS2] Successfully connected to database");
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    LogMessage("[GG2 MSTATS2] Attempting to reconnect to database...");
    g_Database = null;
    Database.Connect(OnDatabaseReconnected, "insurgency-stats");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[GG2 MSTATS2] Failed to reconnect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("[GG2 MSTATS2] Successfully reconnected to database");
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database != null) return Plugin_Stop;

    ReconnectDatabase();
    return Plugin_Stop;
}

// Helper function to handle database query errors
// Returns true if query was successful, false if there was an error
bool HandleQueryError(DBResultSet results, const char[] error, const char[] operationName)
{
    if (results != null) return true;

    // Check if the error is due to lost connection
    if (StrContains(error, "no connection to the server", false) != -1)
    {
        LogError("[GG2 MSTATS2] Lost connection to database: %s - attempting to reconnect", error);
        ReconnectDatabase();
        return false;
    }

    LogError("[GG2 MSTATS2] Failed to %s: %s", operationName, error);
    return false;
}

// Execute a database query with automatic retry on connection loss
// Wraps the query in a DataPack to enable retry on connection failure
void ExecuteQueryWithRetry(SQLTCallback originalCallback, const char[] query, any originalData = 0, int maxRetries = 2)
{
    if (g_Database == null) return;

    // Pack query info for potential retry
    DataPack pack = new DataPack();
    pack.WriteString(query);
    pack.WriteFunction(originalCallback);
    pack.WriteCell(originalData);
    pack.WriteCell(0);             // retryCount
    pack.WriteCell(maxRetries);    // maxRetries

    g_Database.Query(OnQueryCompleteWithRetry, query, pack);
}

public void OnQueryComplete(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "execute query");
}

public void OnQueryCompleteWithRetry(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    // Unpack query data
    pack.Reset();
    char query[16384];
    pack.ReadString(query, sizeof(query));
    SQLTCallback originalCallback = view_as<SQLTCallback>(pack.ReadFunction());
    any          originalData     = pack.ReadCell();
    int          retryCount       = pack.ReadCell();
    int          maxRetries       = pack.ReadCell();

    // Success - forward to original callback
    if (results != null)
    {
        delete pack;
        Call_StartFunction(null, originalCallback);
        Call_PushCell(db);
        Call_PushCell(results);
        Call_PushString("");
        Call_PushCell(originalData);
        Call_Finish();
        return;
    }

    // Not a connection loss - forward error to original callback and bail
    if (StrContains(error, "no connection to the server", false) == -1)
    {
        delete pack;
        LogError("[GG2 MSTATS2] Query failed: %s", error);

        // Call original callback with error
        Call_StartFunction(null, originalCallback);
        Call_PushCell(db);
        Call_PushCell(results);
        Call_PushString(error);
        Call_PushCell(originalData);
        Call_Finish();
        return;
    }

    // Connection lost - attempt reconnect
    LogError("[GG2 MSTATS2] Query failed due to connection loss - attempting reconnect and retry");
    ReconnectDatabase();
    delete pack;

    // Max retries reached - give up
    if (retryCount >= maxRetries)
    {
        LogError("[GG2 MSTATS2] Max retries (%d) reached for query, giving up", maxRetries);
        return;
    }

    // Schedule retry
    LogMessage("[GG2 MSTATS2] Scheduling retry %d/%d", retryCount + 1, maxRetries);
    DataPack retryPack = new DataPack();
    retryPack.WriteString(query);
    retryPack.WriteFunction(originalCallback);
    retryPack.WriteCell(originalData);
    retryPack.WriteCell(retryCount + 1);
    retryPack.WriteCell(maxRetries);
    CreateTimer(3.0, Timer_RetryQuery, retryPack);
}

public Action Timer_RetryQuery(Handle timer, DataPack pack)
{
    pack.Reset();

    char query[16384];
    pack.ReadString(query, sizeof(query));
    SQLTCallback originalCallback = view_as<SQLTCallback>(pack.ReadFunction());
    any          originalData     = pack.ReadCell();
    int          retryCount       = pack.ReadCell();
    int          maxRetries       = pack.ReadCell();

    // Database still reconnecting - reschedule retry
    if (g_Database == null)
    {
        if (retryCount >= maxRetries)
        {
            LogError("[GG2 MSTATS2] Max retries reached and database still null, giving up");
            delete pack;
            return Plugin_Stop;
        }

        LogMessage("[GG2 MSTATS2] Database still reconnecting, rescheduling retry %d/%d", retryCount + 1, maxRetries);

        // Reschedule with incremented retry count
        DataPack newPack = new DataPack();
        newPack.WriteString(query);
        newPack.WriteFunction(originalCallback);
        newPack.WriteCell(originalData);
        newPack.WriteCell(retryCount + 1);
        newPack.WriteCell(maxRetries);

        delete pack;
        CreateTimer(3.0, Timer_RetryQuery, newPack);
        return Plugin_Stop;
    }

    delete pack;

    LogMessage("[GG2 MSTATS2] Retrying query (attempt %d/%d)", retryCount, maxRetries);

    // Create new pack for the retry
    DataPack retryPack = new DataPack();
    retryPack.WriteString(query);
    retryPack.WriteFunction(originalCallback);
    retryPack.WriteCell(originalData);
    retryPack.WriteCell(retryCount);
    retryPack.WriteCell(maxRetries);

    g_Database.Query(OnQueryCompleteWithRetry, query, retryPack);

    return Plugin_Stop;
}

public void OnMapStart()
{
    // Check if database connection is ready
    if (g_Database == null)
    {
        LogMessage("[GG2 MSTATS2] Database unavailable at map start, attempting reconnection...");
        ReconnectDatabase();
    }

    char map_name[128];
    GetCurrentMap(map_name, sizeof(map_name));

    // Escape map name once for SQL queries throughout the map
    if (g_Database != null && g_Database.Escape(map_name, g_escaped_map_name, sizeof(g_escaped_map_name))) return;

    // Critical failure: cannot safely use map name in SQL queries
    // Player stats will still be tracked, but map win/loss records will be disabled
    g_escaped_map_name[0] = '\0';    // Set to empty string instead of using unsafe unescaped name
    LogError("[GG2 MSTATS2] Failed to escape map name in OnMapStart: %s", map_name);
}

public Action LoadPlayerIDs(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidPlayer(client)) continue;
        if (IsFakeClient(client)) continue;
        if (GetClientTeam(client) != TEAM_1_SEC) continue;

        GetClientAuthId(client, AuthId_SteamID64, g_SteamID[client], 32);
        RecordPlayer(client);
    }

    return Plugin_Continue;
}

void InitPlayerCache(int client)
{
    g_cache_kills[client]          = 0;
    g_cache_deaths[client]         = 0;
    g_cache_suicides[client]       = 0;
    g_cache_headshot_given[client] = 0;
    g_cache_headshot_taken[client] = 0;
    g_cache_suppressions[client]   = 0;
    g_cache_caps[client]           = 0;
    g_cache_killstreak[client]     = 0;
    g_cache_killstreak_max[client] = 0;

    // Clear or create weapon kills map
    if (g_cache_weapon_kills[client] != null)
    {
        g_cache_weapon_kills[client].Clear();
        return;
    }
    g_cache_weapon_kills[client] = new StringMap();
}

void FlushPlayerStats(int client)
{
    if (g_Database == null) return;
    if (StrEqual(g_SteamID[client], "")) return;
    if (StrEqual(g_SteamID[client], bawt_steam_id)) return;

    // Track max killstreak
    if (g_cache_killstreak[client] > g_cache_killstreak_max[client])
    {
        g_cache_killstreak_max[client] = g_cache_killstreak[client];
    }

    // Only flush if there's something to update
    if (g_cache_kills[client] == 0 && g_cache_deaths[client] == 0 && g_cache_suicides[client] == 0 && g_cache_headshot_given[client] == 0 && g_cache_headshot_taken[client] == 0 && g_cache_suppressions[client] == 0 && g_cache_caps[client] == 0 && g_cache_killstreak_max[client] == 0)
    {
        return;
    }

    char query[1024];
    Format(query, sizeof(query), "INSERT INTO player_stats (steam_id, kills, deaths, suicides, headshot_given, headshot_taken, suppressions, caps, killstreak) VALUES ('%s', %i, %i, %i, %i, %i, %i, %i, %i) ON CONFLICT (steam_id) DO UPDATE SET kills = player_stats.kills + %i, deaths = player_stats.deaths + %i, suicides = player_stats.suicides + %i, headshot_given = player_stats.headshot_given + %i, headshot_taken = player_stats.headshot_taken + %i, suppressions = player_stats.suppressions + %i, caps = player_stats.caps + %i, killstreak = CASE WHEN player_stats.killstreak IS NULL OR player_stats.killstreak < %i THEN %i ELSE player_stats.killstreak END, updated_at = CURRENT_TIMESTAMP", g_SteamID[client], g_cache_kills[client], g_cache_deaths[client], g_cache_suicides[client], g_cache_headshot_given[client], g_cache_headshot_taken[client], g_cache_suppressions[client], g_cache_caps[client], g_cache_killstreak_max[client], g_cache_kills[client], g_cache_deaths[client], g_cache_suicides[client], g_cache_headshot_given[client], g_cache_headshot_taken[client], g_cache_suppressions[client], g_cache_caps[client], g_cache_killstreak_max[client], g_cache_killstreak_max[client]);

    ExecuteQueryWithRetry(OnQueryComplete, query, client);

    // Clear cache after flushing
    g_cache_kills[client]          = 0;
    g_cache_deaths[client]         = 0;
    g_cache_suicides[client]       = 0;
    g_cache_headshot_given[client] = 0;
    g_cache_headshot_taken[client] = 0;
    g_cache_suppressions[client]   = 0;
    g_cache_caps[client]           = 0;
    g_cache_killstreak[client]     = 0;
    g_cache_killstreak_max[client] = 0;
}

void BuildWeaponKillsQuery(char[] query, int maxlen, const char[] table_name, const char[] id_column, const char[] id_value, int client)
{
    StringMapSnapshot snap = g_cache_weapon_kills[client].Snapshot();

    int               size = snap.Length;
    if (size == 0)
    {
        delete snap;
        return;
    }

    // Build both parts of the query in one loop using separate buffers
    char weapons_values[4096] = "";
    char kills_values[8192]   = "";

    int  weapons_count        = 0;

    for (int i = 0; i < snap.Length; i++)
    {
        char weapon_name[64];
        snap.GetKey(i, weapon_name, sizeof(weapon_name));

        char escaped_weapon_name[129];
        if (!g_Database.Escape(weapon_name, escaped_weapon_name, sizeof(escaped_weapon_name))) continue;

        int kill_count;
        if (!g_cache_weapon_kills[client].GetValue(weapon_name, kill_count)) continue;

        // Build weapons INSERT value
        char weapon_value[128];
        Format(weapon_value, sizeof(weapon_value), "%s('%s')", weapons_count > 0 ? ", " : "", escaped_weapon_name);

        // Check if there's space before concatenating
        if (strlen(weapons_values) + strlen(weapon_value) >= sizeof(weapons_values))
        {
            LogError("[GG2 MSTATS2] Weapon values buffer full! Cannot add weapon '%s'. Stopping at %d weapons.", weapon_name, weapons_count);
            break;
        }
        StrCat(weapons_values, sizeof(weapons_values), weapon_value);

        // Build weapon_kills value
        char kill_value[256];
        Format(kill_value, sizeof(kill_value), "%s('%s', %i)", weapons_count > 0 ? ", " : "", escaped_weapon_name, kill_count);

        // Check if there's space before concatenating
        if (strlen(kills_values) + strlen(kill_value) >= sizeof(kills_values))
        {
            LogError("[GG2 MSTATS2] Kills values buffer full! Cannot add weapon '%s'. Stopping at %d weapons.", weapon_name, weapons_count);
            break;
        }
        StrCat(kills_values, sizeof(kills_values), kill_value);

        weapons_count++;
    }

    delete snap;

    if (weapons_count == 0) return;

    // Build final query: upsert weapons with RETURNING, then JOIN against the CTE
    Format(query, maxlen,
           "WITH upserted_weapons AS (INSERT INTO weapons (weapon_name) VALUES %s ON CONFLICT (weapon_name) DO UPDATE SET weapon_name = EXCLUDED.weapon_name RETURNING weapon_id, weapon_name), weapon_kills AS (SELECT * FROM (VALUES %s) AS t(weapon_name, kill_count)) INSERT INTO %s (%s, weapon_id, kill_count) SELECT '%s', uw.weapon_id, wk.kill_count FROM weapon_kills wk JOIN upserted_weapons uw ON uw.weapon_name = wk.weapon_name ON CONFLICT (%s, weapon_id) DO UPDATE SET kill_count = %s.kill_count + EXCLUDED.kill_count, updated_at = CURRENT_TIMESTAMP",
           weapons_values, kills_values, table_name, id_column, id_value, id_column, table_name);
}

void FlushPlayerWeaponKills(int client)
{
    if (g_Database == null) return;
    if (g_cache_weapon_kills[client] == null) return;

    // For players, a valid steam ID is needed
    bool is_bot = IsFakeClient(client);
    if (!is_bot)
    {
        if (StrEqual(g_SteamID[client], "")) return;
        if (StrEqual(g_SteamID[client], bawt_steam_id)) return;
    }

    char query[16384];    // Large buffer: base query (~500) + weapons_values (4096) + kills_values (8192) + params
    if (is_bot)
    {
        // Bot: flush to bot_kills table using bot name
        char bot_name[64];
        if (!GetClientInfo(client, "name", bot_name, sizeof(bot_name))) return;

        char escaped_bot_name[129];
        if (!g_Database.Escape(bot_name, escaped_bot_name, sizeof(escaped_bot_name))) return;

        BuildWeaponKillsQuery(query, sizeof(query), "bot_kills", "bot_name", escaped_bot_name, client);
    }
    else
    {
        // Player: flush to player_kills table using steam_id
        BuildWeaponKillsQuery(query, sizeof(query), "player_kills", "steam_id", g_SteamID[client], client);
    }

    g_cache_weapon_kills[client].Clear();

    if (strlen(query) == 0) return;
    ExecuteQueryWithRetry(OnQueryComplete, query);
}

void FlushAllPlayerStats(int client, int wins = 0, int losses = 0)
{
    FlushPlayerStats(client);
    FlushPlayerWeaponKills(client);
    FlushPlayerScore(client, wins, losses);
}

void FlushPlayerScore(int client, int wins = 0, int losses = 0)
{
    int player_current_score = GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iPlayerScore", _, client);
    int player_score_change  = player_current_score - g_iStartScore[client];
    if (player_score_change <= 0 && wins <= 0 && losses <= 0) return;

    char score_query[512];
    Format(score_query, sizeof(score_query), "INSERT INTO player_stats (steam_id, score, wins, losses) VALUES ('%s', %i, %i, %i) ON CONFLICT (steam_id) DO UPDATE SET score = player_stats.score + %i, wins = player_stats.wins + %i, losses = player_stats.losses + %i, updated_at = CURRENT_TIMESTAMP", g_SteamID[client], player_score_change, wins, losses, player_score_change, wins, losses);

    ExecuteQueryWithRetry(OnQueryComplete, score_query, client);
    g_iStartScore[client] = player_current_score;
}

public void RecordPlayer(int client)
{
    // one last check for bawtness //
    if (StrEqual(g_SteamID[client], bawt_steam_id)) return;

    char query[512];
    Format(query, sizeof(query),
           "INSERT INTO player_stats (steam_id) VALUES ('%s') ON CONFLICT (steam_id) DO UPDATE SET updated_at = CURRENT_TIMESTAMP",
           g_SteamID[client]);
    ExecuteQueryWithRetry(OnPlayerUpserted, query, client);
}

public void OnPlayerUpserted(Database db, DBResultSet results, const char[] error, any client)
{
    if (!HandleQueryError(results, error, "upsert player")) return;

    LogMessage("[GG2 MSTATS2] Player record upserted for client %i (steam_id: %s)", client, g_SteamID[client]);
}

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client)) return;

    if (!GetClientAuthId(client, AuthId_SteamID64, g_SteamID[client], 32)) return;

    InitPlayerCache(client);
    RecordPlayer(client);
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    // Game state is "round running" (active gameplay)
    if (GetGameState() != 4) return Plugin_Continue;

    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(victim)) return Plugin_Continue;

    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsValidPlayer(attacker)) return Plugin_Continue;

    // Get teams first
    int victim_team   = GetClientTeam(victim);
    int attacker_team = GetClientTeam(attacker);

    // Suicides, or world damage (count as suicides)
    if ((victim == attacker) || (attacker == 0))
    {
        // Skip bot suicides
        if (victim_team == TEAM_2_INS) return Plugin_Continue;

        g_cache_suicides[victim]++;
        g_cache_killstreak[victim] = 0;
        return Plugin_Continue;
    }

    // Team kill
    // TK handling is done by the gg2_teamkill plugin
    if (victim_team == attacker_team) return Plugin_Continue;

    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));

    // Ensure weapon kills map exists for attacker
    if (g_cache_weapon_kills[attacker] == null)
    {
        g_cache_weapon_kills[attacker] = new StringMap();
    }

    // Update the weapon kill count (store original weapon name, escape later in BuildWeaponKillsQuery)
    int current_count = 0;
    g_cache_weapon_kills[attacker].GetValue(weapon, current_count);
    g_cache_weapon_kills[attacker].SetValue(weapon, current_count + 1);

    // Update kill/death stats
    g_cache_kills[attacker]++;
    g_cache_killstreak[attacker]++;
    g_cache_deaths[victim]++;
    g_cache_killstreak[victim] = 0;

    return Plugin_Continue;
}

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int hitgroup = GetEventInt(event, "hitgroup");
    // Hitgroup 1 is head
    if (hitgroup != 1) return Plugin_Continue;

    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(victim)) return Plugin_Continue;

    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsValidPlayer(attacker)) return Plugin_Continue;

    // Ignore if same person
    if (victim == attacker) return Plugin_Continue;

    // Skip if same team
    int attacker_team = GetClientTeam(attacker);
    int victim_team   = GetClientTeam(victim);
    if (attacker_team == victim_team) return Plugin_Continue;

    g_cache_headshot_given[attacker]++;
    g_cache_headshot_taken[victim]++;

    return Plugin_Continue;
}

public Action Event_PlayerSuppressed(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsValidPlayer(attacker)) return Plugin_Continue;
    if (IsFakeClient(attacker)) return Plugin_Continue;

    int victim = GetClientOfUserId(GetEventInt(event, "victim"));
    if (!IsValidPlayer(victim)) return Plugin_Continue;

    // Skip if same person
    if (victim == attacker) return Plugin_Continue;

    // Skip if same team
    int victim_team   = GetClientTeam(victim);
    int attacker_team = GetClientTeam(attacker);
    if (victim_team == attacker_team) return Plugin_Continue;

    g_cache_suppressions[attacker]++;

    return Plugin_Continue;
}

public Action Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    char cappers[256];
    GetEventString(event, "cappers", cappers, sizeof(cappers));

    for (int i = 0; i < strlen(cappers); i++)
    {
        int capper_client = cappers[i];
        if (!IsValidPlayer(capper_client)) continue;
        if (IsFakeClient(capper_client)) return Plugin_Continue;

        g_cache_caps[capper_client]++;
    }

    return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetEventInt(event, "attacker");
    if (!IsValidPlayer(attacker)) return Plugin_Continue;
    if (IsFakeClient(attacker)) return Plugin_Continue;

    g_cache_caps[attacker]++;

    // CLAUDE IGNORE THE FOLLOWING TODO UNTIL FURTHER NOTICE //
    // TODO is this right? Can't there be multiple assisters? Or does the game not support this?
    int assister = GetEventInt(event, "assister");
    if (!IsValidPlayer(assister)) return Plugin_Continue;
    if (IsFakeClient(assister)) return Plugin_Continue;

    g_cache_caps[assister]++;

    return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client)) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;

    FlushAllPlayerStats(client);

    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    bool sec_forces_won = GetEventInt(event, "winner") == TEAM_1_SEC;

    // Flush cached stats
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)) continue;

        if (IsFakeClient(client))
        {
            // Bots: only flush weapon kills
            FlushPlayerWeaponKills(client);
            continue;
        }

        int player_score        = GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iPlayerScore", _, client);
        int player_score_change = player_score - g_iStartScore[client];
        if (player_score_change > 0)
        {
            PrintToChat(client, "GG2 // Player: %N Score: %i", client, player_score);
        }

        FlushAllPlayerStats(client, sec_forces_won ? 1 : 0, sec_forces_won ? 0 : 1);
    }

    if (g_escaped_map_name[0] == '\0')
    {
        LogError("[GG2 MSTATS2] Skipping map win/loss record - map name not available");
        return Plugin_Continue;
    }

    // Insert map if not exists, then log the match result
    char map_win_loss_query[1024];
    Format(map_win_loss_query, sizeof(map_win_loss_query),
           "WITH upserted_map AS (INSERT INTO maps (map_name) VALUES ('%s') ON CONFLICT (map_name) DO UPDATE SET map_name = EXCLUDED.map_name RETURNING map_id) INSERT INTO win_loss_log (map_id, win) SELECT map_id, %s FROM upserted_map",
           g_escaped_map_name, sec_forces_won ? "TRUE" : "FALSE");
    ExecuteQueryWithRetry(OnQueryComplete, map_win_loss_query, 0);

    return Plugin_Continue;
}
