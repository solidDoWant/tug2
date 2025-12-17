#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <discord>
#include <morecolors>
#include <dbi>

#define TEAM_INS 3

public Plugin myinfo =
{
    name        = "[INS GG] TeamKilling",
    author      = "zachm",
    description = "TeamKill System",
    version     = "0.0.2",
    url         = ""
};

// TODO maybe this should track class/role as well - see original mstats2 plugin for reference

Database g_Database = null;
// Ban duration in minutes when auto-ban is triggered (how long to ban the player)
ConVar   g_cvarBanTime;
// Amnesty criteria CVars
ConVar   g_cvarAmnestyMinKPTK;         // Minimum kills-per-TK ratio for amnesty
ConVar   g_cvarAmnestyMinKillCount;    // Minimum total kills required for amnesty
ConVar   g_cvarAmnestyTimeCutoff;      // Time cutoff in seconds (players must have been seen within this period)
// Stores the timestamps (Unix epoch seconds) of the last 3 teamkills for each player.
// Array contents: [player index][0-2] = timestamp of each TK, with older entries shifting left when full
int      g_PlayerTKTimestamps[MAXPLAYERS + 1][3];
// Stores the client index of the attacker who most recently teamkilled each player.
// Array contents: [victim index] = attacker client index (used for the forgive command)
int      g_PlayerLastAttacker[MAXPLAYERS + 1];
int      EMPTY_TK_TIMESTAMPS[3] = { 0, 0, 0 };
// Time window in seconds for counting teamkills (e.g., 3 TKs within this period triggers auto-ban)
// This is different from g_cvarBanTime which controls how long the ban lasts
int      g_TKTimeWindowSeconds  = 600;    // 600 seconds = 10 minutes
char     INVALID_STEAM_ID[64]   = "STEAM_ID_STOP_IGNORING_RETVALS";

// Track connected players' Steam IDs (indexed by client ID)
char     g_ConnectedSteamIDs[MAXPLAYERS + 1][64];
// Amnesty status for connected players (indexed by client ID) - non-empty if player has amnesty
char     g_AmnestyPlayerSteamIDs[MAXPLAYERS + 1][64];
// Offender status for connected players (indexed by client ID) - non-empty if player is offender
char     g_OffenderSteamIDs[MAXPLAYERS + 1][64];
// Track whether we've already notified about an offender joining (to avoid duplicate messages)
bool     g_OffenderNotified[MAXPLAYERS + 1];

public void OnPluginStart()
{
    g_cvarBanTime             = CreateConVar("tk_ban_basetime", "60", "Base ban time (min)", FCVAR_PROTECTED);
    g_cvarAmnestyMinKPTK      = CreateConVar("tk_amnesty_min_kptk", "250", "Minimum kills-per-TK ratio for amnesty", FCVAR_PROTECTED);
    g_cvarAmnestyMinKillCount = CreateConVar("tk_amnesty_min_kills", "1000", "Minimum total kills required for amnesty", FCVAR_PROTECTED);
    g_cvarAmnestyTimeCutoff   = CreateConVar("tk_amnesty_time_cutoff", "7776000", "Amnesty time cutoff in seconds (default: 90 days)", FCVAR_PROTECTED);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("player_death", Event_PlayerDeath);
    RegConsoleCmd("forgive", Cmd_Forgive, "Forgive your attacker TK");
    RegConsoleCmd("пробачити", Cmd_Forgive, "Forgive in ukr");
    RegConsoleCmd("許す", Cmd_Forgive, "Forgive in ukr");
    RegConsoleCmd("原谅", Cmd_Forgive, "Forgive in chinese");
    RegConsoleCmd("простить", Cmd_Forgive, "Forgive in russ");
    RegConsoleCmd("perdonar", Cmd_Forgive, "Forgive in spanish");
    RegConsoleCmd("perdoar", Cmd_Forgive, "Forgive in portug");
    RegConsoleCmd("affetmek", Cmd_Forgive, "Forgive in turk");

    Database.Connect(OnDatabaseConnected, "insurgency-stats");

    LoadTranslations("tug.phrases");
    AutoExecConfig(true, "gg2_teamkill");
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[GG2 TEAMKILL] Failed to connect to database: %s", error);
        SetFailState("Database connection failed");
        return;
    }

    g_Database = db;
    LogMessage("[GG2 TEAMKILL] Successfully connected to database");

    // Refresh amnesty and offender lists on connect
    QueryAmnestyPlayers();
    QueryOffenderPlayers();
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    LogMessage("[GG2 TEAMKILL] Attempting to reconnect to database...");
    g_Database = null;
    Database.Connect(OnDatabaseReconnected, "insurgency-stats");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[GG2 TEAMKILL] Failed to reconnect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("[GG2 TEAMKILL] Successfully reconnected to database");

    // Refresh lists after reconnection
    QueryAmnestyPlayers();
    QueryOffenderPlayers();
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database == null)
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
        LogError("[GG2 TEAMKILL] Lost connection to database: %s - attempting to reconnect", error);
        ReconnectDatabase();
        return false;
    }

    LogError("[GG2 TEAMKILL] Failed to %s: %s", operationName, error);
    return false;
}

