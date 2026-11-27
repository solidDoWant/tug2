// gg2_stats2 - stats v2 recorder (issue #44).
//
// Records raw game facts into the stats v2 tables: the match timeline (build, boot, map runs,
// rounds, survival levels, counterattacks), who was on which team and class when, every death with a
// human on either side, objectives, revives, heals, fire support calls, loadouts at spawn, and the
// per-round counters that are too many to keep one row each (shots, hits, damage, ...). Totals are never
// stored: the views in stats_05..07.sql derive them. See stats_01_schema.sql for the tables.
//
// It runs beside the old stats plugins (gg2_mstats2, gg2_medic_tracker, ...) while both are written, and
// touches none of their tables.
//
// Writing:
//   - Every row names its round by values the server already knows; the round key is one SQL call,
//     stats_round_id(boot, build, map start, map, mode, theater, load, round number, round start), which
//     creates whatever is missing. Nothing waits on the database to learn an id.
//   - Events are buffered and flushed every FLUSH_INTERVAL seconds or FLUSH_ROWS rows, and at round
//     start/end, disconnect and map end, in one transaction. A crash loses at most one interval.
//   - Times are boot time + engine time (to_timestamp(<boot unix> + <engine seconds>)): sub-second, and
//     never a 32-bit float of a Unix time, which would be ~2 minutes coarse.
//   - Connection errors are retried; anything else (a constraint the data broke) is logged with the
//     query and dropped, since resending it can never succeed and would block every later flush.
//   - A flush for a round that is over (its end, and anything after) ends with stats_refresh_round(), which
//     recomputes the round's cached results (stats_03_results.sql) from everything written for it.
//   - Recording is off until the stats_*.sql migrations have created the v2 tables in the server's
//     schema (checked at connect and each map start), so a server that does not list them records
//     nothing.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <classtemplate>
#include <theateritems>
#include <gg2_stats>

#define PLUGIN_VERSION "1.0.0"

#define FLUSH_INTERVAL 30.0
#define FLUSH_ROWS     200
#define MAX_BUFFERED   20000    // rows kept while the database is unreachable; older ones are dropped
#define STMT_MAX       16000    // longest statement built (multi-row inserts are split to fit)
#define RETRY_MAX      5

#define TEAM_SPECTATOR 1
#define TEAM_SECURITY  2
#define TEAM_INSURGENT 3

#define GAME_STATE_RUNNING 4

#define HEAL_GAP 1.5    // seconds between ticks that still count as one continuous heal

public Plugin myinfo =
{
    name        = "[INS] GG2 Stats v2",
    author      = "sdw",
    description = "Records raw game facts for the stats v2 schema (issue #44)",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

// ---------------------------------------------------------------------------------------------------
// Buffered rows. Each table's rows are kept as VALUES tuples (without the round_id, which is added at
// flush time as (SELECT id FROM r)) and inserted in chunks.
// ---------------------------------------------------------------------------------------------------

enum
{
    T_KILLS = 0,
    T_SPANS,
    T_FIRE,
    T_LEVELS,
    T_COUNTERATTACKS,
    T_COUNT
};

char g_tableInsert[T_COUNT][] = {
    "INSERT INTO kills (round_id, killed_at, victim_steam_id, victim_bot_name, victim_team, victim_bot_class_id, victim_x, victim_y, victim_z, attacker_steam_id, attacker_bot_name, attacker_team, attacker_bot_class_id, attacker_x, attacker_y, attacker_z, assister_steam_id, assister_bot_name, weapon_name, hitgroup, headshot, domination, revenge, savior, offensive, defensive, damagebits, customkill, attacker_stance, attacker_aim) VALUES ",
    "INSERT INTO player_spans (round_id, steam_id, started_at, ended_at, team, squad, squad_slot, class_template) VALUES ",
    "INSERT INTO v2_fire_support_calls (round_id, called_at, steam_id, support_type, target_x, target_y, target_z, failure_reason, refunded_at) VALUES ",
    "INSERT INTO survival_levels (round_id, level, reached_at) VALUES ",
    "INSERT INTO counterattacks (round_id, control_point, started_at, ended_at, finale) VALUES "
};

char g_tableSuffix[T_COUNT][] = {
    "",
    " ON CONFLICT DO NOTHING",
    "",
    " ON CONFLICT DO NOTHING",
    " ON CONFLICT DO NOTHING"
};

ArrayList g_rows[T_COUNT];    // VALUES tuples, each without its leading "((SELECT id FROM r), "
ArrayList g_stmts;            // whole round-scoped statements (each may use r), run after the tuples
ArrayList g_plainStmts;       // statements needing no round (sessions, names), run first
StringMap g_flushPlayers;     // steam ids referenced by buffered rows
StringMap g_flushWeapons;     // weapon names referenced by buffered rows
StringMap g_flushBotClasses;  // bot class templates referenced by buffered kills
StringMap g_flushItems;       // theater item names referenced by buffered loadouts
int       g_bufferedRows;

// ---------------------------------------------------------------------------------------------------
// Database and timeline state
// ---------------------------------------------------------------------------------------------------

Database g_db;
Database g_adminDb;           // punitive-persistence, for player_connections
bool     g_ready;             // connected and the v2 tables found
bool     g_disabled;          // no v2 tables in this server's schema: record nothing

int   g_bootUnix;             // Unix seconds the engine clock started at
char  g_buildCommit[96] = "unknown";
char  g_buildVersion[96] = "unknown";

bool  g_mapActive;
float g_mapStart;             // engine time
float g_lastMapEnd = -1.0;    // engine time the previous map ended; -1 after a (re)start
float g_loadSeconds = -1.0;
char  g_map[160], g_mode[64], g_theater[160];

int   g_round;                // current round number; 0 = no round yet on this map
float g_roundStart;
bool  g_roundHumans;          // a human was on a team this round, so the round is written at all
bool  g_roundOver;            // round_end fired; no spans until the next round_start
bool  g_closingRound;         // CloseAllAndFlush: the round's last rows (map end, next round, unload)
float g_roundLive;            // engine time play started (round_freeze_end); 0 = not yet
char  g_roundKey[1024];       // stats_round_id(...) for the current round

// counterattack in progress
bool  g_counterActive;
float g_counterStart;
int   g_counterPoint;
bool  g_counterFinale;

// MVP lookup, as gg2_discord does it
Handle  g_hFindTopPlayers;
Address g_pGameStats = Address_Null;

// ---------------------------------------------------------------------------------------------------
// Per-client state
// ---------------------------------------------------------------------------------------------------

char  g_sid[MAXPLAYERS + 1][24];    // SteamID64; empty for bots and unauthenticated

// The open span: a stretch on one team and class
bool  g_spanOpen[MAXPLAYERS + 1];
float g_spanStart[MAXPLAYERS + 1];
int   g_spanTeam[MAXPLAYERS + 1];
int   g_spanSquad[MAXPLAYERS + 1];
int   g_spanSlot[MAXPLAYERS + 1];
char  g_spanClass[MAXPLAYERS + 1][64];

// Round counters (player_rounds), since the last flush
int   g_suppressions[MAXPLAYERS + 1];
int   g_timesSuppressed[MAXPLAYERS + 1];
int   g_enemiesFlashed[MAXPLAYERS + 1];
int   g_teammatesFlashed[MAXPLAYERS + 1];
int   g_damageTaken[MAXPLAYERS + 1];
int   g_fallDamage[MAXPLAYERS + 1];
// What the game's round stats held at the last flush (they are cumulative within a round)
int   g_lastScore[MAXPLAYERS + 1];
int   g_lastCaptureTicks[MAXPLAYERS + 1];
int   g_lastResets[MAXPLAYERS + 1];

// Weapon counters (player_round_weapons): name -> int[W_COUNT]
enum
{
    W_SHOTS = 0,
    W_HIT_ENEMY,
    W_HIT_FRIENDLY,
    W_HEAD,
    W_CHEST,
    W_STOMACH,
    W_ARMS,
    W_LEGS,
    W_DMG_ENEMY,
    W_DMG_FRIENDLY,
    W_RELOADS,
    W_DEPLOYS,
    W_MS_DRAWN,
    W_COUNT
};
StringMap g_weapons[MAXPLAYERS + 1];

// Shot/hit attribution (as gg2_mstats2): player_hurt for a round fires in the same tick as, and
// before, that round's weapon_fire.
int   g_hitTick[MAXPLAYERS + 1] = { -1, ... };
bool  g_hitEnemy[MAXPLAYERS + 1];
bool  g_hitFriendly[MAXPLAYERS + 1];

// The last hit each victim took, for the kill's hitgroup
int   g_lastHitgroup[MAXPLAYERS + 1] = { -1, ... };
int   g_lastHitTick[MAXPLAYERS + 1];

int   g_blindTick[MAXPLAYERS + 1];  // tick player_blind fired, matched to the grenade's detonation

// Heals in progress, one per healer
bool  g_healOpen[MAXPLAYERS + 1];
int   g_healPatient[MAXPLAYERS + 1];
float g_healStart[MAXPLAYERS + 1];
float g_healLast[MAXPLAYERS + 1];
int   g_healHp[MAXPLAYERS + 1];
bool  g_healFull[MAXPLAYERS + 1];
ArrayList g_healHolds[MAXPLAYERS + 1];    // {start, end, reason} rows
float g_holdStart[MAXPLAYERS + 1] = { -1.0, ... };    // per medic

// Sessions survive map changes (SourceMod re-runs client callbacks at every map), so they are keyed by
// SteamID: steam id -> engine time connected.
StringMap g_sessionStart;

// ===================================================================================================
// Setup
// ===================================================================================================

public void OnPluginStart()
{
    CreateConVar("gg2_stats2_version", PLUGIN_VERSION, "gg2_stats2 version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    for (int t = 0; t < T_COUNT; t++)
        g_rows[t] = new ArrayList(ByteCountToCells(1536));   // a kill row with two bot classes is the longest
    g_stmts         = new ArrayList(ByteCountToCells(4096));
    g_plainStmts    = new ArrayList(ByteCountToCells(1024));
    g_flushPlayers  = new StringMap();
    g_flushWeapons  = new StringMap();
    g_flushBotClasses = new StringMap();
    g_flushItems    = new StringMap();
    g_sessionStart  = new StringMap();

    // Whole seconds of wall time minus engine uptime; a reload can land a second off, which
    // stats_round_id absorbs.
    g_bootUnix = GetTime() - RoundToFloor(GetEngineTime());
    LoadBuildInfo();
    PrepareGameStats();
    ClassTemplate_Init();

    HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
    HookEvent("round_freeze_end", Event_RoundFreezeEnd);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("round_level_advanced", Event_RoundLevelAdvanced);
    HookEvent("game_end", Event_GameEnd);
    HookEvent("player_team", Event_PlayerTeam);
    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("player_hurt", Event_PlayerHurt);
    HookEvent("player_suppressed", Event_PlayerSuppressed);
    HookEvent("player_falldamage", Event_PlayerFallDamage);
    HookEvent("player_blind", Event_PlayerBlind);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("player_changename", Event_PlayerChangeName);
    HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Pre);
    HookEvent("weapon_reload", Event_WeaponReload);
    HookEvent("weapon_deploy", Event_WeaponDeploy);
    HookEvent("time_weapon", Event_TimeWeapon);
    HookEvent("grenade_thrown", Event_GrenadeThrown);
    HookEvent("grenade_detonate", Event_GrenadeDetonate);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured);
    HookEvent("controlpoint_neutralized", Event_ControlPointNeutralized);
    HookEvent("object_destroyed", Event_ObjectDestroyed);

    CreateTimer(FLUSH_INTERVAL, Timer_Flush, _, TIMER_REPEAT);
    CreateTimer(1.0, Timer_Second, _, TIMER_REPEAT);

    Database.Connect(OnDatabaseConnected, "insurgency-stats");
    Database.Connect(OnAdminDatabaseConnected, "punitive-persistence");

    // Late load: pick up the map and whoever is already here. The round number comes from the game.
    if (IsServerProcessing() || GetClientCount(false) > 0)
    {
        StartMap(GetEngineTime() - GetGameTime());
        if (GameRules_GetProp("m_iGameState") >= 3)
            StartRound(false);
        for (int client = 1; client <= MaxClients; client++)
            if (IsClientInGame(client))
                OnClientPostAdminCheck(client);
    }
}

