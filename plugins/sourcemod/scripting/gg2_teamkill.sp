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

Database      g_Database = null;
// Ban duration in minutes when auto-ban is triggered (how long to ban the player)
ConVar        g_cvarBanTime;
GlobalForward g_TKForgivenForward;
GlobalForward g_TKAutoBanForward;
// Stores the timestamps (Unix epoch seconds) of the last 3 teamkills for each player.
// Array contents: [player index][0-2] = timestamp of each TK, with older entries shifting left when full
int           g_PlayerTKTimestamps[MAXPLAYERS + 1][3];
// Stores the client index of the attacker who most recently teamkilled each player.
// Array contents: [victim index] = attacker client index (used for the forgive command)
int           g_PlayerLastAttacker[MAXPLAYERS + 1];
int           EMPTY_TK_TIMESTAMPS[3] = { 0, 0, 0 };
// Time window in seconds for counting teamkills (e.g., 3 TKs within this period triggers auto-ban)
// This is different from g_cvarBanTime which controls how long the ban lasts
int           g_TKTimeWindowSeconds  = 600;    // 600 seconds = 10 minutes
char          INVALID_STEAM_ID[64]   = "STEAM_ID_STOP_IGNORING_RETVALS";

char          g_AmnestyPlayerSteamIDs[1024][64];
char          g_OffenderSteamIDs[1024][64];

public void OnPluginStart()
{
    g_cvarBanTime = CreateConVar("tk_ban_basetime", "5", "Base ban time (min)", FCVAR_PROTECTED);
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
    g_TKForgivenForward = new GlobalForward("TK_Forgiven", ET_Event, Param_Cell);
    g_TKAutoBanForward  = new GlobalForward("TK_AutoBan", ET_Event, Param_Cell);

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

public void OnClientAuthorized(int client)
{
    char steam_id[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steam_id, sizeof(steam_id))) return;

    if (StrEqual(steam_id, "\0") || (StrEqual(steam_id, INVALID_STEAM_ID))) return;

    if (IsFakeClient(client) || g_Database == null) return;

    if (!IsKnownTKOffender(steam_id)) return;

    CPrintToChatAll("{fullred}[KNOWN TK OFFENDER]{common} %N joined, watch out for this dickhead", client);
}

public Action SendForwardTKForgiven(int client)
{    // tug stats forward
    Action result;
    Call_StartForward(g_TKForgivenForward);
    Call_PushCell(client);
    Call_Finish(result);
    return result;
}

public Action SendForwardTKAutoBanFired(int client)
{    // tug stats forward
    Action result;
    Call_StartForward(g_TKAutoBanForward);
    Call_PushCell(client);
    Call_Finish(result);
    return result;
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

    char attacker_steamid64[64];
    if (!GetClientAuthId(attacker, AuthId_SteamID64, attacker_steamid64, sizeof(attacker_steamid64))) return;

    char victim_steamid64[64];
    if (!GetClientAuthId(victim, AuthId_SteamID64, victim_steamid64, sizeof(victim_steamid64))) return;

    char query[1024];
    g_Database.Format(query, sizeof(query),
                      "UPDATE player_tk_logs SET forgiven = TRUE \
                      WHERE id = ( \
                          SELECT id \
                          FROM player_tk_logs \
                          WHERE victim_steam_id = %s AND attacker_steam_id = %s \
                          ORDER BY id DESC LIMIT 1 \
                      )",
                      victim_steamid64, attacker_steamid64);

    g_Database.Query(OnTKForgivenUpdated, query);
}

public void OnTKForgivenUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "update TK forgiven status");
}

public bool PlayerHasAmnesty(int attacker_client)
{
    if (GetUserAdmin(attacker_client) != INVALID_ADMIN_ID)
    {
        LogMessage("[GG2 TEAMKILL] AMNESTY granted to admin %N", attacker_client);
        return true;
    }

    char attacker_steamid64[64];
    if (!GetClientAuthId(attacker_client, AuthId_SteamID64, attacker_steamid64, sizeof(attacker_steamid64))) return false;

    for (int i = 0; i < sizeof(g_AmnestyPlayerSteamIDs); i++)
    {
        if (StrEqual("", g_AmnestyPlayerSteamIDs[i])) break;

        if (!StrEqual(g_AmnestyPlayerSteamIDs[i], attacker_steamid64)) continue;

        LogMessage("[GG2 TEAMKILL] AMNESTY granted to %N", attacker_client);
        return true;
    }

    LogMessage("[GG2 TEAMKILL] NO AMNESTY granted to %N", attacker_client);
    return false;
}