// Build a comma-separated list of connected player Steam IDs for SQL IN clause
// Returns the number of connected players added to the buffer
int BuildConnectedSteamIDList(char[] buffer, int maxlen)
{
    int count  = 0;
    int offset = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_ConnectedSteamIDs[i][0] == '\0') continue;

        if (count > 0)
        {
            offset += FormatEx(buffer[offset], maxlen - offset, ",");
        }

        offset += FormatEx(buffer[offset], maxlen - offset, "%s", g_ConnectedSteamIDs[i]);
        count++;
    }

    return count;
}

public void OnClientAuthorized(int client)
{
    if (IsFakeClient(client)) return;

    char steam_id[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steam_id, sizeof(steam_id))) return;

    if (StrEqual(steam_id, "\0") || StrEqual(steam_id, INVALID_STEAM_ID)) return;

    // Track this player's Steam ID if it is valid
    strcopy(g_ConnectedSteamIDs[client], sizeof(g_ConnectedSteamIDs[]), steam_id);

    // Reset notification flag for this client slot
    g_OffenderNotified[client]         = false;

    // Clear any stale amnesty/offender data for this slot
    g_AmnestyPlayerSteamIDs[client][0] = '\0';
    g_OffenderSteamIDs[client][0]      = '\0';

    if (g_Database == null) return;

    // Query for amnesty and offender status for all connected players (including this new one)
    QueryAmnestyPlayers();
    QueryOffenderPlayers();
}

public Action Timer_RefreshAmnestyList(Handle timer)
{
    if (g_Database != null)
    {
        QueryAmnestyPlayers();
    }

    return Plugin_Continue;
}

public Action Timer_RefreshOffenderList(Handle timer)
{
    if (g_Database != null)
    {
        QueryOffenderPlayers();
    }

    return Plugin_Continue;
}

public void UpdateTKForgivenInDB(int attacker, int victim)
{
    if (g_Database == null) return;

    // Use cached Steam IDs - if not available, the player disconnected
    if (g_ConnectedSteamIDs[attacker][0] == '\0' || g_ConnectedSteamIDs[victim][0] == '\0') return;

    char query[1024];
    g_Database.Format(query, sizeof(query),
                      "UPDATE player_tk_logs SET forgiven = TRUE \
                      WHERE id = ( \
                          SELECT id \
                          FROM player_tk_logs \
                          WHERE victim_steam_id = %s AND attacker_steam_id = %s \
                          ORDER BY id DESC LIMIT 1 \
                      )",
                      g_ConnectedSteamIDs[victim], g_ConnectedSteamIDs[attacker]);

    g_Database.Query(OnTKForgivenUpdated, query);
}

public void OnTKForgivenUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "update TK forgiven status");
}

public void UpdatePlayerLastSeen(int client)
{
    if (g_Database == null) return;

    // Use cached Steam ID - if not available, player already disconnected or never connected properly
    if (g_ConnectedSteamIDs[client][0] == '\0') return;

    char query[256];
    g_Database.Format(query, sizeof(query),
                      "UPDATE player_tks SET last_seen = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE steam_id = %s",
                      g_ConnectedSteamIDs[client]);

    g_Database.Query(OnLastSeenUpdated, query);
}

