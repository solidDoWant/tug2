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

// Accuracy (issue #9): rounds fired and rounds that hit, per weapon -> {shots, enemy_hits, friendly_hits}.
// Read from the game's server code (server_srv.so):
// - CINSWeaponBallistic::FireBullet raises weapon_fire once per round fired, with a "shots" key;
//   grenades, rockets and melee raise it through CINSWeapon::EmitWeaponGameEvent, without one.
// - Before raising it, in the same call (CINSPlayer::FireBullet -> FireGenericBullets ->
//   ApplyMultiDamage), the round's damage is applied, so each victim's player_hurt comes first, in the
//   same tick, with the bullet damage type and the shooter's active weapon.
// So bullet hits are noted as they arrive and claimed by the next weapon_fire in the same tick.
// weapon_fire is hooked pre: gg2_heavy_ammo deals the M107's area damage (also bullet damage) in its
// own weapon_fire hook, after this one, so it is left for the tick check to discard.
#define   DMG_BULLET (1 << 1)    // as in sdkhooks.inc, without needing the extension here
#define   SHOT_STATS 3    // shots, enemy_hits, friendly_hits
StringMap g_cache_shots[MAXPLAYERS + 1];
int       g_hit_tick[MAXPLAYERS + 1] = { -1, ... };    // tick of the unclaimed bullet hits below
bool      g_hit_enemy[MAXPLAYERS + 1];
bool      g_hit_friendly[MAXPLAYERS + 1];

// sm_mstats2_shot_check: checks the assumptions above against live play and logs the results at each
// round end, so they can be confirmed on the test server without anyone testing by hand.
ConVar    g_cvShotCheck;
int       g_check_last_weapon[MAXPLAYERS + 1];    // entity ref of the weapon that fired last
int       g_check_last_clip[MAXPLAYERS + 1];
int       g_check_clip_ok[MAXPLAYERS + 1];        // consecutive shots one round apart, as expected
int       g_check_clip_bad[MAXPLAYERS + 1];       // consecutive shots that weren't
int       g_check_name_bad[MAXPLAYERS + 1];       // player_hurt weapon differs from the active weapon
int       g_check_unclaimed[MAXPLAYERS + 1];      // bullet hits no shot claimed (expected for the M107)

// Per-round history (issue #10). FlushAllPlayerStats collects the lifetime-total updates for one
// player in g_batch instead of sending them one by one, adds a player_rounds row (and its
// player_round_weapons rows) recording the same numbers, and runs the lot as one transaction, so a
// period's sums can never disagree with the lifetime totals.
ArrayList g_batch;
#define   BATCH_QUERY_MAX 16384
char      g_history_query[BATCH_QUERY_MAX];

// Killstreaks run until the player dies, across round ends and map changes (issue #8). A map change
// disconnects every client slot and reconnects it, which resets the per-slot cache, so the current
// streak is parked here by SteamID on disconnect and picked up again when the player comes back.
// A player who leaves and rejoins within the window keeps it too (a crash or a quick reconnect);
// anyone gone longer starts again from 0.
#define   STREAK_CARRY_SECONDS 300
StringMap g_saved_streaks;    // steam_id -> {streak, GetTime() when saved}

