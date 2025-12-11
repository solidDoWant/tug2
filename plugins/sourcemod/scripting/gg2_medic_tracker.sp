#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <morecolors>
#include <discord>

#pragma newdecls required

#define STEAM_ID_SIZE 64

public Plugin myinfo =
{
    name        = "[GG2 Medic Tracker]",
    author      = "zachm",
    description = "Don't let shit ass medics be medics",
    version     = "0.1",
    url         = "https://tug.gg"
};

Database g_Database = null;
char     g_client_steam_ids[MAXPLAYERS + 1][STEAM_ID_SIZE];
bool     g_client_is_medic[MAXPLAYERS + 1];
int      g_client_medic_class_time_tracker_seconds[MAXPLAYERS + 1];

int      g_round_medic_revives[MAXPLAYERS + 1];
int      g_round_medic_heals[MAXPLAYERS + 1];
int      g_current_revivable;
int      g_current_fatal;

char     g_banned_medic_steam_ids[MAXPLAYERS + 1][STEAM_ID_SIZE];
int      g_banned_medic_steam_ids_count = 0;
int      g_medic_ban_warning_count[MAXPLAYERS + 1];

ConVar   g_cvar_ban_warning_threshold;
ConVar   g_cvar_ban_warning_interval;

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[GG2 Medic Tracker] Failed to connect to database: %s", error);
        SetFailState("Database connection failed");
        return;
    }

    g_Database = db;
    LogMessage("[GG2 Medic Tracker] Successfully connected to database");
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    LogMessage("[GG2 Medic Tracker] Attempting to reconnect to database...");
    g_Database = null;
    Database.Connect(OnDatabaseReconnected, "insurgency-stats");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[GG2 Medic Tracker] Failed to reconnect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("[GG2 Medic Tracker] Successfully reconnected to database");
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database == null)
        ReconnectDatabase();

    return Plugin_Stop;
}

// Helper function to handle database query errors
void HandleQueryError(DBResultSet results, const char[] error, const char[] operationName)
{
    if (results != null) return;

    // Check if the error is due to lost connection
    if (StrContains(error, "no connection to the server", false) == -1)
    {
        LogError("[GG2 Medic Tracker] Failed to %s: %s", operationName, error);
        return;
    }

    LogError("[GG2 Medic Tracker] Lost connection to database: %s - attempting to reconnect", error);
    ReconnectDatabase();
}

public void OnPluginStart()
{
    Database.Connect(OnDatabaseConnected, "insurgency-stats");
    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
    RegAdminCmd("medic_stats2", Cmd_GetCurrentMedicStats, ADMFLAG_GENERIC, "Show stats for the current medics (medic class)");
    RegAdminCmd("sm_ban_medic", Cmd_BanMedic, ADMFLAG_BAN, "Ban a player from playing medic class");
    RegAdminCmd("sm_unban_medic", Cmd_UnbanMedic, ADMFLAG_BAN, "Unban a player from medic class");

    g_cvar_ban_warning_threshold = CreateConVar("sm_medic_ban_warning_threshold", "3", "Number of warnings before kicking banned medic", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    g_cvar_ban_warning_interval  = CreateConVar("sm_medic_ban_warning_interval", "15.0", "Interval in seconds between banned medic warnings", FCVAR_NOTIFY, true, 5.0, true, 60.0);

    AutoExecConfig(true, "gg2_medic_tracker");
}

public void OnMapStart()
{
    clear_medic_flags();
    clear_medic_tracker();
    clear_warning_counts();

    CreateTimer(10.0, Timer_GetBannedMedics, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(5.0, Timer_MedicClassTracker, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(g_cvar_ban_warning_interval.FloatValue, Timer_WarnBannedMedics, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Cmd_GetCurrentMedicStats(int caller_client, int args)
{
    bool any_medics = false;
    char message[128];
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidPlayer(client)) continue;
        if (IsFakeClient(client)) continue;
        if (!is_medic(client)) continue;

        any_medics     = true;
        char status[8] = "alive";
        if (!IsPlayerAlive(client))
        {
            status = "dead";
        }

        int minutes = g_client_medic_class_time_tracker_seconds[client] % 3600 / 60;
        int seconds = g_client_medic_class_time_tracker_seconds[client] % 60;
        Format(message, sizeof(message), "%N (%s) heals: %i // revives: %i // medic_time: %02d:%02d", client, status, g_round_medic_heals[client], g_round_medic_revives[client], minutes, seconds);
        ReplyToCommand(caller_client, message);
    }

    if (!any_medics)
    {
        ReplyToCommand(caller_client, "0 Medics in game right now, please try your call later");
        return Plugin_Continue;
    }

    ReplyToCommand(caller_client, "current revivable: %i // current fatal: %i (right now)", g_current_revivable, g_current_fatal);
    return Plugin_Continue;
}

public bool is_medic(int client)
{
    return g_client_is_medic[client];
}

public Action Dead_Count(int revivable, int fatal)
{
    g_current_revivable = revivable;
    g_current_fatal     = fatal;
    return Plugin_Continue;
}

public Action Medic_Revived(int reviver_client, int saved_client)
{
    if (!IsValidPlayer(reviver_client)) return Plugin_Continue;

    g_round_medic_revives[reviver_client]++;
    return Plugin_Continue;
}

public Action Medic_Healed(int healer_client, int saved_client)
{
    if (!IsValidPlayer(healer_client)) return Plugin_Continue;

    g_round_medic_heals[healer_client]++;
    return Plugin_Continue;
}

public void OnMapEnd()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientConnected(client)) continue;
        if (g_client_medic_class_time_tracker_seconds[client] == 0) continue;
    }
}