public bool IsKnownTKOffender(char[] steam_id)
{
    for (int i = 0; i < sizeof(g_OffenderSteamIDs); i++)
    {
        if (StrEqual("", g_OffenderSteamIDs[i])) break;

        if (!StrEqual(g_OffenderSteamIDs[i], steam_id)) continue;
        LogMessage("[GG2 TEAMKILL] KNOWN OFFENDER JOINED NOTICE %s", steam_id);
        return true;
    }

    LogMessage("[GG2 TEAMKILL] Player not a KNOWN TK OFFENDER");
    return false;
}

public void QueryAmnestyPlayers()
{
    if (g_Database == null) return;

    char query[512];
    Format(query, sizeof(query),
           "SELECT steam_id FROM player_tks WHERE tk_amnesty = TRUE ORDER BY steam_id ASC LIMIT %d",
           sizeof(g_AmnestyPlayerSteamIDs));

    g_Database.Query(OnAmnestyPlayersLoaded, query);
}

public void OnAmnestyPlayersLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (!HandleQueryError(results, error, "query amnesty players")) return;

    // Clear the array before repopulating to prevent stale entries
    for (int i = 0; i < sizeof(g_AmnestyPlayerSteamIDs); i++)
    {
        g_AmnestyPlayerSteamIDs[i][0] = '\0';
    }

    int rows = results.RowCount;
    LogMessage("[GG2 TEAMKILL] Retrieved %i TK Amnesty players", rows);

    if (rows == 0) return;

    int  offset = 0;
    char steamid_64[64];
    while (results.FetchRow())
    {
        // Bounds check to prevent buffer overflow
        if (offset >= sizeof(g_AmnestyPlayerSteamIDs))
        {
            LogError("[GG2 TEAMKILL] WARNING: Amnesty list exceeded maximum capacity of %d entries. Increase array size!", sizeof(g_AmnestyPlayerSteamIDs));
            break;
        }

        results.FetchString(0, steamid_64, sizeof(steamid_64));
        g_AmnestyPlayerSteamIDs[offset] = steamid_64;
        offset++;
    }
}

public void QueryOffenderPlayers()
{
    if (g_Database == null) return;

    char query[512];
    int  now         = GetTime();
    int  time_cutoff = (now - 7776000);    // 90 days

    Format(query, sizeof(query),
           "SELECT steam_id FROM player_tks WHERE kills >= 500 AND tk_given > 0 AND (kills::NUMERIC / tk_given) < 100 AND last_seen > %i ORDER BY steam_id ASC LIMIT %d",
           time_cutoff, sizeof(g_OffenderSteamIDs));

    g_Database.Query(OnOffenderPlayersLoaded, query);
}