// Playtime (issue #11): time on the Security team. g_play_start is the GetTime() the current stretch
// began, or 0 when the player isn't on Security; g_play_seconds is time not yet written to the DB.
int       g_play_start[MAXPLAYERS + 1];
int       g_play_seconds[MAXPLAYERS + 1];

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
    HookEvent("player_team", Event_PlayerTeam);
    HookEvent("weapon_fire", Event_WeaponFirePre, EventHookMode_Pre);

    g_cvShotCheck = CreateConVar("sm_mstats2_shot_check", "0", "Check the shot and hit counting against live play and log the results at each round end.", _, true, 0.0, true, 1.0);

    g_saved_streaks = new StringMap();

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
void ExecuteQueryWithRetry(Function originalCallback, const char[] query, any originalData = 0, int maxRetries = 2)
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
    Function originalCallback = pack.ReadFunction();
    any      originalData     = pack.ReadCell();
    int      retryCount       = pack.ReadCell();
    int      maxRetries       = pack.ReadCell();

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
    Function originalCallback = pack.ReadFunction();
    any      originalData     = pack.ReadCell();
    int      retryCount       = pack.ReadCell();
    int      maxRetries       = pack.ReadCell();

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
    PruneSavedStreaks();

    // Check if database connection is ready
    if (g_Database != null) return;

    LogMessage("[GG2 MSTATS2] Database unavailable at map start, attempting reconnection...");
    ReconnectDatabase();
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
        if (g_play_start[client] == 0) g_play_start[client] = GetTime();
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
    RestoreKillstreak(client);

    if (g_cache_shots[client] != null)
        g_cache_shots[client].Clear();
    else
        g_cache_shots[client] = new StringMap();
    g_hit_tick[client] = -1;
    ResetShotCheck(client);

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

    RunOrBatch(query, client);

    // Clear cache after flushing
    g_cache_kills[client]          = 0;
    g_cache_deaths[client]         = 0;
    g_cache_suicides[client]       = 0;
    g_cache_headshot_given[client] = 0;
    g_cache_headshot_taken[client] = 0;
    g_cache_suppressions[client]   = 0;
    g_cache_caps[client]           = 0;
    // The current streak carries on into the next round; only the recorded best is reset.
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
           "WITH upserted_weapons AS (INSERT INTO weapon_stats (weapon_name) VALUES %s ON CONFLICT (weapon_name) DO UPDATE SET weapon_name = EXCLUDED.weapon_name RETURNING weapon_id, weapon_name), weapon_kills AS (SELECT * FROM (VALUES %s) AS t(weapon_name, kill_count)) INSERT INTO %s (%s, weapon_id, kill_count) SELECT '%s', uw.weapon_id, wk.kill_count FROM weapon_kills wk JOIN upserted_weapons uw ON uw.weapon_name = wk.weapon_name ON CONFLICT (%s, weapon_id) DO UPDATE SET kill_count = %s.kill_count + EXCLUDED.kill_count, updated_at = CURRENT_TIMESTAMP",
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
    RunOrBatch(query, client);
}

void FlushAllPlayerStats(int client, int wins = 0, int losses = 0)
{
    if (g_Database == null) return;    // everything stays cached for the next flush
    if (StrEqual(g_SteamID[client], "") || StrEqual(g_SteamID[client], bawt_steam_id)) return;

    // Settle the values the history row records, so it and the total updates use the same numbers.
    AccumulatePlayTime(client);
    if (g_cache_killstreak[client] > g_cache_killstreak_max[client])
        g_cache_killstreak_max[client] = g_cache_killstreak[client];

    bool has_history = BuildHistoryQuery(client, wins, losses, g_history_query, sizeof(g_history_query));

    g_batch = new ArrayList(ByteCountToCells(BATCH_QUERY_MAX));
    if (has_history)
    {
        // player_rounds references player_stats. The row exists from RecordPlayer, but a missing one
        // must not fail the transaction and lose the totals with it.
        char ensure[160];
        Format(ensure, sizeof(ensure), "INSERT INTO player_stats (steam_id) VALUES ('%s') ON CONFLICT (steam_id) DO NOTHING", g_SteamID[client]);
        g_batch.PushString(ensure);
    }
    FlushPlayTime(client);
    FlushPlayerStats(client);
    FlushPlayerShots(client);
    FlushPlayerWeaponKills(client);
    FlushPlayerScore(client, wins, losses);
    if (has_history) g_batch.PushString(g_history_query);

    ArrayList queries = g_batch;
    g_batch           = null;
    if (queries.Length == 0)
    {
        delete queries;
        return;
    }
    ExecuteBatchWithRetry(queries, 0);
}

// Inside FlushAllPlayerStats, queries join its transaction; otherwise they run on their own.
void RunOrBatch(const char[] query, int client)
{
    if (g_batch != null)
        g_batch.PushString(query);
    else
        ExecuteQueryWithRetry(OnQueryComplete, query, client);
}