public void clear_medic_tracker()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_client_medic_class_time_tracker_seconds[client] = 0;
    }
}

public void clear_medic_flags()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_client_is_medic[client] = false;
    }
}

public void clear_warning_counts()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_medic_ban_warning_count[client] = 0;
    }
}

public void OnClientPostAdminCheck(int client)
{
    GetClientAuthId(client, AuthId_SteamID64, g_client_steam_ids[client], sizeof(g_client_steam_ids[]));
}

public void update_medic_time_in_db(int client)
{
    if (g_client_medic_class_time_tracker_seconds[client] == 0) return;
    if (!IsClientConnected(client)) return;
    if (g_Database == null) return;

    int  time_to_add = g_client_medic_class_time_tracker_seconds[client];

    char query[512];
    Format(query, sizeof(query), "INSERT INTO medics (steamId, banned, medic_time) VALUES ('%s', FALSE, %i) ON CONFLICT (steamId) DO UPDATE SET medic_time = medics.medic_time + EXCLUDED.medic_time", g_client_steam_ids[client], time_to_add);

    g_Database.Query(OnMedicTimeSaved, query, client);

    g_client_medic_class_time_tracker_seconds[client] = 0;
}

public void OnMedicTimeSaved(Database db, DBResultSet results, const char[] error, any client)
{
    HandleQueryError(results, error, "save medic time");
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientConnected(client)) continue;
        if (IsFakeClient(client)) continue;

        g_round_medic_revives[client] = 0;
        g_round_medic_heals[client]   = 0;

        if (!is_medic(client)) continue;

        update_medic_time_in_db(client);
    }

    g_current_revivable = 0;
    g_current_fatal     = 0;

    return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client)) return Plugin_Continue;

    if (is_medic(client))
    {
        update_medic_time_in_db(client);
    }

    // Only reset warning count if they weren't kicked (counter <= threshold)
    int threshold = g_cvar_ban_warning_threshold.IntValue;
    if (g_medic_ban_warning_count[client] <= threshold)
    {
        g_medic_ban_warning_count[client] = 0;
    }

    g_client_steam_ids[client]                        = "";
    g_client_is_medic[client]                         = false;
    g_round_medic_revives[client]                     = 0;
    g_round_medic_heals[client]                       = 0;
    g_client_medic_class_time_tracker_seconds[client] = 0;

    return Plugin_Continue;
}

public Action Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client)) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;

    char class_template[64];
    event.GetString("class_template", class_template, sizeof(class_template));

    bool new_class_is_medic = StrContains(class_template, "medic") != -1;

    // they're changing from medic to something else
    if (is_medic(client) && !new_class_is_medic)
    {
        update_medic_time_in_db(client);
        // Reset warning count when they change away from medic
        g_medic_ban_warning_count[client] = 0;
    }

    g_client_is_medic[client] = new_class_is_medic;

    return Plugin_Continue;
}