public void OnPluginEnd()
{
    CloseAllAndFlush();
}

// Build identity, written into the image by the Dockerfile from the Makefile's build arguments:
//   "Build" { "commit" "<git sha>[-dirty]" "version" "<image tag>" }
void LoadBuildInfo()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/gg2_build.cfg");
    KeyValues kv = new KeyValues("Build");
    if (kv.ImportFromFile(path))
    {
        kv.GetString("commit", g_buildCommit, sizeof(g_buildCommit), "unknown");
        kv.GetString("version", g_buildVersion, sizeof(g_buildVersion), "unknown");
    }
    else
    {
        LogMessage("[STATS2] %s missing; recording the build as unknown", path);
    }
    delete kv;
}

void PrepareGameStats()
{
    GameData conf = new GameData("tug2.games");
    if (conf == null)
    {
        LogError("[STATS2] Missing gamedata tug2.games: no MVP, round score or capture ticks");
        return;
    }
    g_pGameStats = conf.GetAddress("INSServerGameStats");
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CINSServerGameStats::FindTopPlayers"))
    {
        PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, _, VENCODE_FLAG_COPYBACK);
        PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, _, VENCODE_FLAG_COPYBACK);
        PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
        g_hFindTopPlayers = EndPrepSDKCall();
    }
    delete conf;
    if (g_hFindTopPlayers == null || g_pGameStats == Address_Null)
        LogError("[STATS2] CINSServerGameStats unavailable: no MVP, round score or capture ticks");
}

// ===================================================================================================
// Database
// ===================================================================================================

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[STATS2] Could not connect to insurgency-stats: %s; retrying in 30 s", error);
        CreateTimer(30.0, Timer_Reconnect);
        return;
    }
    g_db = db;
    CheckTables();
}

// The v2 tables exist once the stats_*.sql migrations have run in this server's schema; stats_round_id
// stands for them all. Without them this server does not record v2 stats. ::int, since FetchInt reads
// a PostgreSQL boolean as 0.
void CheckTables()
{
    g_db.Query(OnTablesChecked, "SELECT (to_regproc('stats_round_id') IS NOT NULL)::int, current_schema()");
}

public Action Timer_Reconnect(Handle timer)
{
    if (g_db == null)
        Database.Connect(OnDatabaseConnected, "insurgency-stats");
    return Plugin_Stop;
}

public void OnTablesChecked(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null || !results.FetchRow())
    {
        LogError("[STATS2] Table check failed: %s", error);
        return;
    }
    char schema[128];
    results.FetchString(1, schema, sizeof(schema));
    if (results.FetchInt(0) == 0)
    {
        if (!g_disabled)
            LogMessage("[STATS2] No stats v2 tables in schema %s (stats_*.sql not applied): not recording", schema);
        g_disabled = true;
        ClearBuffers();
        return;
    }
    g_disabled = false;
    g_ready = true;
    LogMessage("[STATS2] Recording into schema %s", schema);
}

public void OnAdminDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[STATS2] Could not connect to punitive-persistence: %s; IP history not recorded", error);
        return;
    }
    g_adminDb = db;
}

void ClearBuffers()
{
    for (int t = 0; t < T_COUNT; t++)
        g_rows[t].Clear();
    g_stmts.Clear();
    g_plainStmts.Clear();
    g_flushPlayers.Clear();
    g_flushWeapons.Clear();
    g_flushBotClasses.Clear();
    g_flushItems.Clear();
    g_bufferedRows = 0;
}

// ===================================================================================================
// SQL formatting helpers
// ===================================================================================================

// A string literal: single quotes doubled (standard_conforming_strings is on).
void Quote(const char[] value, char[] out, int maxlen)
{
    int j = 0;
    if (j < maxlen - 1) out[j++] = '\'';
    for (int i = 0; value[i] != '\0' && j < maxlen - 3; i++)
    {
        if (value[i] == '\'') out[j++] = '\'';
        out[j++] = value[i];
    }
    out[j++] = '\'';
    out[j]   = '\0';
}

// A literal or NULL when empty.
void QuoteOrNull(const char[] value, char[] out, int maxlen)
{
    if (value[0] == '\0')
        strcopy(out, maxlen, "NULL");
    else
        Quote(value, out, maxlen);
}

// An instant from engine time.
void Ts(float engineTime, char[] out, int maxlen)
{
    Format(out, maxlen, "to_timestamp(%d+%.3f)", g_bootUnix, engineTime);
}

void TeamName(int team, char[] out, int maxlen)
{
    switch (team)
    {
        case TEAM_SPECTATOR: strcopy(out, maxlen, "'spectator'");
        case TEAM_SECURITY: strcopy(out, maxlen, "'security'");
        case TEAM_INSURGENT: strcopy(out, maxlen, "'insurgents'");
        default: strcopy(out, maxlen, "NULL");
    }
}

void StripWeaponPrefix(const char[] weapon, char[] out, int maxlen)
{
    if (StrContains(weapon, "weapon_", false) == 0)
        strcopy(out, maxlen, weapon[7]);
    else
        strcopy(out, maxlen, weapon);
}

bool IsHuman(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client)
        && g_sid[client][0] != '\0';
}

bool IsLive()
{
    return GameRules_GetProp("m_iGameState") == GAME_STATE_RUNNING;
}

void NotePlayer(const char[] sid)
{
    if (sid[0] != '\0') g_flushPlayers.SetValue(sid, true);
}

void NoteWeapon(const char[] weapon)
{
    if (weapon[0] != '\0') g_flushWeapons.SetValue(weapon, true);
}

// Rebuilds g_roundKey from the current map and round.
void BuildRoundKey()
{
    char commit[200], version[200], map[330], mode[140], theater[330], load[32], boot[64], mapTs[64], roundTs[64];
    Quote(g_buildCommit, commit, sizeof(commit));
    Quote(g_buildVersion, version, sizeof(version));
    Quote(g_map, map, sizeof(map));
    Quote(g_mode, mode, sizeof(mode));
    QuoteOrNull(g_theater, theater, sizeof(theater));
    if (g_loadSeconds >= 0.0)
        Format(load, sizeof(load), "%.3f", g_loadSeconds);
    else
        strcopy(load, sizeof(load), "NULL");
    Format(boot, sizeof(boot), "to_timestamp(%d)", g_bootUnix);
    Ts(g_mapStart, mapTs, sizeof(mapTs));
    Ts(g_roundStart, roundTs, sizeof(roundTs));
    Format(g_roundKey, sizeof(g_roundKey), "stats_round_id(%s, %s, %s, %s, %s, %s, %s, %s, %d::smallint, %s)",
           boot, commit, version, mapTs, map, mode, theater, load, g_round, roundTs);
}

bool HaveRound()
{
    return g_mapActive && g_round > 0;
}

void AddRow(int table, const char[] tuple)
{
    if (g_disabled) return;
    if (g_bufferedRows >= MAX_BUFFERED)
    {
        static int dropped;
        if (dropped++ % 1000 == 0)
            LogError("[STATS2] Buffer full (database unreachable?): dropping rows (%d so far)", dropped);
        return;
    }
    g_rows[table].PushString(tuple);
    g_bufferedRows++;
    if (g_bufferedRows >= FLUSH_ROWS) Flush();
}

void AddPlain(const char[] stmt)
{
    if (g_disabled || g_plainStmts.Length >= MAX_BUFFERED) return;
    g_plainStmts.PushString(stmt);
}

void AddStmt(const char[] stmt)
{
    if (g_disabled || g_bufferedRows >= MAX_BUFFERED) return;
    g_stmts.PushString(stmt);
    g_bufferedRows++;
}

// ===================================================================================================
// Flushing
// ===================================================================================================

public Action Timer_Flush(Handle timer)
{
    EmitAllCounters();
    Flush();
    return Plugin_Continue;
}