public void OnLastSeenUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "update last_seen");
}

public bool PlayerHasAmnesty(int attacker_client)
{
    if (GetUserAdmin(attacker_client) != INVALID_ADMIN_ID)
    {
        LogMessage("[GG2 TEAMKILL] AMNESTY granted to admin %N", attacker_client);
        return true;
    }

    // Check if this client has amnesty status cached (directly by client index)
    if (g_AmnestyPlayerSteamIDs[attacker_client][0] != '\0')
    {
        LogMessage("[GG2 TEAMKILL] AMNESTY granted to %N", attacker_client);
        return true;
    }

    LogMessage("[GG2 TEAMKILL] NO AMNESTY granted to %N", attacker_client);
    return false;
}

public void QueryAmnestyPlayers()
{
    if (g_Database == null) return;

    // Build list of connected player Steam IDs
    char steamIdList[2048];
    int  count = BuildConnectedSteamIDList(steamIdList, sizeof(steamIdList));

    // No players connected, nothing to query
    if (count == 0) return;

    int  time_cutoff_seconds = g_cvarAmnestyTimeCutoff.IntValue;
    int  min_kills           = g_cvarAmnestyMinKillCount.IntValue;
    int  min_kptk            = g_cvarAmnestyMinKPTK.IntValue;

    char query[2560];
    Format(query, sizeof(query),
           "SELECT steam_id FROM player_tks WHERE kills >= %i AND tk_given > 0 AND (kills::NUMERIC / tk_given) > %i AND last_seen > NOW() - INTERVAL '%i seconds' AND steam_id IN (%s)",
           min_kills, min_kptk, time_cutoff_seconds, steamIdList);

    g_Database.Query(OnAmnestyPlayersLoaded, query);
}

public void OnAmnestyPlayersLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (!HandleQueryError(results, error, "query amnesty players")) return;

    // Clear all amnesty data before repopulating
    for (int i = 1; i <= MaxClients; i++)
    {
        g_AmnestyPlayerSteamIDs[i][0] = '\0';
    }

    int rows = results.RowCount;
    LogMessage("[GG2 TEAMKILL] Retrieved %i TK Amnesty players for connected clients", rows);

    if (rows == 0) return;

    char steamid_64[64];
    while (results.FetchRow())
    {
        results.FetchString(0, steamid_64, sizeof(steamid_64));

        // Find which connected client this Steam ID belongs to
        for (int client = 1; client <= MaxClients; client++)
        {
            if (g_ConnectedSteamIDs[client][0] == '\0') continue;

            if (!StrEqual(g_ConnectedSteamIDs[client], steamid_64)) continue;

            // Store amnesty status for this client
            strcopy(g_AmnestyPlayerSteamIDs[client], sizeof(g_AmnestyPlayerSteamIDs[]), steamid_64);
            break;
        }
    }
}

public void QueryOffenderPlayers()
{
    if (g_Database == null) return;

    // Build list of connected player Steam IDs
    char steamIdList[2048];
    int  count = BuildConnectedSteamIDList(steamIdList, sizeof(steamIdList));

    // No players connected, nothing to query
    if (count == 0) return;

    char query[2560];
    Format(query, sizeof(query),
           "SELECT steam_id FROM player_tks WHERE kills >= 500 AND tk_given > 0 AND (kills::NUMERIC / tk_given) < 100 AND last_seen > NOW() - INTERVAL '90 days' AND steam_id IN (%s)",
           steamIdList);

    g_Database.Query(OnOffenderPlayersLoaded, query);
}