public void OnOffenderPlayersLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (!HandleQueryError(results, error, "query offender players")) return;

    // Clear the array before repopulating to prevent stale entries
    for (int i = 0; i < sizeof(g_OffenderSteamIDs); i++)
    {
        g_OffenderSteamIDs[i][0] = '\0';
    }

    int rows = results.RowCount;
    LogMessage("[GG2 TEAMKILL] Retrieved %i TK Offenders", rows);

    if (rows == 0) return;

    int  offset = 0;
    char steamid_64[64];
    while (results.FetchRow())
    {
        // Bounds check to prevent buffer overflow
        if (offset >= sizeof(g_OffenderSteamIDs))
        {
            LogError("[GG2 TEAMKILL] WARNING: Offender list exceeded maximum capacity of %d entries. Increase array size!", sizeof(g_OffenderSteamIDs));
            break;
        }

        results.FetchString(0, steamid_64, sizeof(steamid_64));
        g_OffenderSteamIDs[offset] = steamid_64;
        offset++;
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
    CreateTimer(60.0, Timer_RefreshAmnestyList, _, TIMER_REPEAT);
    CreateTimer(60.0, Timer_RefreshOffenderList, _, TIMER_REPEAT);
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;

    ResetPlayerTKData(client);
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
        SendForwardTKForgiven(client);
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

    // Get steam IDs for both players
    char attacker_steamid[64];
    if (!GetClientAuthId(attacker, AuthId_SteamID64, attacker_steamid, sizeof(attacker_steamid)))
    {
        LogError("[GG2 TEAMKILL] Cannot record TK: failed to get attacker steam_id for %N", attacker);
        return;
    }

    char victim_steamid[64];
    if (!GetClientAuthId(victim, AuthId_SteamID64, victim_steamid, sizeof(victim_steamid)))
    {
        LogError("[GG2 TEAMKILL] Cannot record TK: failed to get victim steam_id for %N", victim);
        return;
    }

    // Execute both queries in a single transaction for atomicity
    Transaction txn = new Transaction();

    // Upsert both players in a single query, incrementing their respective counters
    char        upsertBothPlayersQuery[1536];
    g_Database.Format(upsertBothPlayersQuery, sizeof(upsertBothPlayersQuery),
                      "INSERT INTO player_tks (steam_id, tk_given, tk_taken) VALUES (%s, 1, 0), (%s, 0, 1) \
           ON CONFLICT (steam_id) DO UPDATE SET tk_given = player_tks.tk_given + EXCLUDED.tk_given, tk_taken = player_tks.tk_taken + EXCLUDED.tk_taken, updated_at = CURRENT_TIMESTAMP",
                      attacker_steamid, victim_steamid);
    txn.AddQuery(upsertBothPlayersQuery);

    // Insert TK record
    char insertQuery[512];
    g_Database.Format(insertQuery, sizeof(insertQuery),
                      "INSERT INTO player_tk_logs (attacker_steam_id, victim_steam_id, weapon, forgiven) \
                      VALUES (%s, %s, '%s', FALSE)",
                      attacker_steamid, victim_steamid, weapon);
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

    char attackerSteamID[32];
    if (!GetClientAuthId(attacker, AuthId_SteamID64, attackerSteamID, sizeof(attackerSteamID))) return Plugin_Continue;

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
        if (tk_count == 1)
        {
            ForcePlayerSuicide(attacker);
        }

        // Format(chatMessage, sizeof(chatMessage),"\x07FF0000[TeamKill]\x0700FA9A BE MORE CAREFUL, TK COUNT: %i/3", tk_count);
        CPrintToChat(attacker, "%T", "teamkill_be_careful", attacker, tk_count + 1);
        // PrintToChat(victim, "\x07FF0000[TeamKill]\x07F8F8FF Type\x0700FA9A /forgive\x07F8F8FF in your chat to forgive your TKer. Otherwise, they may be banned.");
        CPrintToChat(victim, "%T", "teamkill_how_to_forgive", victim);
        return Plugin_Continue;
    }

    SendForwardTKAutoBanFired(attacker);

    LogMessage("[GG TK_AUTO_BAN] auto banning %N // %i / %i / %i // %d ", attacker, g_PlayerTKTimestamps[attacker][0], g_PlayerTKTimestamps[attacker][1], g_PlayerTKTimestamps[attacker][2], g_cvarBanTime.IntValue);

    char message[96];
    Format(message, sizeof(message), "Banned for %i minutes (TK AUTO-BAN)", g_cvarBanTime.IntValue);
    send_to_discord(attacker, message);

    int playerId = GetClientUserId(attacker);
    ServerCommand("sm_ban #%d %d Team Killing", playerId, g_cvarBanTime.IntValue);

    char attacker_name[64];
    Format(attacker_name, sizeof(attacker_name), "%N", attacker);
    // Format(chatMessage, sizeof(chatMessage), "\x07FF0000[TeamKill]\x0700FA9A %N WAS BANNED 5min FOR TKs", attacker);
    CPrintToChatAll("%t", "teamkill_player_banned", attacker_name);

    ResetPlayerTKData(attacker);

    return Plugin_Continue;
}