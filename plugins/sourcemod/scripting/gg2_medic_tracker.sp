#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <classtemplate>

#pragma newdecls required

#define STEAM_ID_SIZE 64

public Plugin myinfo =
{
    name        = "[GG2 Medic Tracker]",
    author      = "zachm",
    description = "Tracks medic playtime and per-round medic stats",
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

// Medic bans used to live here too (sm_ban_medic / sm_unban_medic, warn-then-kick). They are class
// bans in punitive_persistence now - sm_banclass <player> medic - which block the pick itself.

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

    ClassTemplate_Init();
}

// Loaded mid-map (a reload or hot patch): OnClientPostAdminCheck and player_pick_squad already
// happened for everyone here, so medic time would go untracked - or be saved against an empty
// SteamID. Rebuilt here rather than in OnPluginStart because a late load also runs OnMapStart,
// which clears the medic flags.
public void OnConfigsExecuted()
{
    static bool restored = false;
    if (restored) return;
    restored = true;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client)) continue;
        if (IsClientAuthorized(client)) OnClientPostAdminCheck(client);

        char class_template[64];
        if (ClassTemplate_Get(client, class_template, sizeof(class_template)))
            g_client_is_medic[client] = StrContains(class_template, "medic") != -1;
    }
}

public void OnMapStart()
{
    clear_medic_flags();
    clear_medic_tracker();

    CreateTimer(5.0, Timer_MedicClassTracker, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
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

public void Dead_Count(int revivable, int fatal)
{
    g_current_revivable = revivable;
    g_current_fatal     = fatal;
}

public void Medic_Revived(int reviver_client, int saved_client)
{
    if (!IsValidPlayer(reviver_client)) return;

    g_round_medic_revives[reviver_client]++;
}

public void Medic_Healed(int healer_client, int saved_client)
{
    if (!IsValidPlayer(healer_client)) return;

    g_round_medic_heals[healer_client]++;
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

public bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
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