bool IsPlayingSolo()
{
    bool foundFirstPlayer = false;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientConnected(client)) continue;
        if (IsFakeClient(client)) continue;

        if (foundFirstPlayer) return false;
        foundFirstPlayer = true;
    }
    return true;
}

public Action Timer_MedicClassTracker(Handle timer)
{
    // Don't take action when solo, or when the round isn't running
    if (!IsGameActive()) return Plugin_Continue;
    if (IsPlayingSolo()) return Plugin_Continue;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidPlayer(client)) continue;
        if (IsFakeClient(client)) continue;
        if (!is_medic(client)) continue;

        g_client_medic_class_time_tracker_seconds[client] += 5;
    }

    return Plugin_Continue;
}

public Action Timer_GetBannedMedics(Handle timer)
{
    // Don't take action when solo, or when the round isn't running
    if (!IsGameActive()) return Plugin_Continue;
    if (IsPlayingSolo()) return Plugin_Continue;

    // Build list of connected players' Steam IDs for query optimization
    char steam_ids_list[2048] = "";
    bool has_players          = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientConnected(client)) continue;
        if (IsFakeClient(client)) continue;
        if (strlen(g_client_steam_ids[client]) == 0) continue;

        if (has_players)
        {
            StrCat(steam_ids_list, sizeof(steam_ids_list), "','");
        }
        StrCat(steam_ids_list, sizeof(steam_ids_list), g_client_steam_ids[client]);
        has_players = true;
    }

    // If no players connected, skip query
    if (!has_players) return Plugin_Continue;
    if (g_Database == null) return Plugin_Continue;

    // Only query for banned status of currently connected players
    char query[2304];
    Format(query, sizeof(query), "SELECT steamId FROM medics WHERE banned = TRUE AND steamId IN ('%s')", steam_ids_list);
    g_Database.Query(OnBannedMedicsFetched, query);
    return Plugin_Continue;
}

public Action Timer_WarnBannedMedics(Handle timer)
{
    // Don't take action when solo, or when the round isn't running
    if (!IsGameActive()) return Plugin_Continue;
    if (IsPlayingSolo()) return Plugin_Continue;

    int threshold = g_cvar_ban_warning_threshold.IntValue;

    // Warn all currently connected banned medics
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidPlayer(client)) continue;
        if (IsFakeClient(client)) continue;
        if (!is_medic(client)) continue;
        if (!is_medic_banned(client)) continue;

        g_medic_ban_warning_count[client]++;

        if (g_medic_ban_warning_count[client] > threshold)
        {
            // Kick on offense after threshold
            KickClient(client, "[MEDIC BAN] You have been kicked for playing medic class after poor medic performance.", threshold);
            LogMessage("[GG2 Medic Tracker] Kicked medic %N", client);
            continue;
        }

        // Show warning
        int warnings_left = threshold - g_medic_ban_warning_count[client] + 1;
        CPrintToChat(client, "{red}[WARNING %i/%i] You are banned from playing medic! Change your class or be kicked.", g_medic_ban_warning_count[client], threshold);
        PrintCenterText(client, "MEDIC BAN WARNING %i/%i - CHANGE CLASS OR BE KICKED", g_medic_ban_warning_count[client], threshold);
        LogMessage("[GG2 Medic Tracker] Warned banned medic %N (%i/%i)", client, g_medic_ban_warning_count[client], threshold);
    }

    return Plugin_Continue;
}

public void OnBannedMedicsFetched(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        HandleQueryError(results, error, "fetch banned medics");
        return;
    }

    // Clear and repopulate the banned list
    g_banned_medic_steam_ids_count = 0;

    if (results.RowCount == 0) return;

    while (results.FetchRow())
    {
        // Check array bounds before adding
        if (g_banned_medic_steam_ids_count >= MAXPLAYERS)
        {
            LogError("[GG2 Medic Tracker] Banned medics array full, cannot add more entries");
            break;
        }

        char banned_id[STEAM_ID_SIZE];
        results.FetchString(0, banned_id, sizeof(banned_id));
        strcopy(g_banned_medic_steam_ids[g_banned_medic_steam_ids_count], STEAM_ID_SIZE, banned_id);
        g_banned_medic_steam_ids_count++;
    }
}

public bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

public bool is_medic_banned(int client)
{
    for (int i = 0; i < g_banned_medic_steam_ids_count; i++)
    {
        if (StrEqual(g_client_steam_ids[client], g_banned_medic_steam_ids[i])) return true;
    }

    return false;
}

