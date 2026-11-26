#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <discord>
#include <weaponnames>
#include <morecolors>
#include <dbi>
#include <gg2_stats>

// gg2_stats2 (include/gg2_stats.inc): raised when a victim forgives a team kill.
GlobalForward g_StatsForgivenForward;

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
// The server's stats v2 schema (issue #44), quoted; empty until found. Lifetime kills and team kills
// for amnesty come from its v_player_lifetime view.
char     g_StatsSchema[160];
// Ban duration in minutes when auto-ban is triggered (how long to ban the player)
ConVar   g_cvarBanTime;
// Amnesty criteria CVars
ConVar   g_cvarAmnestyMinKPTK;         // Minimum kills-per-TK ratio for amnesty
ConVar   g_cvarAmnestyMinKillCount;    // Minimum total kills required for amnesty
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
    g_StatsForgivenForward    = new GlobalForward("TeamKill_OnForgiven", ET_Ignore, Param_Cell, Param_Cell);
    g_cvarBanTime             = CreateConVar("tk_ban_basetime", "60", "Base ban time (min)", FCVAR_PROTECTED);
    g_cvarAmnestyMinKPTK      = CreateConVar("tk_amnesty_min_kptk", "250", "Minimum kills-per-TK ratio for amnesty", FCVAR_PROTECTED);
    g_cvarAmnestyMinKillCount = CreateConVar("tk_amnesty_min_kills", "1000", "Minimum total kills required for amnesty", FCVAR_PROTECTED);
    // Kept so existing configs that set it still load; amnesty is only ever checked for connected
    // players, who always pass an activity cutoff (see QueryAmnestyPlayers).
    CreateConVar("tk_amnesty_time_cutoff", "7776000", "Unused since stats v2 (issue #44): only connected players are checked, and they are always recent", FCVAR_PROTECTED);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("player_death", Event_PlayerDeath);

    // Localisation files are mounted by the engine and do not change between maps, so once is enough.
    WeaponNames_Load();

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
    FindStatsSchema();
}

// The one stats_* schema the database user owns (see stats_01_schema.sql). Without it there are no
// lifetime stats to judge amnesty by, so nobody gets amnesty and nobody is flagged.
void FindStatsSchema()
{
    g_Database.Query(OnStatsSchemaFound,
                     "SELECT quote_ident(nspname) FROM pg_namespace WHERE nspname LIKE 'stats\\_%' "
                   ... "AND nspowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)");
}

public void OnStatsSchemaFound(Database db, DBResultSet results, const char[] error, any data)
{
    if (!HandleQueryError(results, error, "find the stats schema")) return;
    if (results.RowCount != 1 || !results.FetchRow())
    {
        LogError("[GG2 TEAMKILL] %d stats_* schemas owned by this database user (need exactly 1): no amnesty or offender lists", results.RowCount);
        g_StatsSchema[0] = '\0';
        return;
    }
    results.FetchString(0, g_StatsSchema, sizeof(g_StatsSchema));
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
    FindStatsSchema();
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
// Set quoted for text columns (player_stats.steam_id); leave it off for numeric columns
// (player_tks.steam_id).
// Returns the number of connected players added to the buffer
int BuildConnectedSteamIDList(char[] buffer, int maxlen, bool quoted = false)
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

        offset += FormatEx(buffer[offset], maxlen - offset, quoted ? "'%s'" : "%s", g_ConnectedSteamIDs[i]);
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

// The forgive is recorded by gg2_stats2 (team_kill_forgives) from this forward.
public void UpdateTKForgivenInDB(int attacker, int victim)
{
    Call_StartForward(g_StatsForgivenForward);
    Call_PushCell(victim);
    Call_PushCell(attacker);
    Call_Finish();
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

// Amnesty: at least tk_amnesty_min_kills lifetime kills and a kill/TK ratio above
// tk_amnesty_min_kptk. Both come from the stats v2 view v_player_lifetime (kills of enemies, team
// kills given), which covers all of a player's recorded play. Only connected players are looked up,
// so the old "active within tk_amnesty_time_cutoff" test is always met and is not repeated.
public void QueryAmnestyPlayers()
{
    if (g_Database == null || g_StatsSchema[0] == '\0') return;

    char steamIdList[2048];
    if (BuildConnectedSteamIDList(steamIdList, sizeof(steamIdList)) == 0) return;

    char query[3072];
    Format(query, sizeof(query),
           "SELECT steam_id::text FROM %s.v_player_lifetime "
         ... "WHERE steam_id = ANY(ARRAY[%s]::bigint[]) AND kills >= %i AND team_kills > 0 "
         ... "AND (kills::numeric / team_kills) > %i",
           g_StatsSchema, steamIdList, g_cvarAmnestyMinKillCount.IntValue, g_cvarAmnestyMinKPTK.IntValue);

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

// Offenders: at least 500 lifetime kills and a kill/TK ratio under 100, from v_player_lifetime as
// for amnesty. The old "active in the last 90 days" test is always met by a connected player.
public void QueryOffenderPlayers()
{
    if (g_Database == null || g_StatsSchema[0] == '\0') return;

    char steamIdList[2048];
    if (BuildConnectedSteamIDList(steamIdList, sizeof(steamIdList)) == 0) return;

    char query[3072];
    Format(query, sizeof(query),
           "SELECT steam_id::text FROM %s.v_player_lifetime "
         ... "WHERE steam_id = ANY(ARRAY[%s]::bigint[]) AND kills >= 500 AND team_kills > 0 "
         ... "AND (kills::numeric / team_kills) < 100",
           g_StatsSchema, steamIdList);

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

    // The team kill itself is recorded by gg2_stats2 (a kills row of kind team_kill).

    // Both Discord lines below name the victim and the weapon, so build them once here.
    //
    // The victim's name is linked the same way send_to_discord links the attacker's, so both sides
    // of the TK are clickable rather than just the killer. discord_player_link only fails for a
    // client who is not in game, which is already ruled out above; the fallback is there so a future
    // change to that contract degrades to a plain name instead of an uninitialised buffer.
    char victim_link[192];
    if (!discord_player_link(victim, victim_link, sizeof(victim_link)))
        Format(victim_link, sizeof(victim_link), "%N", victim);

    // The display name, not the classname: "M67" rather than "grenade_m67". See weaponnames.inc.
    char weapon_name[64];
    WeaponNames_Get(weapon, weapon_name, sizeof(weapon_name));

    if (PlayerHasAmnesty(attacker))
    {
        // Steam name can be a max of 32 chars. Double it to account for in-game name changes, like `[ADMIN]` and `[MEDIC]` prefixes.
        char amnesty_attacker[64];
        Format(amnesty_attacker, sizeof(amnesty_attacker), "%N", attacker);
        CPrintToChat(victim, "%T", "teamkiller_has_amnesty", victim, amnesty_attacker);

        // The VICTIM goes in the message, not the attacker. send_to_discord already prefixes the
        // line with the name of the client passed as its first argument - "<attacker>: <message>" -
        // so naming the attacker again here printed them on both sides of the TK:
        //     pl0x: TK'd pl0x (p90) (AMNESTY GRANTED)
        // amnesty_attacker stays for the chat line above, where naming the attacker IS the point:
        // that one tells the victim who killed them.
        char d_message[512];
        Format(d_message, sizeof(d_message), "__***TK'd***__ %s (%s) (AMNESTY GRANTED)", victim_link, weapon_name);
        send_to_discord(attacker, d_message);

        return Plugin_Continue;
    }

    char d_message[512];
    Format(d_message, sizeof(d_message), "__***TK'd***__ %s (%s)", victim_link, weapon_name);
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