// Writes everything buffered in one transaction. Must run before the round key changes.
void Flush()
{
    if (!g_ready || g_db == null) return;
    if (g_bufferedRows == 0 && g_plainStmts.Length == 0) return;

    bool haveRoundRows = g_stmts.Length > 0;
    for (int t = 0; t < T_COUNT && !haveRoundRows; t++)
        haveRoundRows = g_rows[t].Length > 0;
    if (haveRoundRows && !HaveRound())
    {
        // Rows with no round to hang them on (should not happen: they are only made in a round).
        LogError("[STATS2] Dropping %d rows recorded outside a round", g_bufferedRows);
        ClearBuffers();
        return;
    }

    ArrayList queries = new ArrayList(ByteCountToCells(STMT_MAX + 1));
    char stmt[STMT_MAX + 1];

    // Players and weapons first: everything references them.
    BuildKeyInsert(queries, g_flushPlayers, "INSERT INTO players (steam_id) VALUES ", "", " ON CONFLICT DO NOTHING");
    BuildKeyInsert(queries, g_flushWeapons, "INSERT INTO weapons (weapon_name) VALUES ", "'", " ON CONFLICT DO NOTHING");
    // Small-id lookups: insert only names not there yet, so their identity sequences don't advance
    // on every flush (ON CONFLICT alone would use up a smallint key in weeks).
    BuildKeyInsert(queries, g_flushBotClasses, "INSERT INTO bot_classes (class_template) SELECT n FROM (VALUES ", "'",
                   ") v(n) WHERE NOT EXISTS (SELECT 1 FROM bot_classes b WHERE b.class_template = v.n) ON CONFLICT DO NOTHING");
    BuildKeyInsert(queries, g_flushItems, "INSERT INTO items (item_name) SELECT n FROM (VALUES ", "'",
                   ") v(n) WHERE NOT EXISTS (SELECT 1 FROM items i WHERE i.item_name = v.n) ON CONFLICT DO NOTHING");

    for (int i = 0; i < g_plainStmts.Length; i++)
    {
        g_plainStmts.GetString(i, stmt, sizeof(stmt));
        queries.PushString(stmt);
    }

    if (haveRoundRows)
    {
        char head[1100];
        Format(head, sizeof(head), "WITH r AS (SELECT %s AS id) ", g_roundKey);
        for (int t = 0; t < T_COUNT; t++)
            BuildTupleInserts(queries, head, t);
        for (int i = 0; i < g_stmts.Length; i++)
        {
            char body[STMT_MAX - 1100];
            g_stmts.GetString(i, body, sizeof(body));
            Format(stmt, sizeof(stmt), "%s%s", head, body);
            queries.PushString(stmt);
        }
        // A round that is over gets its cached results (re)computed with everything written for it,
        // in the same transaction (stats_03_results.sql). It never fails the flush.
        if (g_roundOver || g_closingRound)
        {
            Format(stmt, sizeof(stmt), "%sSELECT stats_refresh_round((SELECT id FROM r))", head);
            queries.PushString(stmt);
        }
    }

    ClearBuffers();
    Execute(queries, 0);
}

// One multi-row insert (or more, if it would not fit) of the keys in a set.
void BuildKeyInsert(ArrayList queries, StringMap keys, const char[] insert, const char[] quote, const char[] suffix)
{
    if (keys.Size == 0) return;
    StringMapSnapshot snap = keys.Snapshot();
    char stmt[STMT_MAX + 1], key[200], value[420];
    stmt[0] = '\0';
    for (int i = 0; i < snap.Length; i++)
    {
        snap.GetKey(i, key, sizeof(key));
        if (quote[0] != '\0')
        {
            char quoted[410];
            Quote(key, quoted, sizeof(quoted));
            Format(value, sizeof(value), "(%s)", quoted);
        }
        else
        {
            Format(value, sizeof(value), "(%s)", key);
        }
        if (stmt[0] != '\0' && strlen(stmt) + strlen(value) + strlen(suffix) + 2 >= STMT_MAX)
        {
            StrCat(stmt, sizeof(stmt), suffix);
            queries.PushString(stmt);
            stmt[0] = '\0';
        }
        if (stmt[0] == '\0')
            strcopy(stmt, sizeof(stmt), insert);
        else
            StrCat(stmt, sizeof(stmt), ",");
        StrCat(stmt, sizeof(stmt), value);
    }
    delete snap;
    if (stmt[0] != '\0')
    {
        StrCat(stmt, sizeof(stmt), suffix);
        queries.PushString(stmt);
    }
}

void BuildTupleInserts(ArrayList queries, const char[] head, int table)
{
    if (g_rows[table].Length == 0) return;
    char stmt[STMT_MAX + 1], tuple[1536];
    int  base = strlen(head) + strlen(g_tableInsert[table]) + strlen(g_tableSuffix[table]);
    stmt[0]   = '\0';
    for (int i = 0; i < g_rows[table].Length; i++)
    {
        g_rows[table].GetString(i, tuple, sizeof(tuple));
        if (stmt[0] != '\0' && strlen(stmt) + strlen(tuple) + base + 32 >= STMT_MAX)
        {
            StrCat(stmt, sizeof(stmt), g_tableSuffix[table]);
            queries.PushString(stmt);
            stmt[0] = '\0';
        }
        if (stmt[0] == '\0')
            Format(stmt, sizeof(stmt), "%s%s", head, g_tableInsert[table]);
        else
            StrCat(stmt, sizeof(stmt), ",");
        StrCat(stmt, sizeof(stmt), "((SELECT id FROM r),");
        StrCat(stmt, sizeof(stmt), tuple);
        StrCat(stmt, sizeof(stmt), ")");
    }
    if (stmt[0] != '\0')
    {
        StrCat(stmt, sizeof(stmt), g_tableSuffix[table]);
        queries.PushString(stmt);
    }
}

void Execute(ArrayList queries, int attempt)
{
    Transaction txn = new Transaction();
    char stmt[STMT_MAX + 1];
    for (int i = 0; i < queries.Length; i++)
    {
        queries.GetString(i, stmt, sizeof(stmt));
        txn.AddQuery(stmt);
    }
    DataPack pack = new DataPack();
    pack.WriteCell(queries);
    pack.WriteCell(attempt);
    g_db.Execute(txn, OnFlushDone, OnFlushFailed, pack);
}

public void OnFlushDone(Database db, DataPack pack, int numQueries, DBResultSet[] results, any[] queryData)
{
    pack.Reset();
    ArrayList queries = pack.ReadCell();
    delete queries;
    delete pack;
}

public void OnFlushFailed(Database db, DataPack pack, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    pack.Reset();
    ArrayList queries = pack.ReadCell();
    int attempt = pack.ReadCell();
    delete pack;

    // Only a lost connection is worth resending; a constraint or type error never goes away.
    bool connection = StrContains(error, "connection", false) != -1 || StrContains(error, "terminat", false) != -1
                   || StrContains(error, "timeout", false) != -1 || StrContains(error, "could not", false) != -1;
    if (connection && attempt < RETRY_MAX)
    {
        LogError("[STATS2] Flush failed (%s); retry %d of %d in 10 s", error, attempt + 1, RETRY_MAX);
        DataPack retry = new DataPack();
        retry.WriteCell(queries);
        retry.WriteCell(attempt + 1);
        CreateTimer(10.0, Timer_Retry, retry);
        return;
    }

    char stmt[STMT_MAX + 1];
    if (failIndex >= 0 && failIndex < queries.Length)
        queries.GetString(failIndex, stmt, sizeof(stmt));
    LogError("[STATS2] Flush dropped (%s) at query %d of %d: %.900s", error, failIndex + 1, numQueries, stmt);
    delete queries;
}

public Action Timer_Retry(Handle timer, DataPack pack)
{
    pack.Reset();
    ArrayList queries = pack.ReadCell();
    int attempt = pack.ReadCell();
    delete pack;
    if (g_db == null)
    {
        delete queries;
        return Plugin_Stop;
    }
    Execute(queries, attempt);
    return Plugin_Stop;
}

// ===================================================================================================
// Map and round timeline
// ===================================================================================================

public void OnMapStart()
{
    float now = GetEngineTime();
    g_loadSeconds = g_lastMapEnd >= 0.0 ? now - g_lastMapEnd : -1.0;
    StartMap(now);
    // A first boot can connect before DatabaseMigrator has created the tables.
    if (g_disabled && g_db != null)
        CheckTables();
}

void StartMap(float startedAt)
{
    g_mapActive   = true;
    g_mapStart    = startedAt;
    g_round       = 0;
    g_roundOver   = false;
    g_roundHumans = false;
    g_counterActive = false;
    GetCurrentMap(g_map, sizeof(g_map));
    ConVar cv = FindConVar("mp_gamemode");
    if (cv != null) cv.GetString(g_mode, sizeof(g_mode));
    else strcopy(g_mode, sizeof(g_mode), "unknown");
    cv = FindConVar("mp_theater_override");
    if (cv != null) cv.GetString(g_theater, sizeof(g_theater));
    else g_theater[0] = '\0';
}

public void OnMapEnd()
{
    CloseAllAndFlush();
    g_mapActive  = false;
    g_round      = 0;
    g_lastMapEnd = GetEngineTime();
}

// Closes every open span, heal and counterattack, writes all counters, and flushes.
void CloseAllAndFlush()
{
    if (HaveRound())
    {
        float now = GetEngineTime();
        for (int client = 1; client <= MaxClients; client++)
        {
            CloseSpan(client, now);
            CloseHeal(client);
        }
        EndCounterattack(now);
        EmitAllCounters();
    }
    g_closingRound = true;
    Flush();
    g_closingRound = false;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // Everything of the previous round goes out under its own key first.
    CloseAllAndFlush();
    StartRound(true);
    return Plugin_Continue;
}

void StartRound(bool fresh)
{
    if (!g_mapActive) StartMap(GetEngineTime() - GetGameTime());
    g_round       = GameRules_GetProp("m_iRoundPlayedCount") + 1;
    g_roundStart  = GetEngineTime();
    g_roundOver   = false;
    g_roundHumans = false;
    g_roundLive   = fresh ? 0.0 : (GameRules_GetProp("m_iGameState") == GAME_STATE_RUNNING ? g_roundStart : 0.0);
    g_counterActive = false;
    BuildRoundKey();

    // The game resets its round stats at round start; a late load keeps what is there.
    for (int client = 1; client <= MaxClients; client++)
    {
        if (fresh)
        {
            g_lastScore[client]        = 0;
            g_lastCaptureTicks[client] = 0;
            g_lastResets[client]       = 0;
        }
        else if (IsHuman(client))
        {
            g_lastScore[client]        = GameStat(client, 20);
            g_lastCaptureTicks[client] = GameStat(client, 12);
            g_lastResets[client]       = GameStat(client, 11);
        }
        if (IsHuman(client))
            OpenSpan(client, GetClientTeam(client), g_roundStart);
    }
}