int GetGameState()
{
    return GameRules_GetProp("m_iGameState");
}

bool IsGameActive()
{
    int state = GetGameState();
    // 1 - Pregame/Warmup
    // 2 - Game start
    // 3 - Pre-round (countdown)
    // 4 - Round running (active gameplay)
    return state >= 1 && state <= 4;
}

public Action Cmd_BanMedic(int caller_client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(caller_client, "[SM] Usage: sm_ban_medic <target>");
        return Plugin_Handled;
    }

    char arg[65];
    GetCmdArg(1, arg, sizeof(arg));

    int target_client = FindTarget(caller_client, arg, true, false);
    if (target_client == -1) return Plugin_Handled;

    if (IsFakeClient(target_client))
    {
        ReplyToCommand(caller_client, "[SM] Cannot ban bots from medic class");
        return Plugin_Handled;
    }

    if (is_medic_banned(target_client))
    {
        ReplyToCommand(caller_client, "[SM] %N is already banned from medic class", target_client);
        return Plugin_Handled;
    }

    char target_steam_id[STEAM_ID_SIZE];
    strcopy(target_steam_id, sizeof(target_steam_id), g_client_steam_ids[target_client]);

    if (strlen(target_steam_id) == 0)
    {
        ReplyToCommand(caller_client, "[SM] Could not retrieve Steam ID for %N", target_client);
        return Plugin_Handled;
    }

    if (g_Database == null)
    {
        ReplyToCommand(caller_client, "[SM] Database unavailable");
        return Plugin_Handled;
    }

    // Update database to ban the player
    char query[512];
    Format(query, sizeof(query), "INSERT INTO medics (steamId, banned, medic_time) VALUES ('%s', TRUE, 0) ON CONFLICT (steamId) DO UPDATE SET banned = TRUE", target_steam_id);

    DataPack pack = new DataPack();
    pack.WriteCell(caller_client);
    pack.WriteCell(target_client);
    pack.WriteString(target_steam_id);

    g_Database.Query(OnMedicBanned, query, pack);

    return Plugin_Handled;
}

public void OnMedicBanned(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int  caller_client = pack.ReadCell();
    int  target        = pack.ReadCell();

    char target_steam_id[STEAM_ID_SIZE];
    pack.ReadString(target_steam_id, sizeof(target_steam_id));
    delete pack;

    if (results == null)
    {
        HandleQueryError(results, error, "ban medic");
        if (IsClientConnected(caller_client))
        {
            ReplyToCommand(caller_client, "[SM] Database error while banning medic");
        }
        return;
    }

    // Add to banned list immediately
    if (g_banned_medic_steam_ids_count < MAXPLAYERS)
    {
        strcopy(g_banned_medic_steam_ids[g_banned_medic_steam_ids_count], STEAM_ID_SIZE, target_steam_id);
        g_banned_medic_steam_ids_count++;
    }

    // Notify admin
    if (IsClientConnected(caller_client))
    {
        ReplyToCommand(caller_client, "[SM] Successfully banned %N from medic class", target);
    }

    // Send Discord notification
    char target_name[MAX_NAME_LENGTH];
    if (IsClientConnected(target))
    {
        GetClientName(target, target_name, sizeof(target_name));
    }
    else
    {
        strcopy(target_name, sizeof(target_name), "Unknown");
    }

    char admin_name[MAX_NAME_LENGTH];
    if (caller_client == 0)
    {
        strcopy(admin_name, sizeof(admin_name), "Console");
    }
    else if (IsClientConnected(caller_client))
    {
        GetClientName(caller_client, admin_name, sizeof(admin_name));
    }
    else
    {
        strcopy(admin_name, sizeof(admin_name), "Unknown");
    }

    char discord_msg[256];
    Format(discord_msg, sizeof(discord_msg), "**[MEDIC BAN]** %s banned %s from playing medic class", admin_name, target_name);
    send_to_discord(0, discord_msg);

    // Notify target if still connected
    if (!IsClientConnected(target)) return;

    CPrintToChat(target, "{red}[MEDIC BAN] You have been banned from playing medic class!");
    LogMessage("[GG2 Medic Tracker] Admin banned %N from medic class", target);

    // If they're currently a medic, warn them immediately
    if (!is_medic(target)) return;
    CPrintToChat(target, "{red}[MEDIC BAN] Change your class immediately or you will be kicked!");
    PrintCenterText(target, "YOU ARE BANNED FROM MEDIC - CHANGE CLASS NOW");
}