public void OnOffenderPlayersLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (!HandleQueryError(results, error, "query offender players")) return;

    // Clear all offender data before repopulating
    for (int i = 1; i <= MaxClients; i++)
    {
        g_OffenderSteamIDs[i][0] = '\0';
    }

    int rows = results.RowCount;
    LogMessage("[GG2 TEAMKILL] Retrieved %i TK Offenders for connected clients", rows);

    if (rows == 0) return;

    char steamid_64[64];
    while (results.FetchRow())
    {
        results.FetchString(0, steamid_64, sizeof(steamid_64));

        // Find which connected client this Steam ID belongs to
        for (int client = 1; client <= MaxClients; client++)
        {
            if (g_ConnectedSteamIDs[client][0] == '\0') continue;

            if (!StrEqual(g_ConnectedSteamIDs[client], steamid_64)) continue;

            // Store offender status for this client
            strcopy(g_OffenderSteamIDs[client], sizeof(g_OffenderSteamIDs[]), steamid_64);

            // Only notify once per client session
            if (!g_OffenderNotified[client] && IsClientInGame(client))
            {
                g_OffenderNotified[client] = true;
                CPrintToChatAll("{fullred}[KNOWN TK OFFENDER]{common} %N joined, watch out for this dickhead", client);
            }
            break;
        }
    }
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetPlayerTKData(i);
    }

    // Check if database connection is ready
    if (g_Database == null)
    {
        LogMessage("[GG2 TEAMKILL] Database unavailable at map start, attempting reconnection...");
        ReconnectDatabase();
    }

    // Refresh amnesty and offender lists at map start
    QueryAmnestyPlayers();
    QueryOffenderPlayers();

    // Set timers to refresh lists every 60 seconds
    CreateTimer(60.0, Timer_RefreshAmnestyList, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(60.0, Timer_RefreshOffenderList, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;

    // Update last_seen before clearing Steam ID
    UpdatePlayerLastSeen(client);

    ResetPlayerTKData(client);

    // Clear tracking data for this client slot
    g_ConnectedSteamIDs[client][0]     = '\0';
    g_AmnestyPlayerSteamIDs[client][0] = '\0';
    g_OffenderSteamIDs[client][0]      = '\0';
    g_OffenderNotified[client]         = false;
}

public Action Cmd_Forgive(int client, int args)
{
    int attacker = g_PlayerLastAttacker[client];
    if (attacker == 0)
    {
        CPrintToChat(client, "%T", "teamkill_noone_to_forgive", client);
        LogMessage("[GG TK_AUTO_BAN] %N attempted to forgive but nobody was forgivable", client);
        return Plugin_Handled;
    }

    LogMessage("[GG TK_AUTO_BAN] %N forgave %N, popping last entry in tk timer", client, attacker);
    g_PlayerLastAttacker[client] = 0;

    // Find and clear the most recent TK timestamp
    bool forgiven                = false;
    for (int i = 2; i >= 0; i--)
    {
        if (g_PlayerTKTimestamps[attacker][i] == 0) continue;

        g_PlayerTKTimestamps[attacker][i] = 0;
        forgiven                          = true;
        UpdateTKForgivenInDB(attacker, client);
        break;
    }

    if (!forgiven)
    {
        CPrintToChat(client, "%T", "teamkill_noone_to_forgive", client);
        LogMessage("[GG TK_AUTO_BAN] %N attempted to forgive but nobody was forgivable", client);
        return Plugin_Handled;
    }

    char forgiver_name[64];
    Format(forgiver_name, sizeof(forgiver_name), "%N", client);
    char forgiven_name[64];
    Format(forgiven_name, sizeof(forgiven_name), "%N", attacker);
    CPrintToChatAll("%t", "teamkill_player_forgiven", forgiver_name, forgiven_name);

    char discord_message[1024];
    FormatEx(discord_message, sizeof(discord_message), "[TK Auto-Ban] %N has forgiven %N for TK", client, attacker);
    send_to_discord(client, discord_message);

    return Plugin_Handled;
}

public bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

void ResetPlayerTKData(int client)
{
    g_PlayerTKTimestamps[client] = EMPTY_TK_TIMESTAMPS;
    g_PlayerLastAttacker[client] = 0;
}

void RecordTeamKill(int client, int victim)
{
    int insertedAtIndex          = -1;
    int now                      = GetTime();
    g_PlayerLastAttacker[victim] = client;
    for (int i = 0; i < 3; i++)
    {
        if (g_PlayerTKTimestamps[client][i] != 0) continue;

        g_PlayerTKTimestamps[client][i] = now;
        insertedAtIndex                 = i;
        break;
    }

    // shift arrays if we didn't insert
    if (insertedAtIndex != -1) return;

    g_PlayerTKTimestamps[client][0] = g_PlayerTKTimestamps[client][1];
    g_PlayerTKTimestamps[client][1] = g_PlayerTKTimestamps[client][2];
    g_PlayerTKTimestamps[client][2] = now;
}

// Calculates the number of valid (recent) teamkills for a player
// Returns: The count of teamkills that occurred within the g_TKTimeWindowSeconds time window
//
// Example: If a player has 3 TKs but 1 is older than g_TKTimeWindowSeconds, returns 2
int CountRecentTKs(int client)
{
    int now           = GetTime();
    int recentTKCount = 0;

    for (int i = 0; i < 3; i++)
    {
        int lastTKTime = g_PlayerTKTimestamps[client][i];

        // Empty slot - no more TKs to check
        if (lastTKTime == 0) break;

        // Check if this TK is within the time window
        if (now - lastTKTime <= g_TKTimeWindowSeconds)
        {
            recentTKCount++;
        }
    }

    return recentTKCount;
}

public bool ShouldLogWeapon(char[] weapon)
{
    return true;
    // rocket_arty kills are covered as 155 kills
    /*
    char blacklist_weapons[][] = {
        "grenade_m777_us",
        "grenade_m777_ins"
    };
    for (int i = 0; i <= sizeof(blacklist_weapons)-1; i++) {
        if (StrEqual(weapon, blacklist_weapons[i])) {
            return false;
        }
    }
    return true;
    */
}

// Record a teamkill to the database
void RecordTKToDatabase(int attacker, int victim, const char[] weapon)
{
    if (g_Database == null) return;

    // Use cached Steam IDs - if not available, the player disconnected
    if (g_ConnectedSteamIDs[attacker][0] == '\0')
    {
        LogError("[GG2 TEAMKILL] Cannot record TK: no cached steam_id for attacker %N", attacker);
        return;
    }

    if (g_ConnectedSteamIDs[victim][0] == '\0')
    {
        LogError("[GG2 TEAMKILL] Cannot record TK: no cached steam_id for victim %N", victim);
        return;
    }

    // Execute both queries in a single transaction for atomicity
    Transaction txn = new Transaction();

    // Upsert both players in a single query, incrementing their respective counters and updating last_seen
    char        upsertBothPlayersQuery[1536];
    g_Database.Format(upsertBothPlayersQuery, sizeof(upsertBothPlayersQuery),
                      "INSERT INTO player_tks (steam_id, tk_given, tk_taken, last_seen) VALUES (%s, 1, 0, CURRENT_TIMESTAMP), (%s, 0, 1, CURRENT_TIMESTAMP) \
           ON CONFLICT (steam_id) DO UPDATE SET tk_given = player_tks.tk_given + EXCLUDED.tk_given, tk_taken = player_tks.tk_taken + EXCLUDED.tk_taken, last_seen = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP",
                      g_ConnectedSteamIDs[attacker], g_ConnectedSteamIDs[victim]);
    txn.AddQuery(upsertBothPlayersQuery);

    // Insert TK record
    char insertQuery[512];
    g_Database.Format(insertQuery, sizeof(insertQuery),
                      "INSERT INTO player_tk_logs (attacker_steam_id, victim_steam_id, weapon, forgiven) \
                      VALUES (%s, %s, '%s', FALSE)",
                      g_ConnectedSteamIDs[attacker], g_ConnectedSteamIDs[victim], weapon);
    txn.AddQuery(insertQuery);

    // Execute transaction
    g_Database.Execute(txn, OnTKTransactionSuccess, OnTKTransactionFailure);
}

public void OnTKTransactionSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    // Do nothing
}