public void Event_RoundFreezeEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound()) return;
    g_roundLive = GetEngineTime();
    // Nobody playing yet: the round end writes it if someone joins (Event_RoundEnd).
    if (!g_roundHumans) return;
    char ts[64], stmt[256];
    Ts(g_roundLive, ts, sizeof(ts));
    Format(stmt, sizeof(stmt), "UPDATE rounds SET live_at = %s WHERE round_id = (SELECT id FROM r)", ts);
    AddStmt(stmt);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound()) return;
    float now = GetEngineTime();

    // The round row is written only if a human was on a team: the round_end the game fires when the
    // server empties is not a played round.
    if (g_roundHumans)
    {
        char ts[64], live[64], winner[24], reason[24], mvp[32], stmt[640];
        Ts(now, ts, sizeof(ts));
        if (g_roundLive > 0.0) Ts(g_roundLive, live, sizeof(live));
        else strcopy(live, sizeof(live), "NULL");
        TeamName(event.GetInt("winner"), winner, sizeof(winner));
        if (event.GetInt("winner") < TEAM_SECURITY) strcopy(winner, sizeof(winner), "NULL");
        switch (event.GetInt("reason"))
        {
            case 0: strcopy(reason, sizeof(reason), "'objective'");
            case 1: strcopy(reason, sizeof(reason), "'elimination'");
            case 2: strcopy(reason, sizeof(reason), "'time_expired'");
            case 3: strcopy(reason, sizeof(reason), "'draw'");
            default: strcopy(reason, sizeof(reason), "NULL");
        }
        int best = FindRoundMvp();
        if (best > 0)
        {
            strcopy(mvp, sizeof(mvp), g_sid[best]);
            NotePlayer(g_sid[best]);
        }
        else
        {
            strcopy(mvp, sizeof(mvp), "NULL");
        }
        Format(stmt, sizeof(stmt),
               "UPDATE rounds SET ended_at = %s, live_at = COALESCE(live_at, %s), winner = %s, end_reason = %s, mvp_steam_id = %s WHERE round_id = (SELECT id FROM r)",
               ts, live, winner, reason, mvp);
        AddStmt(stmt);
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        CloseSpan(client, now);
        CloseHeal(client);
    }
    EndCounterattack(now);
    EmitAllCounters();
    g_roundOver = true;
    Flush();
}

public void Event_RoundLevelAdvanced(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound()) return;
    char ts[64], tuple[128];
    Ts(GetEngineTime(), ts, sizeof(ts));
    Format(tuple, sizeof(tuple), "%d,%s", event.GetInt("level"), ts);
    AddRow(T_LEVELS, tuple);
}

public void Event_GameEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound()) return;
    char ts[64], stmt[256];
    Ts(GetEngineTime(), ts, sizeof(ts));
    Format(stmt, sizeof(stmt),
           "UPDATE map_runs SET game_over_at = %s WHERE map_run_id = (SELECT map_run_id FROM rounds WHERE round_id = (SELECT id FROM r))",
           ts);
    AddStmt(stmt);
    Flush();
}

// The game's own round MVP on the players' side (see gg2_discord's FindMvp); 0 if a bot or none.
int FindRoundMvp()
{
    if (g_hFindTopPlayers == null || g_pGameStats == Address_Null) return 0;
    int top[2] = { -1, -1 };
    SDKCall(g_hFindTopPlayers, g_pGameStats, top[0], top[1], true);
    int sec = top[0];
    if (!IsHuman(sec) || GetClientTeam(sec) != TEAM_SECURITY || GameStat(sec, 20) <= 0) return 0;
    return sec;
}

// The game's round stat for a player: CINSServerGameStats block at +0x18 + entindex*0x594, round copy
// at +0x118, 4 bytes per stat id (20 Score, 12 ObjectiveCaptureTicks, 11 ObjectivesReset).
int GameStat(int client, int id)
{
    if (g_pGameStats == Address_Null) return 0;
    int offset = 0x18 + client * 0x594 + 0x118 + 4 * id;
    return LoadFromAddress(g_pGameStats + view_as<Address>(offset), NumberType_Int32);
}

public Action Timer_Second(Handle timer)
{
    if (!HaveRound()) return Plugin_Continue;
    float now = GetEngineTime();

    // Heals with no tick for a while, or that reached full health, are over.
    for (int healer = 1; healer <= MaxClients; healer++)
    {
        if (g_healOpen[healer] && (g_healFull[healer] || now - g_healLast[healer] > HEAL_GAP))
            CloseHeal(healer);
    }

    // Counterattacks (checkpoint): the game exposes only whether one is on.
    if (!g_roundOver)
    {
        bool on = view_as<bool>(GameRules_GetProp("m_bCounterAttack"));
        if (on && !g_counterActive)
        {
            g_counterActive = true;
            g_counterStart  = now;
            g_counterPoint  = Ins_ObjectiveResource_GetPropSafe("m_nActivePushPointIndex");
            int numPoints   = Ins_ObjectiveResource_GetPropSafe("m_iNumControlPoints");
            g_counterFinale = numPoints > 0 && g_counterPoint + 1 == numPoints;
            // Written once, when it ends (EndCounterattack): one row, never an upsert of itself.
        }
        else if (!on && g_counterActive)
        {
            EndCounterattack(now);
        }
    }
    return Plugin_Continue;
}

void EndCounterattack(float now)
{
    if (!g_counterActive) return;
    g_counterActive = false;
    char start[64], end[64], tuple[200];
    Ts(g_counterStart, start, sizeof(start));
    Ts(now, end, sizeof(end));
    Format(tuple, sizeof(tuple), "%d,%s,%s,%s", g_counterPoint < 0 ? 0 : g_counterPoint, start, end,
           g_counterFinale ? "true" : "false");
    AddRow(T_COUNTERATTACKS, tuple);
}

// The objective resource's props, read straight from the entity (gg2_insurgency's natives need its
// library loaded; this does not).
int Ins_ObjectiveResource_GetPropSafe(const char[] prop)
{
    int ent = FindEntityByClassname(-1, "ins_objective_resource");
    if (ent == -1 || !HasEntProp(ent, Prop_Send, prop)) return -1;
    return GetEntProp(ent, Prop_Send, prop);
}

// ===================================================================================================
// Players: sessions, names, spans
// ===================================================================================================

public void OnClientPostAdminCheck(int client)
{
    g_sid[client][0] = '\0';
    ResetClientCounters(client);
    if (IsFakeClient(client)) return;
    if (!GetClientAuthId(client, AuthId_SteamID64, g_sid[client], sizeof(g_sid[])) || !IsAllDigits(g_sid[client]))
    {
        g_sid[client][0] = '\0';
        return;
    }

    // A new session unless this SteamID is already in one (a map change re-runs this callback).
    float start;
    if (g_sessionStart.GetValue(g_sid[client], start)) return;
    start = GetEngineTime();
    g_sessionStart.SetValue(g_sid[client], start);

    char ts[64], name[MAX_NAME_LENGTH], qname[2 * MAX_NAME_LENGTH + 3], stmt[512];
    Ts(start, ts, sizeof(ts));
    NotePlayer(g_sid[client]);
    Format(stmt, sizeof(stmt), "INSERT INTO sessions (steam_id, connected_at) VALUES (%s, %s) ON CONFLICT DO NOTHING",
           g_sid[client], ts);
    AddPlain(stmt);
    GetClientName(client, name, sizeof(name));
    Quote(name, qname, sizeof(qname));
    Format(stmt, sizeof(stmt), "INSERT INTO name_changes (steam_id, connected_at, changed_at, name) VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING",
           g_sid[client], ts, ts, qname);
    AddPlain(stmt);

    // IP history goes to the admin database only, keyed like the session.
    char ip[64];
    if (g_adminDb != null && GetClientIP(client, ip, sizeof(ip)))
    {
        char qip[80], q[256];
        Quote(ip, qip, sizeof(qip));
        Format(q, sizeof(q), "INSERT INTO player_connections (steam_id, connected_at, ip) VALUES (%s, %s, %s::inet) ON CONFLICT DO NOTHING",
               g_sid[client], ts, qip);
        g_adminDb.Query(OnAdminQuery, q);
    }

    // Joined mid-round already on a team (late load): open their span.
    if (HaveRound() && !g_roundOver && GetClientTeam(client) >= TEAM_SPECTATOR)
        OpenSpan(client, GetClientTeam(client), GetEngineTime());
}

public void OnAdminQuery(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null) LogError("[STATS2] player_connections insert failed: %s", error);
}

bool IsAllDigits(const char[] s)
{
    if (s[0] == '\0') return false;
    for (int i = 0; s[i] != '\0'; i++)
        if (s[i] < '0' || s[i] > '9') return false;
    return true;
}

public void Event_PlayerChangeName(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client)) return;
    float start;
    if (!g_sessionStart.GetValue(g_sid[client], start)) return;
    char newname[MAX_NAME_LENGTH], qname[2 * MAX_NAME_LENGTH + 3], connected[64], now[64], stmt[512];
    event.GetString("newname", newname, sizeof(newname));
    Quote(newname, qname, sizeof(qname));
    Ts(start, connected, sizeof(connected));
    Ts(GetEngineTime(), now, sizeof(now));
    Format(stmt, sizeof(stmt), "INSERT INTO name_changes (steam_id, connected_at, changed_at, name) VALUES (%s, %s, %s, %s) ON CONFLICT DO NOTHING",
           g_sid[client], connected, now, qname);
    AddPlain(stmt);
}