// The score change FlushPlayerScore would add, and whether it adds anything at all (it skips when
// there is no gain and no win or loss). The resource entity is gone during a map change.
bool PendingScore(int client, int wins, int losses, int &change)
{
    change       = 0;
    int resource = GetPlayerResourceEntity();
    if (resource == -1) return false;

    change = GetEntProp(resource, Prop_Send, "m_iPlayerScore", _, client) - g_iStartScore[client];
    if (change <= 0 && wins <= 0 && losses <= 0)
    {
        change = 0;
        return false;
    }
    return true;
}

// Builds the player_rounds insert for what this flush adds to the player's totals. Returns false
// when there is nothing to record.
bool BuildHistoryQuery(int client, int wins, int losses, char[] query, int maxlen)
{
    int score;
    PendingScore(client, wins, losses, score);

    // Per-weapon numbers: the union of the kill and shot caches.
    StringMap weapons = new StringMap();    // name -> {kills, shots, enemy_hits, friendly_hits}
    int       totals[SHOT_STATS];
    if (g_cache_weapon_kills[client] != null)
    {
        StringMapSnapshot snap = g_cache_weapon_kills[client].Snapshot();
        for (int i = 0; i < snap.Length; i++)
        {
            char name[64];
            snap.GetKey(i, name, sizeof(name));
            int row[4], kills;
            g_cache_weapon_kills[client].GetValue(name, kills);
            row[0] = kills;
            weapons.SetArray(name, row, sizeof(row));
        }
        delete snap;
    }
    if (g_cache_shots[client] != null)
    {
        StringMapSnapshot snap = g_cache_shots[client].Snapshot();
        for (int i = 0; i < snap.Length; i++)
        {
            char name[64];
            snap.GetKey(i, name, sizeof(name));
            int row[4], counts[SHOT_STATS];
            g_cache_shots[client].GetArray(name, counts, sizeof(counts));
            weapons.GetArray(name, row, sizeof(row));
            row[1] = counts[0];
            row[2] = counts[1];
            row[3] = counts[2];
            weapons.SetArray(name, row, sizeof(row));
            totals[0] += counts[0];
            totals[1] += counts[1];
            totals[2] += counts[2];
        }
        delete snap;
    }

    if (g_cache_kills[client] == 0 && g_cache_deaths[client] == 0 && g_cache_suicides[client] == 0
        && g_cache_headshot_given[client] == 0 && g_cache_headshot_taken[client] == 0 && g_cache_suppressions[client] == 0
        && g_cache_caps[client] == 0 && g_cache_killstreak_max[client] == 0 && score == 0 && wins == 0 && losses == 0
        && g_play_seconds[client] <= 0 && totals[0] == 0 && weapons.Size == 0)
    {
        delete weapons;
        return false;
    }

    char map[128], map_escaped[257];
    GetCurrentMap(map, sizeof(map));
    if (!g_Database.Escape(map, map_escaped, sizeof(map_escaped))) map_escaped[0] = '\0';

    char row_values[512];
    Format(row_values, sizeof(row_values), "('%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)",
           g_SteamID[client], map_escaped, g_cache_kills[client], g_cache_deaths[client], g_cache_suicides[client],
           g_cache_headshot_given[client], g_cache_headshot_taken[client], g_cache_suppressions[client], g_cache_caps[client],
           score, wins, losses, g_cache_killstreak_max[client], g_play_seconds[client] > 0 ? g_play_seconds[client] : 0,
           totals[0], totals[1], totals[2]);
    char round_insert[1024];
    Format(round_insert, sizeof(round_insert),
           "INSERT INTO player_rounds (steam_id, map_name, kills, deaths, suicides, headshot_given, headshot_taken, suppressions, caps, score, wins, losses, killstreak, play_time_seconds, shots, enemy_hits, friendly_hits) VALUES %s",
           row_values);

    if (weapons.Size == 0)
    {
        strcopy(query, maxlen, round_insert);
        delete weapons;
        return true;
    }

    char names[4096] = "", values[8192] = "";
    int  count       = 0;
    StringMapSnapshot snap = weapons.Snapshot();
    for (int i = 0; i < snap.Length; i++)
    {
        char name[64], escaped[129];
        snap.GetKey(i, name, sizeof(name));
        if (!g_Database.Escape(name, escaped, sizeof(escaped))) continue;
        int row[4];
        weapons.GetArray(name, row, sizeof(row));

        char name_value[160], value[256];
        Format(name_value, sizeof(name_value), "%s('%s')", count > 0 ? ", " : "", escaped);
        Format(value, sizeof(value), "%s('%s', %d, %d, %d, %d)", count > 0 ? ", " : "", escaped, row[0], row[1], row[2], row[3]);
        if (strlen(names) + strlen(name_value) >= sizeof(names) || strlen(values) + strlen(value) >= sizeof(values))
        {
            LogError("[GG2 MSTATS2] History weapon buffer full, dropping the rest after %d weapons", count);
            break;
        }
        StrCat(names, sizeof(names), name_value);
        StrCat(values, sizeof(values), value);
        count++;
    }
    delete snap;
    delete weapons;

    if (count == 0)
    {
        strcopy(query, maxlen, round_insert);
        return true;
    }
    Format(query, maxlen,
           "WITH r AS (%s RETURNING id), w AS (INSERT INTO weapon_stats (weapon_name) VALUES %s ON CONFLICT (weapon_name) DO UPDATE SET weapon_name = EXCLUDED.weapon_name RETURNING weapon_id, weapon_name) INSERT INTO player_round_weapons (round_id, weapon_id, kills, shots, enemy_hits, friendly_hits) SELECT r.id, w.weapon_id, v.kills, v.shots, v.enemy_hits, v.friendly_hits FROM r CROSS JOIN (VALUES %s) AS v(weapon_name, kills, shots, enemy_hits, friendly_hits) JOIN w ON w.weapon_name = v.weapon_name",
           round_insert, names, values);
    return true;
}