public Action Cmd_UnbanMedic(int caller_client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(caller_client, "[SM] Usage: sm_unban_medic <target>");
        return Plugin_Handled;
    }

    char arg[65];
    GetCmdArg(1, arg, sizeof(arg));

    int target_client = FindTarget(caller_client, arg, true, false);
    if (target_client == -1) return Plugin_Handled;

    if (IsFakeClient(target_client))
    {
        ReplyToCommand(caller_client, "[SM] Bots cannot be banned from medic class");
        return Plugin_Handled;
    }

    if (!is_medic_banned(target_client))
    {
        ReplyToCommand(caller_client, "[SM] %N is not banned from medic class", target_client);
        return Plugin_Handled;
    }

    char target_steam_id[STEAM_ID_SIZE];
    strcopy(target_steam_id, sizeof(target_steam_id), g_client_steam_ids[target_client]);

    if (strlen(target_steam_id) == 0)
    {
        ReplyToCommand(caller_client, "[SM] Could not retrieve Steam ID for %N", target_client);
        return Plugin_Handled;
    }

    if (g_Database == null)
    {
        ReplyToCommand(caller_client, "[SM] Database unavailable");
        return Plugin_Handled;
    }

    // Update database to unban the player
    char query[512];
    Format(query, sizeof(query), "UPDATE medics SET banned = FALSE WHERE steamId = '%s'", target_steam_id);

    DataPack pack = new DataPack();
    pack.WriteCell(caller_client);
    pack.WriteCell(target_client);
    pack.WriteString(target_steam_id);

    g_Database.Query(OnMedicUnbanned, query, pack);

    return Plugin_Handled;
}

public void OnMedicUnbanned(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int  caller_client = pack.ReadCell();
    int  target        = pack.ReadCell();

    char target_steam_id[STEAM_ID_SIZE];
    pack.ReadString(target_steam_id, sizeof(target_steam_id));
    delete pack;

    if (results == null)
    {
        HandleQueryError(results, error, "unban medic");
        if (IsClientConnected(caller_client))
        {
            ReplyToCommand(caller_client, "[SM] Database error while unbanning medic");
        }
        return;
    }

    // Remove from banned list
    for (int i = 0; i < g_banned_medic_steam_ids_count; i++)
    {
        if (!StrEqual(g_banned_medic_steam_ids[i], target_steam_id)) continue;

        // Shift remaining entries down
        for (int j = i; j < g_banned_medic_steam_ids_count - 1; j++)
        {
            strcopy(g_banned_medic_steam_ids[j], STEAM_ID_SIZE, g_banned_medic_steam_ids[j + 1]);
        }
        g_banned_medic_steam_ids_count--;
        break;
    }

    // Notify admin
    if (IsClientConnected(caller_client))
    {
        ReplyToCommand(caller_client, "[SM] Successfully unbanned %N from medic class", target);
    }

    // Send Discord notification
    char target_name[MAX_NAME_LENGTH];
    if (IsClientConnected(target))
    {
        GetClientName(target, target_name, sizeof(target_name));
    }
    else
    {
        strcopy(target_name, sizeof(target_name), "Unknown");
    }

    char admin_name[MAX_NAME_LENGTH];
    if (caller_client == 0)
    {
        strcopy(admin_name, sizeof(admin_name), "Console");
    }
    else if (IsClientConnected(caller_client))
    {
        GetClientName(caller_client, admin_name, sizeof(admin_name));
    }
    else
    {
        strcopy(admin_name, sizeof(admin_name), "Unknown");
    }

    char discord_msg[256];
    Format(discord_msg, sizeof(discord_msg), "**[MEDIC UNBAN]** %s unbanned %s from medic class", admin_name, target_name);
    send_to_discord(0, discord_msg);

    // Notify target if still connected
    if (!IsClientConnected(target)) return;

    g_medic_ban_warning_count[target] = 0;
    CPrintToChat(target, "{green}[MEDIC BAN] You have been unbanned from playing medic class!");
    LogMessage("[GG2 Medic Tracker] Admin unbanned %N from medic class", target);
}