// A real disconnect (not a map change).
public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client)) return Plugin_Continue;

    float now = GetEngineTime();
    if (HaveRound())
    {
        CloseSpan(client, now);
        CloseHealsOf(client);
        EmitCounters(client);
    }

    float start;
    if (g_sessionStart.GetValue(g_sid[client], start))
    {
        char reason[256], qreason[520], connected[64], ended[64], stmt[1024];
        event.GetString("reason", reason, sizeof(reason));
        QuoteOrNull(reason, qreason, sizeof(qreason));
        Ts(start, connected, sizeof(connected));
        Ts(now, ended, sizeof(ended));
        Format(stmt, sizeof(stmt), "UPDATE sessions SET disconnected_at = %s, disconnect_reason = %s WHERE steam_id = %s AND connected_at = %s",
               ended, qreason, g_sid[client], connected);
        AddPlain(stmt);
        g_sessionStart.Remove(g_sid[client]);
    }
    return Plugin_Continue;
}

public void OnClientDisconnect(int client)
{
    // Map changes come through here too; the disconnect event above has already handled a real one.
    if (HaveRound() && IsHuman(client))
    {
        CloseSpan(client, GetEngineTime());
        CloseHealsOf(client);
        EmitCounters(client);
    }
    ResetClientCounters(client);
    g_sid[client][0] = '\0';
}

void ResetClientCounters(int client)
{
    g_suppressions[client]     = 0;
    g_timesSuppressed[client]  = 0;
    g_enemiesFlashed[client]   = 0;
    g_teammatesFlashed[client] = 0;
    g_damageTaken[client]      = 0;
    g_fallDamage[client]       = 0;
    g_lastScore[client]        = 0;
    g_lastCaptureTicks[client] = 0;
    g_lastResets[client]       = 0;
    g_hitTick[client]          = -1;
    g_lastHitgroup[client]     = -1;
    g_spanOpen[client]         = false;
    g_healOpen[client]         = false;
    g_holdStart[client]        = -1.0;
    delete g_healHolds[client];
    if (g_weapons[client] != null) g_weapons[client].Clear();
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client) || !HaveRound() || g_roundOver) return;
    float now = GetEngineTime();
    CloseSpan(client, now);
    int team = event.GetInt("team");
    if (team >= TEAM_SPECTATOR)
        OpenSpan(client, team, now);
}

public void Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client) || !HaveRound() || g_roundOver) return;
    char cls[64];
    event.GetString("class_template", cls, sizeof(cls));
    int squad = event.GetInt("squad"), slot = event.GetInt("squad_slot");
    if (g_spanOpen[client] && StrEqual(cls, g_spanClass[client]) && squad == g_spanSquad[client] && slot == g_spanSlot[client])
        return;
    float now = GetEngineTime();
    int   team = GetClientTeam(client);
    CloseSpan(client, now);
    OpenSpanWith(client, team, squad, slot, cls, now);
}

void OpenSpan(int client, int team, float at)
{
    if (team < TEAM_SPECTATOR) return;
    char cls[64];
    int  squad = -1, slot = -1;
    if (team != TEAM_SPECTATOR)
    {
        ClassTemplate_Get(client, cls, sizeof(cls));
        int res = GetPlayerResourceEntity();
        if (res != -1 && HasEntProp(res, Prop_Send, "m_iSquad"))
        {
            squad = GetEntProp(res, Prop_Send, "m_iSquad", _, client);
            slot  = GetEntProp(res, Prop_Send, "m_iSquadSlot", _, client);
        }
    }
    OpenSpanWith(client, team, squad, slot, cls, at);
}

void OpenSpanWith(int client, int team, int squad, int slot, const char[] cls, float at)
{
    g_spanOpen[client]  = true;
    g_spanStart[client] = at;
    g_spanTeam[client]  = team;
    g_spanSquad[client] = squad;
    g_spanSlot[client]  = slot;
    strcopy(g_spanClass[client], sizeof(g_spanClass[]), cls);
    if (team == TEAM_SECURITY || team == TEAM_INSURGENT) g_roundHumans = true;
}

void CloseSpan(int client, float at)
{
    if (!g_spanOpen[client]) return;
    g_spanOpen[client] = false;
    if (!IsHuman(client)) return;
    if (at < g_spanStart[client]) at = g_spanStart[client];    // clamp: never a negative span
    // Spectator time before anyone played is not worth a row on its own.
    if (g_spanTeam[client] == TEAM_SPECTATOR && !g_roundHumans) return;

    char start[64], end[64], team[24], cls[140], squad[16], slot[16], tuple[512];
    Ts(g_spanStart[client], start, sizeof(start));
    Ts(at, end, sizeof(end));
    TeamName(g_spanTeam[client], team, sizeof(team));
    QuoteOrNull(g_spanClass[client], cls, sizeof(cls));
    if (g_spanSquad[client] >= 0) IntToString(g_spanSquad[client], squad, sizeof(squad));
    else strcopy(squad, sizeof(squad), "NULL");
    if (g_spanSlot[client] >= 0) IntToString(g_spanSlot[client], slot, sizeof(slot));
    else strcopy(slot, sizeof(slot), "NULL");
    Format(tuple, sizeof(tuple), "%s,%s,%s,%s,%s,%s,%s", g_sid[client], start, end, team, squad, slot, cls);
    NotePlayer(g_sid[client]);
    AddRow(T_SPANS, tuple);
}

// ===================================================================================================
// Spawns and loadouts
// ===================================================================================================

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client) || !HaveRound() || g_roundOver) return;
    if (GetClientTeam(client) < TEAM_SECURITY) return;
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteFloat(GetEngineTime());
    // The game hands the loadout out just after the spawn event.
    CreateTimer(0.5, Timer_RecordSpawn, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public Action Timer_RecordSpawn(Handle timer, DataPack pack)
{
    pack.Reset();
    int   client  = GetClientOfUserId(pack.ReadCell());
    float spawned = pack.ReadFloat();
    if (!IsHuman(client) || !IsPlayerAlive(client) || !HaveRound()) return Plugin_Stop;

    char ts[64], stmt[4096], item[96];
    Ts(spawned, ts, sizeof(ts));
    // Continues the "WITH r AS (...)" the flush puts in front.
    Format(stmt, sizeof(stmt),
           ", s AS (INSERT INTO spawns (round_id, steam_id, spawned_at) SELECT id, %s, %s FROM r ON CONFLICT DO NOTHING RETURNING spawn_id) ",
           g_sid[client], ts);

    // Items: gear by theater name, weapons by classname. One row each; duplicates collapse.
    StringMap seen  = new StringMap();
    char values[3500];
    values[0] = '\0';
    if (TheaterItem_Ready() && HasEntProp(client, Prop_Send, "m_EquippedGear"))
    {
        int n = GetEntPropArraySize(client, Prop_Send, "m_EquippedGear");
        for (int i = 0; i < n; i++)
        {
            int id = GetEntProp(client, Prop_Send, "m_EquippedGear", 4, i);
            if (id <= 0 || !TheaterItem_Name(TheaterCategory_Gear, id, item, sizeof(item))) continue;
            AppendItem(seen, item, values, sizeof(values));
        }
    }
    int count = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < count; i++)
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon <= 0 || !IsValidEntity(weapon)) continue;
        GetEntityClassname(weapon, item, sizeof(item));
        AppendItem(seen, item, values, sizeof(values));
    }
    delete seen;

    NotePlayer(g_sid[client]);
    if (values[0] != '\0')
    {
        Format(stmt, sizeof(stmt), "%sINSERT INTO spawn_items (spawn_id, item_id) SELECT s.spawn_id, i.item_id FROM s, (VALUES %s) v(item) JOIN items i ON i.item_name = v.item ON CONFLICT DO NOTHING",
               stmt, values);
    }
    else
    {
        StrCat(stmt, sizeof(stmt), "SELECT 1 FROM s");
    }
    AddStmt(stmt);
    return Plugin_Stop;
}

void AppendItem(StringMap seen, const char[] item, char[] values, int maxlen)
{
    if (item[0] == '\0') return;
    bool dummy;
    if (seen.GetValue(item, dummy)) return;
    seen.SetValue(item, true);
    g_flushItems.SetValue(item, true);
    char q[200];
    Quote(item, q, sizeof(q));
    if (values[0] != '\0') StrCat(values, maxlen, ",");
    Format(values, maxlen, "%s(%s)", values, q);
}

// ===================================================================================================
// Kills and damage
// ===================================================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound()) return Plugin_Continue;
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int assister = GetClientOfUserId(event.GetInt("assister"));
    if (victim < 1 || !IsClientInGame(victim)) return Plugin_Continue;
    bool victimHuman   = IsHuman(victim);
    bool attackerHuman = IsHuman(attacker);
    if (!victimHuman && !attackerHuman) return Plugin_Continue;    // bot vs bot

    char ts[64];
    Ts(GetEngineTime(), ts, sizeof(ts));

    // Victim: team, and SteamID or bot name and class.
    char vsid[24] = "NULL", vbot[140] = "NULL", vteam[24] = "NULL", vcls[200] = "NULL";
    DescribeSide(victim, vsid, vbot, vteam, vcls);

    char asid[24] = "NULL", abot[140] = "NULL", ateam[24] = "NULL", acls[200] = "NULL";
    char ax[16] = "NULL", ay[16] = "NULL", az[16] = "NULL", stance[16] = "NULL", aim[16] = "NULL";
    if (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker))
    {
        DescribeSide(attacker, asid, abot, ateam, acls);
        float pos[3];
        GetClientAbsOrigin(attacker, pos);
        FloatToString(pos[0], ax, sizeof(ax));
        FloatToString(pos[1], ay, sizeof(ay));
        FloatToString(pos[2], az, sizeof(az));
        if (attackerHuman)
        {
            AttackerStance(attacker, stance, sizeof(stance));
            AttackerAim(attacker, aim, sizeof(aim));
        }
    }

    char ssid[24] = "NULL", sbot[140] = "NULL", dummyTeam[24], dummyCls[200];
    if (assister >= 1 && assister <= MaxClients && IsClientInGame(assister) && assister != attacker)
        DescribeSide(assister, ssid, sbot, dummyTeam, dummyCls);

    char weapon[64], qweapon[140] = "NULL";
    event.GetString("weapon", weapon, sizeof(weapon));
    if (weapon[0] != '\0' && attacker >= 1)
    {
        char stripped[64];
        StripWeaponPrefix(weapon, stripped, sizeof(stripped));
        NoteWeapon(stripped);
        Quote(stripped, qweapon, sizeof(qweapon));
    }

    char hitgroup[24] = "NULL";
    if (g_lastHitTick[victim] == GetGameTickCount() || g_lastHitTick[victim] == GetGameTickCount() - 1)
        HitgroupName(g_lastHitgroup[victim], hitgroup, sizeof(hitgroup));

    int flags = event.GetInt("deathflags");
    char tuple[1536];
    Format(tuple, sizeof(tuple),
           "%s,%s,%s,%s,%s,%.1f,%.1f,%.1f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%s,%s",
           ts, vsid, vbot, vteam, vcls,
           event.GetFloat("x"), event.GetFloat("y"), event.GetFloat("z"),
           asid, abot, ateam, acls, ax, ay, az, ssid, sbot, qweapon, hitgroup,
           (flags & 0x10) ? "true" : "false", (flags & 0x04) ? "true" : "false",
           (flags & 0x08) ? "true" : "false", (flags & 0x20) ? "true" : "false",
           (flags & 0x40) ? "true" : "false", (flags & 0x80) ? "true" : "false",
           event.GetInt("damagebits"), event.GetInt("customkill"), stance, aim);
    AddRow(T_KILLS, tuple);
    return Plugin_Continue;
}