// Runs a flush's queries as one transaction, retrying on a lost connection like
// ExecuteQueryWithRetry. queries is deleted once it succeeds or is given up on.
void ExecuteBatchWithRetry(ArrayList queries, int retryCount)
{
    if (g_Database == null)
    {
        RetryBatchLater(queries, retryCount);
        return;
    }

    Transaction txn = new Transaction();
    char        query[BATCH_QUERY_MAX];
    for (int i = 0; i < queries.Length; i++)
    {
        queries.GetString(i, query, sizeof(query));
        txn.AddQuery(query);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(queries);
    pack.WriteCell(retryCount);
    g_Database.Execute(txn, OnBatchSuccess, OnBatchFailure, pack);
}

public void OnBatchSuccess(Database db, DataPack pack, int numQueries, DBResultSet[] results, any[] queryData)
{
    pack.Reset();
    ArrayList queries = pack.ReadCell();
    delete pack;
    delete queries;
}

public void OnBatchFailure(Database db, DataPack pack, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    pack.Reset();
    ArrayList queries    = pack.ReadCell();
    int       retryCount = pack.ReadCell();
    delete pack;

    if (StrContains(error, "no connection to the server", false) == -1)
    {
        char query[256];
        if (failIndex >= 0 && failIndex < queries.Length) queries.GetString(failIndex, query, sizeof(query));
        LogError("[GG2 MSTATS2] Stats transaction failed at query %d (%s...): %s", failIndex, query, error);
        delete queries;
        return;
    }

    LogError("[GG2 MSTATS2] Stats transaction failed due to connection loss - attempting reconnect and retry");
    ReconnectDatabase();
    RetryBatchLater(queries, retryCount);
}

void RetryBatchLater(ArrayList queries, int retryCount)
{
    if (retryCount >= 2)
    {
        LogError("[GG2 MSTATS2] Giving up on a stats transaction after %d retries", retryCount);
        delete queries;
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(queries);
    pack.WriteCell(retryCount + 1);
    CreateTimer(3.0, Timer_RetryBatch, pack);
}

public Action Timer_RetryBatch(Handle timer, DataPack pack)
{
    pack.Reset();
    ArrayList queries    = pack.ReadCell();
    int       retryCount = pack.ReadCell();
    delete pack;
    ExecuteBatchWithRetry(queries, retryCount);
    return Plugin_Stop;
}

void FlushPlayerScore(int client, int wins = 0, int losses = 0)
{
    int player_score_change;
    if (!PendingScore(client, wins, losses, player_score_change)) return;
    int player_current_score = g_iStartScore[client] + player_score_change;

    char score_query[512];
    g_Database.Format(score_query, sizeof(score_query),
                      "INSERT INTO player_stats (steam_id, score, wins, losses) VALUES ('%s', %i, %i, %i) ON CONFLICT (steam_id) DO UPDATE SET score = player_stats.score + %i, wins = player_stats.wins + %i, losses = player_stats.losses + %i, updated_at = CURRENT_TIMESTAMP",
                      g_SteamID[client], player_score_change, wins, losses, player_score_change, wins, losses);

    RunOrBatch(score_query, client);
    g_iStartScore[client] = player_current_score;
}

public void RecordPlayer(int client)
{
    // one last check for bawtness //
    if (StrEqual(g_SteamID[client], bawt_steam_id)) return;

    // Keep the player's latest name so the stats can be looked up by name. Database.Format escapes
    // %s, and the buffer allows for a name made entirely of characters that escaping doubles.
    char name[MAX_NAME_LENGTH];
    if (!GetClientName(client, name, sizeof(name))) name[0] = '\0';

    char query[1024];
    if (name[0])
    {
        g_Database.Format(query, sizeof(query),
                          "INSERT INTO player_stats (steam_id, name) VALUES ('%s', '%s') ON CONFLICT (steam_id) DO UPDATE SET name = EXCLUDED.name, updated_at = CURRENT_TIMESTAMP",
                          g_SteamID[client], name);
    }
    else
    {
        g_Database.Format(query, sizeof(query),
                          "INSERT INTO player_stats (steam_id) VALUES ('%s') ON CONFLICT (steam_id) DO UPDATE SET updated_at = CURRENT_TIMESTAMP",
                          g_SteamID[client]);
    }
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
        EndKillstreak(victim);
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
    EndKillstreak(victim);

    return Plugin_Continue;
}

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    NoteBulletHit(event);

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
    g_play_start[client] = 0;    // they're leaving: OnClientDisconnect must find nothing more to add

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

    // Insert map if not exists, then log the match result.
    // ExecuteQueryWithRetry checks for a null handle, but g_Database.Format below runs first and
    // would throw on one, so the round result has to be dropped explicitly when the database is
    // down. Without this the error surfaces as an invalid-handle exception at every round end for
    // the duration of an outage.
    if (g_Database == null)
    {
        LogError("[GG2 MSTATS2] Database unavailable at round end, map win/loss not recorded");
        return Plugin_Continue;
    }

    char map_name[128];
    GetCurrentMap(map_name, sizeof(map_name));

    char map_win_loss_query[1024];
    g_Database.Format(map_win_loss_query, sizeof(map_win_loss_query),
                      "WITH upserted_map AS (INSERT INTO map_stats (map_name) VALUES ('%s') ON CONFLICT (map_name) DO UPDATE SET map_name = EXCLUDED.map_name RETURNING map_id) INSERT INTO win_loss_log (map_id, win) SELECT map_id, %!s FROM upserted_map",
                      map_name, sec_forces_won ? "TRUE" : "FALSE");
    ExecuteQueryWithRetry(OnQueryComplete, map_win_loss_query, 0);

    return Plugin_Continue;
}

// A death or suicide ends the victim's streak. Record it as their best first: the best was otherwise
// only taken at a round end, so any streak that ended in a death mid-round was never recorded.
void EndKillstreak(int client)
{
    if (g_cache_killstreak[client] > g_cache_killstreak_max[client])
        g_cache_killstreak_max[client] = g_cache_killstreak[client];
    g_cache_killstreak[client] = 0;
}

void RestoreKillstreak(int client)
{
    int saved[2];
    if (StrEqual(g_SteamID[client], "") || !g_saved_streaks.GetArray(g_SteamID[client], saved, sizeof(saved))) return;

    g_saved_streaks.Remove(g_SteamID[client]);
    if (GetTime() - saved[1] <= STREAK_CARRY_SECONDS)
        g_cache_killstreak[client] = saved[0];
}

void PruneSavedStreaks()
{
    if (g_saved_streaks == null) return;

    StringMapSnapshot snap = g_saved_streaks.Snapshot();
    char              steam_id[32];
    int               saved[2];
    int               now = GetTime();
    for (int i = 0; i < snap.Length; i++)
    {
        snap.GetKey(i, steam_id, sizeof(steam_id));
        if (g_saved_streaks.GetArray(steam_id, saved, sizeof(saved)) && now - saved[1] > STREAK_CARRY_SECONDS)
            g_saved_streaks.Remove(steam_id);
    }
    delete snap;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Continue;

    // Close the current stretch on Security, if any, and open a new one if they're (still) on it.
    int now = GetTime();
    if (g_play_start[client] != 0)
    {
        g_play_seconds[client] += now - g_play_start[client];
        g_play_start[client] = 0;
    }
    if (event.GetInt("team") == TEAM_1_SEC)
        g_play_start[client] = now;

    return Plugin_Continue;
}

// Adds the player's time on Security since the last flush to player_stats.play_time_seconds.
// Moves the time since the current stretch on Security began into g_play_seconds.
void AccumulatePlayTime(int client)
{
    if (g_play_start[client] == 0) return;

    int now = GetTime();
    g_play_seconds[client] += now - g_play_start[client];
    g_play_start[client] = now;
}

void FlushPlayTime(int client)
{
    // Inside a batch, FlushAllPlayerStats has just accumulated, and the history row records exactly
    // g_play_seconds; accumulating again could add a second it doesn't have.
    if (g_batch == null) AccumulatePlayTime(client);

    if (g_play_seconds[client] <= 0) return;
    if (g_Database == null) return;    // kept for the next flush
    if (StrEqual(g_SteamID[client], "") || StrEqual(g_SteamID[client], bawt_steam_id)) return;

    char query[512];
    Format(query, sizeof(query),
           "INSERT INTO player_stats (steam_id, play_time_seconds) VALUES ('%s', %i) ON CONFLICT (steam_id) DO UPDATE SET play_time_seconds = player_stats.play_time_seconds + %i, updated_at = CURRENT_TIMESTAMP",
           g_SteamID[client], g_play_seconds[client], g_play_seconds[client]);
    RunOrBatch(query, client);
    g_play_seconds[client] = 0;
}

// Runs when a player leaves and, unlike the player_disconnect event, for every player on a map change.
public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;

    // The player_disconnect event's flush doesn't run on a map change, which used to lose everything
    // since the last round end. On a real leave the event has already flushed and this finds nothing.
    FlushAllPlayerStats(client);
    g_play_start[client]   = 0;
    g_play_seconds[client] = 0;    // a failed flush must not pass time on to the slot's next player

    // Park the streak for RestoreKillstreak. It isn't cleared here: on a real leave the
    // player_disconnect event may still flush the slot's stats, and InitPlayerCache resets the slot
    // for whoever connects next.
    if (g_cache_killstreak[client] > 0 && !StrEqual(g_SteamID[client], ""))
    {
        int saved[2];
        saved[0] = g_cache_killstreak[client];
        saved[1] = GetTime();
        g_saved_streaks.SetArray(g_SteamID[client], saved, sizeof(saved));
    }
}