public void OnTKTransactionFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    LogError("[GG2 TEAMKILL] Transaction failed at query %d/%d: %s", failIndex + 1, numQueries, error);

    // Check if the error is due to lost connection
    if (StrContains(error, "no connection to the server", false) == -1) return;

    LogError("[GG2 TEAMKILL] Lost connection to database during TK recording - attempting to reconnect");
    ReconnectDatabase();
}

bool ShouldTriggerAutoBan(int client)
{
    int span = g_PlayerTKTimestamps[client][2] - g_PlayerTKTimestamps[client][0];
    if (span < 0) return false;

    return span < g_TKTimeWindowSeconds;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        ResetPlayerTKData(client);
    }

    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    // Ignore kills via objectives
    char weapon[32];
    GetEventString(event, "weapon", weapon, sizeof(weapon));
    if ((StrContains(weapon, "cache", false) != -1) || (!ShouldLogWeapon(weapon))) return Plugin_Continue;

    // Ignore bot and non-existent victims
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim == 0 || IsFakeClient(victim)) return Plugin_Continue;

    // Ignore bot kills and non-existent attackers
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsValidPlayer(attacker) || !IsClientInGame(attacker)) return Plugin_Continue;

    // Ignore suicides and world damage
    if (victim == attacker) return Plugin_Continue;

    // Ignore burn damage from non-flamethrower sources
    int bIsBurnDamage = GetEventInt(event, "damagebits") & DMG_BURN;
    if (bIsBurnDamage && !StrEqual("weapon_flamethrower", weapon)) return Plugin_Continue;

    // Ignore if either player is on the INS team
    int attackerTeam = GetClientTeam(attacker);
    int victimTeam   = GetClientTeam(victim);
    if (victimTeam == TEAM_INS || attackerTeam == TEAM_INS) return Plugin_Continue;

    // Ignore if not a teamkill
    if (victimTeam != attackerTeam) return Plugin_Continue;

    LogMessage("[GG TK_AUTO_BAN] %N killed a teammate (%N)", attacker, victim);

    // Record the teamkill to database
    RecordTKToDatabase(attacker, victim, weapon);

    if (PlayerHasAmnesty(attacker))
    {
        // Steam name can be a max of 32 chars. Double it to account for in-game name changes, like `[ADMIN]` and `[MEDIC]` prefixes.
        char amnesty_attacker[64];
        Format(amnesty_attacker, sizeof(amnesty_attacker), "%N", attacker);
        CPrintToChat(victim, "%T", "teamkiller_has_amnesty", victim, amnesty_attacker);

        // 36 chars for the raw message + 64 for the attacker name + 1 for null termination char = 101, with 91 left over for weapon name
        char d_message[192];
        Format(d_message, sizeof(d_message), "__***TK'd***__ %s (%s) (AMNESTY GRANTED)", amnesty_attacker, weapon);
        send_to_discord(attacker, d_message);

        return Plugin_Continue;
    }

    char d_message[192];
    Format(d_message, sizeof(d_message), "__***TK'd***__ %N (%s)", victim, weapon);
    send_to_discord(attacker, d_message);

    RecordTeamKill(attacker, victim);
    if (!ShouldTriggerAutoBan(attacker))
    {
        int tk_count = CountRecentTKs(attacker);
        // Disabled for now
        // if (tk_count == 1)
        // {
        //     ForcePlayerSuicide(attacker);
        // }

        CPrintToChat(attacker, "%T", "teamkill_be_careful", attacker, tk_count + 1);
        CPrintToChat(victim, "%T", "teamkill_how_to_forgive", victim);
        return Plugin_Continue;
    }

    LogMessage("[GG TK_AUTO_BAN] auto banning %N // %i / %i / %i // %d ", attacker, g_PlayerTKTimestamps[attacker][0], g_PlayerTKTimestamps[attacker][1], g_PlayerTKTimestamps[attacker][2], g_cvarBanTime.IntValue);

    char message[96];
    Format(message, sizeof(message), "Banned for %i minutes (TK AUTO-BAN)", g_cvarBanTime.IntValue);
    send_to_discord(attacker, message);

    int playerId = GetClientUserId(attacker);
    ServerCommand("sm_ban #%d %d Team Killing", playerId, g_cvarBanTime.IntValue);

    char attacker_name[64];
    Format(attacker_name, sizeof(attacker_name), "%N", attacker);
    CPrintToChatAll("%t", "teamkill_player_banned", attacker_name);

    ResetPlayerTKData(attacker);

    return Plugin_Continue;
}