// One side of a kill: a human's SteamID, or a bot's name, team and class.
// A bot's class is written as its bot_classes key, looked up by name in the insert.
void DescribeSide(int client, char sid[24], char bot[140], char team[24], char cls[200])
{
    if (IsHuman(client))
    {
        strcopy(sid, 24, g_sid[client]);
        NotePlayer(g_sid[client]);
        TeamName(GetClientTeam(client), team, 24);
        return;
    }
    if (!IsFakeClient(client)) return;    // an unauthenticated human: leave the side anonymous
    char name[MAX_NAME_LENGTH], c[64];
    GetClientName(client, name, sizeof(name));
    Quote(name, bot, 140);
    TeamName(GetClientTeam(client), team, 24);
    if (ClassTemplate_Get(client, c, sizeof(c)) && c[0] != '\0')
    {
        char q[140];
        Quote(c, q, sizeof(q));
        Format(cls, 200, "(SELECT bot_class_id FROM bot_classes WHERE class_template = %s)", q);
        g_flushBotClasses.SetValue(c, true);
    }
}

// m_iCurrentStance: 0 standing, 1 crouched, 2 prone (CINSPlayerShared).
void AttackerStance(int client, char[] out, int maxlen)
{
    if (!HasEntProp(client, Prop_Send, "m_iCurrentStance")) return;
    switch (GetEntProp(client, Prop_Send, "m_iCurrentStance"))
    {
        case 0: strcopy(out, maxlen, "'standing'");
        case 1: strcopy(out, maxlen, "'crouched'");
        case 2: strcopy(out, maxlen, "'prone'");
    }
}

// m_iPlayerFlags (CINSPlayerShared): 0x1 iron sights, 0x2 bipod, 0x20 focus (read off SetIronsightsState,
// SetBipodState and SetFocusMode in server_srv.so).
void AttackerAim(int client, char[] out, int maxlen)
{
    if (!HasEntProp(client, Prop_Send, "m_iPlayerFlags")) return;
    int flags = GetEntProp(client, Prop_Send, "m_iPlayerFlags");
    if (flags & 0x2) strcopy(out, maxlen, "'bipod'");
    else if (flags & 0x20) strcopy(out, maxlen, "'focus'");
    else if (flags & 0x1) strcopy(out, maxlen, "'sights'");
    else strcopy(out, maxlen, "'hip'");
}

void HitgroupName(int hitgroup, char[] out, int maxlen)
{
    switch (hitgroup)
    {
        case 0: strcopy(out, maxlen, "'generic'");
        case 1: strcopy(out, maxlen, "'head'");
        case 2: strcopy(out, maxlen, "'chest'");
        case 3: strcopy(out, maxlen, "'stomach'");
        case 4: strcopy(out, maxlen, "'left_arm'");
        case 5: strcopy(out, maxlen, "'right_arm'");
        case 6: strcopy(out, maxlen, "'left_leg'");
        case 7: strcopy(out, maxlen, "'right_leg'");
        case 10: strcopy(out, maxlen, "'gear'");
    }
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (victim < 1) return;
    int hitgroup = event.GetInt("hitgroup");
    g_lastHitgroup[victim] = hitgroup;
    g_lastHitTick[victim]  = GetGameTickCount();

    if (!HaveRound() || !IsLive()) return;
    int dmg = event.GetInt("dmg_health");
    if (IsHuman(victim)) g_damageTaken[victim] += dmg;

    if (!IsHuman(attacker) || attacker == victim) return;
    bool friendly = GetClientTeam(victim) == GetClientTeam(attacker);

    char weapon[64], name64[64];
    event.GetString("weapon", weapon, sizeof(weapon));
    StripWeaponPrefix(weapon, name64, sizeof(name64));
    if (name64[0] == '\0') return;
    int counts[W_COUNT];
    GetWeaponCounts(attacker, name64, counts);
    if (friendly)
    {
        counts[W_DMG_FRIENDLY] += dmg;
    }
    else
    {
        counts[W_DMG_ENEMY] += dmg;
        switch (hitgroup)
        {
            case 1: counts[W_HEAD]++;
            case 2: counts[W_CHEST]++;
            case 3: counts[W_STOMACH]++;
            case 4, 5: counts[W_ARMS]++;
            case 6, 7: counts[W_LEGS]++;
        }
    }
    g_weapons[attacker].SetArray(name64, counts, W_COUNT);

    // Shot attribution, bullets only: this round's weapon_fire comes next in the same tick.
    if (event.GetInt("damagebits") & DMG_BULLET)
    {
        int tick = GetGameTickCount();
        if (g_hitTick[attacker] != tick)
        {
            g_hitTick[attacker]     = tick;
            g_hitEnemy[attacker]    = false;
            g_hitFriendly[attacker] = false;
        }
        if (friendly) g_hitFriendly[attacker] = true;
        else g_hitEnemy[attacker] = true;
    }
}

void GetWeaponCounts(int client, const char[] weapon, int counts[W_COUNT])
{
    if (g_weapons[client] == null) g_weapons[client] = new StringMap();
    if (!g_weapons[client].GetArray(weapon, counts, W_COUNT))
    {
        for (int i = 0; i < W_COUNT; i++) counts[i] = 0;
    }
}

void AddWeaponCount(int client, const char[] weapon, int index, int amount)
{
    if (weapon[0] == '\0') return;
    int counts[W_COUNT];
    GetWeaponCounts(client, weapon, counts);
    counts[index] += amount;
    g_weapons[client].SetArray(weapon, counts, W_COUNT);
}

bool ActiveWeaponName(int client, char[] name, int maxlen)
{
    char classname[64];
    if (!GetClientWeapon(client, classname, sizeof(classname)) || classname[0] == '\0') return false;
    StripWeaponPrefix(classname, name, maxlen);
    return true;
}

public Action Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound() || !IsLive()) return Plugin_Continue;
    if (event.GetInt("shots", -1) == -1) return Plugin_Continue;    // not a firearm round
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client)) return Plugin_Continue;
    char weapon[64];
    if (!ActiveWeaponName(client, weapon, sizeof(weapon))) return Plugin_Continue;

    int counts[W_COUNT];
    GetWeaponCounts(client, weapon, counts);
    counts[W_SHOTS]++;
    if (g_hitTick[client] == GetGameTickCount())
    {
        if (g_hitEnemy[client]) counts[W_HIT_ENEMY]++;
        if (g_hitFriendly[client]) counts[W_HIT_FRIENDLY]++;
    }
    g_hitTick[client] = -1;
    g_weapons[client].SetArray(weapon, counts, W_COUNT);
    return Plugin_Continue;
}

public void Event_GrenadeThrown(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound() || !IsLive()) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client)) return;
    char weapon[64];
    if (ActiveWeaponName(client, weapon, sizeof(weapon)))
        AddWeaponCount(client, weapon, W_SHOTS, 1);
}

public void Event_WeaponReload(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound() || !IsLive()) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client)) return;
    char weapon[64];
    if (ActiveWeaponName(client, weapon, sizeof(weapon)))
        AddWeaponCount(client, weapon, W_RELOADS, 1);
}

// weapon_deploy and time_weapon carry the weapon's theater id.
bool TheaterWeaponName(int id, char[] out, int maxlen)
{
    char theaterName[96];
    if (!TheaterItem_Ready() || !TheaterItem_Name(TheaterCategory_Weapon, id, theaterName, sizeof(theaterName)))
        return false;
    StripWeaponPrefix(theaterName, out, maxlen);
    return true;
}

public void Event_WeaponDeploy(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound() || !IsLive()) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client)) return;
    char weapon[64];
    if (TheaterWeaponName(event.GetInt("weaponid"), weapon, sizeof(weapon)) || ActiveWeaponName(client, weapon, sizeof(weapon)))
        AddWeaponCount(client, weapon, W_DEPLOYS, 1);
}

public void Event_TimeWeapon(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound()) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHuman(client)) return;
    char weapon[64];
    float seconds = event.GetFloat("seconds");
    if (seconds > 0.0 && TheaterWeaponName(event.GetInt("weapon"), weapon, sizeof(weapon)))
        AddWeaponCount(client, weapon, W_MS_DRAWN, RoundToNearest(seconds * 1000.0));
}

public void Event_PlayerSuppressed(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound() || !IsLive()) return;
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim   = GetClientOfUserId(event.GetInt("victim"));
    if (attacker == victim) return;
    if (IsHuman(attacker) && (victim < 1 || GetClientTeam(victim) != GetClientTeam(attacker)))
        g_suppressions[attacker]++;
    if (IsHuman(victim))
        g_timesSuppressed[victim]++;
}

public void Event_PlayerFallDamage(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound()) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsHuman(client))
        g_fallDamage[client] += RoundToNearest(event.GetFloat("damage"));
}

// Flashes, matched exactly as gg2_teamflash does: every player_blind a flashbang causes fires in the
// same tick as, and before, its grenade_detonate.
public void Event_PlayerBlind(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client >= 1) g_blindTick[client] = GetGameTickCount();
}