// Notes a bullet hit by a human for the shot that fired it (see g_cache_shots).
void NoteBulletHit(Event event)
{
    if (GetGameState() != 4) return;
    if (!(event.GetInt("damagebits") & DMG_BULLET)) return;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (!IsValidPlayer(attacker) || IsFakeClient(attacker)) return;
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(victim) || victim == attacker) return;

    int tick = GetGameTickCount();
    if (g_hit_tick[attacker] != tick)
    {
        if (g_hit_tick[attacker] != -1) g_check_unclaimed[attacker]++;
        g_hit_tick[attacker]     = tick;
        g_hit_enemy[attacker]    = false;
        g_hit_friendly[attacker] = false;
    }
    if (GetClientTeam(victim) == GetClientTeam(attacker))
        g_hit_friendly[attacker] = true;
    else
        g_hit_enemy[attacker] = true;

    if (g_cvShotCheck.BoolValue)
    {
        char hurt_weapon[64], hurt_name[64], active[64];
        event.GetString("weapon", hurt_weapon, sizeof(hurt_weapon));
        StripWeaponPrefix(hurt_weapon, hurt_name, sizeof(hurt_name));
        ActiveWeaponName(attacker, active, sizeof(active));
        if (!StrEqual(hurt_name, active, false))
        {
            if (g_check_name_bad[attacker]++ < 3)
                LogMessage("[GG2 MSTATS2] shot check: %N hurt with \"%s\" while holding \"%s\"", attacker, hurt_weapon, active);
        }
    }
}

public Action Event_WeaponFirePre(Event event, const char[] name, bool dontBroadcast)
{
    if (GetGameState() != 4) return Plugin_Continue;
    if (event.GetInt("shots", -1) == -1) return Plugin_Continue;    // not a firearm round

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Continue;

    char weapon[64];
    if (!ActiveWeaponName(client, weapon, sizeof(weapon))) return Plugin_Continue;

    if (g_cache_shots[client] == null) g_cache_shots[client] = new StringMap();
    int counts[SHOT_STATS];
    g_cache_shots[client].GetArray(weapon, counts, sizeof(counts));
    counts[0]++;

    int tick = GetGameTickCount();
    if (g_hit_tick[client] == tick)
    {
        if (g_hit_enemy[client]) counts[1]++;
        if (g_hit_friendly[client]) counts[2]++;
    }
    else if (g_hit_tick[client] != -1)
    {
        g_check_unclaimed[client]++;
    }
    g_hit_tick[client] = -1;
    g_cache_shots[client].SetArray(weapon, counts, sizeof(counts));

    if (g_cvShotCheck.BoolValue) CheckClip(client);
    return Plugin_Continue;
}

// The active weapon's name as kills record it: the classname without "weapon_".
bool ActiveWeaponName(int client, char[] name, int maxlen)
{
    char classname[64];
    if (!GetClientWeapon(client, classname, sizeof(classname)) || classname[0] == '\0') return false;
    StripWeaponPrefix(classname, name, maxlen);
    return true;
}