public void Event_GrenadeDetonate(Event event, const char[] name, bool dontBroadcast)
{
    int tick     = GetGameTickCount();
    int thrower  = GetClientOfUserId(event.GetInt("userid"));
    bool counted = HaveRound() && IsHuman(thrower);
    int team     = counted ? GetClientTeam(thrower) : 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_blindTick[i] != tick) continue;
        g_blindTick[i] = 0;
        if (!counted || i == thrower || !IsClientInGame(i)) continue;
        if (GetClientTeam(i) == team) g_teammatesFlashed[thrower]++;
        else g_enemiesFlashed[thrower]++;
    }
}

// ===================================================================================================
// Objectives
// ===================================================================================================

public void Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    RecordPointEvent(event, "captured");
}

public void Event_ControlPointNeutralized(Event event, const char[] name, bool dontBroadcast)
{
    RecordPointEvent(event, "neutralized");
}

void RecordPointEvent(Event event, const char[] kind)
{
    if (!HaveRound()) return;
    char cappers[MAXPLAYERS + 1], participants[2048];
    event.GetString("cappers", cappers, sizeof(cappers));
    participants[0] = '\0';
    // cappers is a string of client index bytes; bots in it are skipped, not a reason to stop.
    for (int i = 0; cappers[i] != '\0'; i++)
    {
        int client = cappers[i];
        if (!IsHuman(client)) continue;
        AppendParticipant(participants, sizeof(participants), client, "capper");
    }
    char cpname[64], qname[140], team[24];
    event.GetString("cpname", cpname, sizeof(cpname));
    QuoteOrNull(cpname, qname, sizeof(qname));
    TeamName(event.GetInt("team"), team, sizeof(team));
    RecordObjective(kind, event.GetInt("cp"), qname, team, "NULL", participants);
}

public void Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
    if (!HaveRound()) return;
    // attacker and assister here are client indices, not userids.
    char participants[512];
    participants[0] = '\0';
    int attacker = event.GetInt("attacker"), assister = event.GetInt("assister");
    if (IsHuman(attacker)) AppendParticipant(participants, sizeof(participants), attacker, "attacker");
    if (IsHuman(assister) && assister != attacker) AppendParticipant(participants, sizeof(participants), assister, "assister");

    char weapon[64], stripped[64], qweapon[140] = "NULL", team[24];
    event.GetString("weapon", weapon, sizeof(weapon));
    if (weapon[0] != '\0')
    {
        StripWeaponPrefix(weapon, stripped, sizeof(stripped));
        NoteWeapon(stripped);
        Quote(stripped, qweapon, sizeof(qweapon));
    }
    TeamName(event.GetInt("attackerteam"), team, sizeof(team));
    if (StrEqual(team, "NULL")) strcopy(team, sizeof(team), "'security'");
    RecordObjective("cache_destroyed", event.GetInt("cp"), "NULL", team, qweapon, participants);
}

void AppendParticipant(char[] list, int maxlen, int client, const char[] role)
{
    NotePlayer(g_sid[client]);
    if (list[0] != '\0') StrCat(list, maxlen, ",");
    Format(list, maxlen, "%s(%s,'%s')", list, g_sid[client], role);
}

void RecordObjective(const char[] kind, int cp, const char[] qname, const char[] team, const char[] qweapon, const char[] participants)
{
    char ts[64], stmt[3500], cpv[16];
    Ts(GetEngineTime(), ts, sizeof(ts));
    if (cp >= 0) IntToString(cp, cpv, sizeof(cpv));
    else strcopy(cpv, sizeof(cpv), "NULL");
    Format(stmt, sizeof(stmt),
           ", e AS (INSERT INTO objective_events (round_id, at, kind, control_point, cp_name, team, weapon_name) SELECT id, %s, '%s', %s, %s, %s, %s FROM r RETURNING objective_event_id) ",
           ts, kind, cpv, qname, team, qweapon);
    if (participants[0] != '\0')
        Format(stmt, sizeof(stmt), "%sINSERT INTO objective_participants (objective_event_id, steam_id, role) SELECT e.objective_event_id, v.sid, v.role::objective_role FROM e, (VALUES %s) v(sid, role) ON CONFLICT DO NOTHING",
               stmt, participants);
    else
        StrCat(stmt, sizeof(stmt), "SELECT 1 FROM e");
    AddStmt(stmt);
}

// ===================================================================================================
// Revives, heals, fire support, team kill forgives (forwards from other plugins)
// ===================================================================================================

public void Stats_OnRevive(int reviver, int revived, float startedAt, int method, const int[] helpers, int helperCount)
{
    if (!HaveRound() || !IsHuman(reviver) || !IsHuman(revived)) return;
    char start[64], done[64], stmt[2048], m[16], list[1024];
    Ts(startedAt, start, sizeof(start));
    Ts(GetEngineTime(), done, sizeof(done));
    switch (method)
    {
        case STATS_REVIVE_DEFIB: strcopy(m, sizeof(m), "defib");
        case STATS_REVIVE_KNIFE: strcopy(m, sizeof(m), "knife");
        default: strcopy(m, sizeof(m), "healthkit");
    }
    NotePlayer(g_sid[reviver]);
    NotePlayer(g_sid[revived]);
    Format(stmt, sizeof(stmt),
           ", v AS (INSERT INTO revives (round_id, started_at, revived_at, reviver_steam_id, revived_steam_id, method) SELECT id, %s, %s, %s, %s, '%s' FROM r RETURNING revive_id) ",
           start, done, g_sid[reviver], g_sid[revived], m);
    list[0] = '\0';
    for (int i = 0; i < helperCount; i++)
    {
        if (!IsHuman(helpers[i]) || helpers[i] == reviver) continue;
        NotePlayer(g_sid[helpers[i]]);
        if (list[0] != '\0') StrCat(list, sizeof(list), ",");
        Format(list, sizeof(list), "%s(%s)", list, g_sid[helpers[i]]);
    }
    if (list[0] != '\0')
        Format(stmt, sizeof(stmt), "%sINSERT INTO revive_helpers (revive_id, steam_id) SELECT v.revive_id, h.sid FROM v, (VALUES %s) h(sid) ON CONFLICT DO NOTHING",
               stmt, list);
    else
        StrCat(stmt, sizeof(stmt), "SELECT 1 FROM v");
    AddStmt(stmt);
}

public void Stats_OnHealTick(int healer, int patient, int hpGained, bool reachedMax)
{
    if (!HaveRound() || !IsHuman(healer) || !IsHuman(patient)) return;
    float now = GetEngineTime();
    if (g_healOpen[healer] && (g_healPatient[healer] != patient || g_healFull[healer] || now - g_healLast[healer] > HEAL_GAP))
        CloseHeal(healer);
    if (!g_healOpen[healer])
        OpenHeal(healer, patient, now);
    g_healLast[healer] = now;
    g_healHp[healer] += hpGained;
    if (reachedMax) g_healFull[healer] = true;
}

void OpenHeal(int healer, int patient, float now)
{
    g_healOpen[healer]    = true;
    g_healPatient[healer] = patient;
    g_healStart[healer]   = now;
    g_healLast[healer]    = now;
    g_healHp[healer]      = 0;
    g_healFull[healer]    = false;
    delete g_healHolds[healer];
}

public void Stats_OnHealHold(int medic, int patient, bool started, int reason)
{
    if (!HaveRound() || !IsHuman(medic) || !IsHuman(patient)) return;
    float now = GetEngineTime();
    if (started)
    {
        // The hold engages on the heal's first tick, before the tick forward: open the heal for it.
        if (!g_healOpen[medic] || g_healPatient[medic] != patient)
        {
            CloseHeal(medic);
            OpenHeal(medic, patient, now);
        }
        g_holdStart[medic] = now;
        return;
    }
    if (g_holdStart[medic] < 0.0 || !g_healOpen[medic] || g_healPatient[medic] != patient) return;
    if (g_healHolds[medic] == null) g_healHolds[medic] = new ArrayList(3);
    any row[3];
    row[0] = g_holdStart[medic];
    row[1] = now;
    row[2] = reason;
    g_healHolds[medic].PushArray(row);
    g_holdStart[medic] = -1.0;
}

void CloseHealsOf(int client)
{
    CloseHeal(client);
    for (int healer = 1; healer <= MaxClients; healer++)
        if (g_healOpen[healer] && g_healPatient[healer] == client)
            CloseHeal(healer);
}

void CloseHeal(int healer)
{
    if (!g_healOpen[healer]) return;
    g_healOpen[healer] = false;
    int patient = g_healPatient[healer];
    // A hold still on when the heal ends (round end, disconnect) ends with it.
    if (g_holdStart[healer] >= 0.0)
    {
        if (g_healHolds[healer] == null) g_healHolds[healer] = new ArrayList(3);
        any row[3];
        row[0] = g_holdStart[healer];
        row[1] = g_healLast[healer] > g_holdStart[healer] ? g_healLast[healer] : g_holdStart[healer];
        row[2] = g_roundOver ? STATS_HOLD_ROUND_END : STATS_HOLD_LOST_TARGET;
        g_healHolds[healer].PushArray(row);
        g_holdStart[healer] = -1.0;
    }
    if (!HaveRound() || !IsHuman(healer) || g_sid[patient][0] == '\0' || (g_healHp[healer] <= 0 && g_healHolds[healer] == null))
    {
        delete g_healHolds[healer];
        return;
    }

    char start[64], end[64], stmt[3000];
    Ts(g_healStart[healer], start, sizeof(start));
    Ts(g_healLast[healer], end, sizeof(end));
    NotePlayer(g_sid[healer]);
    NotePlayer(g_sid[patient]);
    Format(stmt, sizeof(stmt),
           ", h AS (INSERT INTO heals (round_id, started_at, ended_at, healer_steam_id, patient_steam_id, hp_healed, to_full) SELECT id, %s, %s, %s, %s, %d, %s FROM r RETURNING heal_id) ",
           start, end, g_sid[healer], g_sid[patient], g_healHp[healer] > 32767 ? 32767 : g_healHp[healer],
           g_healFull[healer] ? "true" : "false");
    if (g_healHolds[healer] != null && g_healHolds[healer].Length > 0)
    {
        static const char reasons[][] = { "full_health", "keys_released", "lost_target", "death", "disconnect", "round_end", "map_end" };
        char list[2000], hs[64], he[64];
        list[0] = '\0';
        for (int i = 0; i < g_healHolds[healer].Length; i++)
        {
            any row[3];
            g_healHolds[healer].GetArray(i, row);
            float hstart = view_as<float>(row[0]), hend = view_as<float>(row[1]);
            int   reason = row[2];
            if (reason < 0 || reason >= sizeof(reasons)) reason = STATS_HOLD_LOST_TARGET;
            if (hend < hstart) hend = hstart;
            Ts(hstart, hs, sizeof(hs));
            Ts(hend, he, sizeof(he));
            if (list[0] != '\0') StrCat(list, sizeof(list), ",");
            Format(list, sizeof(list), "%s(%s,%s,'%s')", list, hs, he, reasons[reason]);
        }
        Format(stmt, sizeof(stmt), "%sINSERT INTO heal_holds (heal_id, started_at, ended_at, released_by) SELECT h.heal_id, v.s, v.e, v.why::heal_hold_release FROM h, (VALUES %s) v(s, e, why) ON CONFLICT DO NOTHING",
               stmt, list);
    }
    else
    {
        StrCat(stmt, sizeof(stmt), "SELECT 1 FROM h");
    }
    delete g_healHolds[healer];
    AddStmt(stmt);
}