void StripWeaponPrefix(const char[] weapon, char[] out, int maxlen)
{
    if (StrContains(weapon, "weapon_", false) == 0)
        strcopy(out, maxlen, weapon[7]);
    else
        strcopy(out, maxlen, weapon);
}

// One weapon_fire per round means the magazine drops by exactly one between consecutive shots of the
// same weapon (a rise is a reload, and doesn't count either way).
void CheckClip(int client)
{
    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon == -1 || !HasEntProp(weapon, Prop_Send, "m_iClip1")) return;

    int ref  = EntIndexToEntRef(weapon);
    int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
    if (ref == g_check_last_weapon[client] && clip < g_check_last_clip[client])
    {
        if (clip == g_check_last_clip[client] - 1)
            g_check_clip_ok[client]++;
        else if (g_check_clip_bad[client]++ < 3)
            LogMessage("[GG2 MSTATS2] shot check: %N's magazine went %d -> %d between two shots", client, g_check_last_clip[client], clip);
    }
    g_check_last_weapon[client] = ref;
    g_check_last_clip[client]   = clip;
}

void ResetShotCheck(int client)
{
    g_check_last_weapon[client] = INVALID_ENT_REFERENCE;
    g_check_last_clip[client]   = 0;
    g_check_clip_ok[client]     = 0;
    g_check_clip_bad[client]    = 0;
    g_check_name_bad[client]    = 0;
    g_check_unclaimed[client]   = 0;
}

void FlushPlayerShots(int client)
{
    if (g_cache_shots[client] == null || g_cache_shots[client].Size == 0) return;
    if (g_Database == null) return;    // kept for the next flush
    if (StrEqual(g_SteamID[client], "") || StrEqual(g_SteamID[client], bawt_steam_id)) return;

    if (g_cvShotCheck.BoolValue) LogShotCheck(client);

    StringMapSnapshot snap = g_cache_shots[client].Snapshot();
    char weapons_values[4096] = "";
    char shots_values[8192]   = "";
    int  count                = 0;
    for (int i = 0; i < snap.Length; i++)
    {
        char weapon[64], escaped[129];
        snap.GetKey(i, weapon, sizeof(weapon));
        int counts[SHOT_STATS];
        if (!g_cache_shots[client].GetArray(weapon, counts, sizeof(counts))) continue;
        if (!g_Database.Escape(weapon, escaped, sizeof(escaped))) continue;

        char weapon_value[160], shot_value[256];
        Format(weapon_value, sizeof(weapon_value), "%s('%s')", count > 0 ? ", " : "", escaped);
        Format(shot_value, sizeof(shot_value), "%s('%s', %d, %d, %d)", count > 0 ? ", " : "", escaped, counts[0], counts[1], counts[2]);
        if (strlen(weapons_values) + strlen(weapon_value) >= sizeof(weapons_values)
            || strlen(shots_values) + strlen(shot_value) >= sizeof(shots_values))
        {
            LogError("[GG2 MSTATS2] Shot buffer full, dropping the rest after %d weapons", count);
            break;
        }
        StrCat(weapons_values, sizeof(weapons_values), weapon_value);
        StrCat(shots_values, sizeof(shots_values), shot_value);
        count++;
    }
    delete snap;
    g_cache_shots[client].Clear();
    if (count == 0) return;

    char query[16384];
    Format(query, sizeof(query),
           "WITH upserted_weapons AS (INSERT INTO weapon_stats (weapon_name) VALUES %s ON CONFLICT (weapon_name) DO UPDATE SET weapon_name = EXCLUDED.weapon_name RETURNING weapon_id, weapon_name), shot_counts AS (SELECT * FROM (VALUES %s) AS t(weapon_name, shots, enemy_hits, friendly_hits)) INSERT INTO player_shots (steam_id, weapon_id, shots, enemy_hits, friendly_hits) SELECT '%s', uw.weapon_id, sc.shots, sc.enemy_hits, sc.friendly_hits FROM shot_counts sc JOIN upserted_weapons uw ON uw.weapon_name = sc.weapon_name ON CONFLICT (steam_id, weapon_id) DO UPDATE SET shots = player_shots.shots + EXCLUDED.shots, enemy_hits = player_shots.enemy_hits + EXCLUDED.enemy_hits, friendly_hits = player_shots.friendly_hits + EXCLUDED.friendly_hits, updated_at = CURRENT_TIMESTAMP",
           weapons_values, shots_values, g_SteamID[client]);
    RunOrBatch(query, client);
}

void LogShotCheck(int client)
{
    char  line[1024] = "";
    StringMapSnapshot snap = g_cache_shots[client].Snapshot();
    for (int i = 0; i < snap.Length; i++)
    {
        char weapon[64];
        snap.GetKey(i, weapon, sizeof(weapon));
        int counts[SHOT_STATS];
        g_cache_shots[client].GetArray(weapon, counts, sizeof(counts));
        Format(line, sizeof(line), "%s %s=%d/%d/%d", line, weapon, counts[0], counts[1], counts[2]);
    }
    delete snap;
    LogMessage("[GG2 MSTATS2] shot check: %N shots/enemy/friendly:%s | magazine steps ok %d, off %d | name mismatches %d | unclaimed bullet hits %d",
               client, line, g_check_clip_ok[client], g_check_clip_bad[client], g_check_name_bad[client], g_check_unclaimed[client]);
    ResetShotCheck(client);
}