// Calls not yet flushed, so a refund can be folded into its call: {client, engine time, row index}
public void FireSupport_OnCallResult(int client, const char[] supportType, const float target[3], bool hasTarget, const char[] failure)
{
    if (!HaveRound() || !IsHuman(client)) return;
    char ts[64], qtype[140], qfail[140], x[16] = "NULL", y[16] = "NULL", z[16] = "NULL", tuple[512];
    Ts(GetEngineTime(), ts, sizeof(ts));
    char stripped[64];
    StripWeaponPrefix(supportType, stripped, sizeof(stripped));
    Quote(stripped, qtype, sizeof(qtype));
    QuoteOrNull(failure, qfail, sizeof(qfail));
    if (hasTarget)
    {
        FloatToString(target[0], x, sizeof(x));
        FloatToString(target[1], y, sizeof(y));
        FloatToString(target[2], z, sizeof(z));
    }
    NotePlayer(g_sid[client]);
    Format(tuple, sizeof(tuple), "%s,%s,%s,%s,%s,%s,%s,NULL", ts, g_sid[client], qtype, x, y, z, qfail);
    AddRow(T_FIRE, tuple);
}

public void FireSupport_OnRefund(int client)
{
    if (!HaveRound() || !IsHuman(client)) return;
    // Refunds follow their call within a moment; mark the caller's latest call. Run after the call
    // rows go in (round-scoped statements come after the tuple inserts).
    char ts[64], stmt[512];
    Ts(GetEngineTime(), ts, sizeof(ts));
    Format(stmt, sizeof(stmt),
           "UPDATE v2_fire_support_calls SET refunded_at = %s WHERE call_id = (SELECT max(call_id) FROM v2_fire_support_calls WHERE steam_id = %s AND refunded_at IS NULL)",
           ts, g_sid[client]);
    AddStmt(stmt);
}

public void TeamKill_OnForgiven(int victim, int attacker)
{
    if (!HaveRound() || !IsHuman(victim) || !IsHuman(attacker)) return;
    char ts[64], stmt[512];
    Ts(GetEngineTime(), ts, sizeof(ts));
    // The latest kill of this victim by this attacker; it may still be in this flush, so this runs
    // after the kill rows.
    Format(stmt, sizeof(stmt),
           "INSERT INTO team_kill_forgives (kill_id, forgiven_at) SELECT kill_id, %s FROM kills WHERE attacker_steam_id = %s AND victim_steam_id = %s ORDER BY killed_at DESC LIMIT 1 ON CONFLICT DO NOTHING",
           ts, g_sid[attacker], g_sid[victim]);
    AddStmt(stmt);
}

// ===================================================================================================
// Per-round counters
// ===================================================================================================

void EmitAllCounters()
{
    if (!HaveRound()) return;
    for (int client = 1; client <= MaxClients; client++)
        if (IsHuman(client))
            EmitCounters(client);
}

// Writes what this player added since the last flush, as additive upserts.
void EmitCounters(int client)
{
    if (!HaveRound() || !IsHuman(client)) return;

    // The game's round stats are cumulative within the round: write the change.
    int score  = GameStat(client, 20), ticks = GameStat(client, 12), resets = GameStat(client, 11);
    int dScore = score - g_lastScore[client], dTicks = ticks - g_lastCaptureTicks[client], dResets = resets - g_lastResets[client];
    g_lastScore[client]        = score;
    g_lastCaptureTicks[client] = ticks;
    g_lastResets[client]       = resets;
    if (dTicks < 0) dTicks = 0;
    if (dResets < 0) dResets = 0;

    bool hasWeapons = g_weapons[client] != null && g_weapons[client].Size > 0;
    if (dScore == 0 && dTicks == 0 && dResets == 0 && g_suppressions[client] == 0 && g_timesSuppressed[client] == 0
        && g_enemiesFlashed[client] == 0 && g_teammatesFlashed[client] == 0 && g_damageTaken[client] == 0
        && g_fallDamage[client] == 0 && !hasWeapons)
        return;

    NotePlayer(g_sid[client]);
    char stmt[2048];
    Format(stmt, sizeof(stmt),
           "INSERT INTO v2_player_rounds AS p (round_id, steam_id, score, capture_ticks, objective_resets, suppressions, times_suppressed, enemies_flashed, teammates_flashed, damage_taken, fall_damage) "
         ... "SELECT id, %s, %d, %d, %d, %d, %d, %d, %d, %d, %d FROM r ON CONFLICT (round_id, steam_id) DO UPDATE SET "
         ... "score = p.score + EXCLUDED.score, capture_ticks = p.capture_ticks + EXCLUDED.capture_ticks, "
         ... "objective_resets = p.objective_resets + EXCLUDED.objective_resets, suppressions = p.suppressions + EXCLUDED.suppressions, "
         ... "times_suppressed = p.times_suppressed + EXCLUDED.times_suppressed, enemies_flashed = p.enemies_flashed + EXCLUDED.enemies_flashed, "
         ... "teammates_flashed = p.teammates_flashed + EXCLUDED.teammates_flashed, damage_taken = p.damage_taken + EXCLUDED.damage_taken, "
         ... "fall_damage = p.fall_damage + EXCLUDED.fall_damage",
           g_sid[client], dScore, dTicks, dResets, g_suppressions[client], g_timesSuppressed[client],
           g_enemiesFlashed[client], g_teammatesFlashed[client], g_damageTaken[client], g_fallDamage[client]);
    AddStmt(stmt);

    g_suppressions[client]     = 0;
    g_timesSuppressed[client]  = 0;
    g_enemiesFlashed[client]   = 0;
    g_teammatesFlashed[client] = 0;
    g_damageTaken[client]      = 0;
    g_fallDamage[client]       = 0;

    if (!hasWeapons) return;
    // Statements are buffered in 4 KB slots (g_stmts), so the weapons go out in as many as needed.
    char values[2400], row[200], weapon[64], qweapon[140];
    values[0] = '\0';
    StringMapSnapshot snap = g_weapons[client].Snapshot();
    for (int i = 0; i < snap.Length; i++)
    {
        snap.GetKey(i, weapon, sizeof(weapon));
        int c[W_COUNT];
        g_weapons[client].GetArray(weapon, c, W_COUNT);
        NoteWeapon(weapon);
        Quote(weapon, qweapon, sizeof(qweapon));
        Format(row, sizeof(row), "(%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d)", qweapon,
               c[W_SHOTS], c[W_HIT_ENEMY], c[W_HIT_FRIENDLY], c[W_HEAD], c[W_CHEST], c[W_STOMACH], c[W_ARMS],
               c[W_LEGS], c[W_DMG_ENEMY], c[W_DMG_FRIENDLY], c[W_RELOADS], c[W_DEPLOYS], RoundToNearest(c[W_MS_DRAWN] / 1000.0));
        if (values[0] != '\0' && strlen(values) + strlen(row) + 2 >= sizeof(values))
        {
            EmitWeaponRows(client, values);
            values[0] = '\0';
        }
        if (values[0] != '\0') StrCat(values, sizeof(values), ",");
        StrCat(values, sizeof(values), row);
    }
    delete snap;
    g_weapons[client].Clear();
    if (values[0] != '\0') EmitWeaponRows(client, values);
}

void EmitWeaponRows(int client, const char[] values)
{
    char stmt[4096];
    Format(stmt, sizeof(stmt),
           "INSERT INTO v2_player_round_weapons AS w (round_id, steam_id, weapon_name, shots, shots_hit_enemy, shots_hit_friendly, hits_head, hits_chest, hits_stomach, hits_arms, hits_legs, damage_enemy, damage_friendly, reloads, deploys, seconds_drawn) "
         ... "SELECT r.id, %s, v.* FROM r, (VALUES %s) v ON CONFLICT (round_id, steam_id, weapon_name) DO UPDATE SET "
         ... "shots = w.shots + EXCLUDED.shots, shots_hit_enemy = w.shots_hit_enemy + EXCLUDED.shots_hit_enemy, "
         ... "shots_hit_friendly = w.shots_hit_friendly + EXCLUDED.shots_hit_friendly, hits_head = w.hits_head + EXCLUDED.hits_head, "
         ... "hits_chest = w.hits_chest + EXCLUDED.hits_chest, hits_stomach = w.hits_stomach + EXCLUDED.hits_stomach, "
         ... "hits_arms = w.hits_arms + EXCLUDED.hits_arms, hits_legs = w.hits_legs + EXCLUDED.hits_legs, "
         ... "damage_enemy = w.damage_enemy + EXCLUDED.damage_enemy, damage_friendly = w.damage_friendly + EXCLUDED.damage_friendly, "
         ... "reloads = w.reloads + EXCLUDED.reloads, deploys = w.deploys + EXCLUDED.deploys, seconds_drawn = w.seconds_drawn + EXCLUDED.seconds_drawn",
           g_sid[client], values);
    AddStmt(stmt);
}
