#include <sourcemod>
#include <sdkhooks>
#include <smlib>
#include <morecolors>
#include <dbi>

#pragma newdecls required

#define healthkit_weapon_name "weapon_healthkit"
#define defib_weapon_name     "weapon_defib"

#define MAX_MESSAGES          64

Database   g_Database                        = null;

int        g_rotating_player_messages_offset = 0;
int        g_rotating_admin_messages_offset  = 0;
char       rotating_player_messages[MAX_MESSAGES][MAX_MESSAGE_LENGTH];
char       rotating_admin_messages[MAX_MESSAGES][MAX_MESSAGE_LENGTH];
char       player_join_messages[MAX_MESSAGES][MAX_MESSAGE_LENGTH];
bool       g_has_player_seen_first_connect_message[MAXPLAYERS + 1];

bool       g_is_last_cap_cache;

char       in_counter_attack_cache_message[] = "{dodgerblue}COUNTERATTACK:{default} {yellow}Last cap was a cache, you need only to survive the counter!";
char       in_counter_attack_hold_message[]  = "{dodgerblue}COUNTERATTACK:{default} {yellow}DEFEND THE CAP, DO NOT PUSH!";

native int Ins_ObjectiveResource_GetProp(const char[] prop, int size = 4, int element = 0);
bool       InCounterAttack()
{
    return view_as<bool>(GameRules_GetProp("m_bCounterAttack"));
}

public Plugin myinfo =
{
    name        = "[GG2 Messages] MESSAGES plugin",
    author      = "zachm",
    description = "Get messages from the db, put them into game chat",
    version     = "0.0.1",
    url         = "http://sourcemod.net/"
};

public void OnMapStart()
{
    CreateTimer(30.0, Timer_RotatingPlayerMessages, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(120.0, Timer_RotatingAdminMessages, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    // Check if database connection is ready
    if (g_Database == null)
    {
        LogMessage("[GG2 MESSAGES] Database unavailable at map start, attempting reconnection...");
        ReconnectDatabase();
    }

    // Refresh message lists at map start
    QueryRotatingPlayerMessages();
    QueryRotatingAdminMessages();
    QueryPlayerJoinMessages();
}

public void OnPluginStart()
{
    HookEvent("player_spawn", Event_PlayerSpawnInit, EventHookMode_Post);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured, EventHookMode_Pre);
    HookEvent("object_destroyed", Event_ObjectDestroyed, EventHookMode_Pre);
    HookEvent("weapon_deploy", Event_WeaponDeploy);

    Database.Connect(OnDatabaseConnected, "insurgency-stats");

    LoadTranslations("tug.phrases");
}

public Action Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    g_is_last_cap_cache = false;
    CreateTimer(2.0, Timer_CheckInCounter, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
    g_is_last_cap_cache = true;
    CreateTimer(2.0, Timer_CheckInCounter, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

public Action Event_WeaponDeploy(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client)) return Plugin_Continue;

    char weapon_name[64];
    GetClientWeapon(client, weapon_name, sizeof(weapon_name));

    if (StrEqual(weapon_name, healthkit_weapon_name, false))
    {
        PrintHintText(client, "%T", "justholdit", client);
        return Plugin_Continue;
    }

    if (StrEqual(weapon_name, defib_weapon_name, false))
    {
        PrintHintText(client, "%T", "justholditdefib", client);
    }

    return Plugin_Continue;
}

public bool is_translatable(char[] phrase)
{
    return StrContains(phrase, " ") == -1;
}

public Action Timer_CheckInCounter(Handle timer)
{
    if (!InCounterAttack()) return Plugin_Continue;

    if (g_is_last_cap_cache)
    {
        CPrintToChatAll(in_counter_attack_cache_message);
        return Plugin_Continue;
    }

    CPrintToChatAll(in_counter_attack_hold_message);

    return Plugin_Continue;
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[GG2 MESSAGES] Failed to connect to database: %s", error);
        SetFailState("Database connection failed");
        return;
    }

    g_Database = db;
    LogMessage("[GG2 MESSAGES] Successfully connected to database");

    // Refresh message lists on connect
    QueryRotatingPlayerMessages();
    QueryRotatingAdminMessages();
    QueryPlayerJoinMessages();

    // Setup recurring reload of messages every 5 minutes
    CreateTimer(300.0, Timer_LoadMessages, _, TIMER_REPEAT);
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    LogMessage("[GG2 MESSAGES] Attempting to reconnect to database...");
    g_Database = null;
    Database.Connect(OnDatabaseReconnected, "insurgency-stats");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[GG2 MESSAGES] Failed to reconnect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("[GG2 MESSAGES] Successfully reconnected to database");

    // Refresh lists after reconnection
    QueryRotatingPlayerMessages();
    QueryRotatingAdminMessages();
    QueryPlayerJoinMessages();
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database == null)
    {
        ReconnectDatabase();
    }

    return Plugin_Stop;
}

// Helper function to handle database query errors
// Returns true if query was successful, false if there was an error
bool HandleQueryError(DBResultSet results, const char[] error, const char[] operationName)
{
    if (results != null) return true;

    // Check if the error is due to lost connection
    if (StrContains(error, "no connection to the server", false) == -1)
    {
        LogError("[GG2 MESSAGES] Failed to %s: %s", operationName, error);
        return false;
    }

    LogError("[GG2 MESSAGES] Lost connection to database: %s - attempting to reconnect", error);
    ReconnectDatabase();
    return false;
}

public void OnRotatingPlayerMessagesLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (!HandleQueryError(results, error, "load rotating player messages")) return;

    if (results.RowCount == 0) return;

    // Clear old messages
    for (int i = 0; i < MAX_MESSAGES; i++)
    {
        rotating_player_messages[i][0] = '\0';
    }

    int  offset = 0;
    char message[MAX_MESSAGE_LENGTH];
    while (results.FetchRow())
    {
        if (offset >= MAX_MESSAGES) break;    // Bounds check

        results.FetchString(0, message, sizeof(message));

        if (StrEqual(message, "")) continue;

        rotating_player_messages[offset] = message;
        offset++;
    }
}

public void OnRotatingAdminMessagesLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (!HandleQueryError(results, error, "load rotating admin messages"))
        return;

    if (results.RowCount == 0) return;

    // Clear old messages
    for (int i = 0; i < MAX_MESSAGES; i++)
    {
        rotating_admin_messages[i][0] = '\0';
    }

    int  offset = 0;
    char message[MAX_MESSAGE_LENGTH];
    while (results.FetchRow())
    {
        if (offset >= MAX_MESSAGES) break;    // Bounds check

        results.FetchString(0, message, sizeof(message));

        if (StrEqual(message, "")) continue;

        rotating_admin_messages[offset] = message;
        offset++;
    }
}

public void OnPlayerJoinMessagesLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (!HandleQueryError(results, error, "load player join messages"))
        return;

    if (results.RowCount == 0) return;

    // Clear old messages
    for (int i = 0; i < MAX_MESSAGES; i++)
    {
        player_join_messages[i][0] = '\0';
    }

    int  offset = 0;
    char message[MAX_MESSAGE_LENGTH];
    while (results.FetchRow())
    {
        if (offset >= MAX_MESSAGES) break;    // Bounds check

        results.FetchString(0, message, sizeof(message));

        if (StrEqual(message, "")) continue;

        player_join_messages[offset] = message;
        offset++;
    }
}

public void QueryRotatingPlayerMessages()
{
    if (g_Database == null) return;

    char query[512];
    Format(query, sizeof(query), "SELECT message FROM gg2_messages_rotating_player WHERE enabled ORDER BY id ASC LIMIT %d;", MAX_MESSAGES);
    g_Database.Query(OnRotatingPlayerMessagesLoaded, query);
}

public void QueryRotatingAdminMessages()
{
    if (g_Database == null) return;

    char query[512];
    Format(query, sizeof(query), "SELECT message FROM gg2_messages_rotating_admin WHERE enabled ORDER BY id ASC LIMIT %d;", MAX_MESSAGES);
    g_Database.Query(OnRotatingAdminMessagesLoaded, query);
}

public void QueryPlayerJoinMessages()
{
    if (g_Database == null) return;

    char query[512];
    Format(query, sizeof(query), "SELECT message FROM gg2_messages_join_player WHERE enabled ORDER BY id ASC LIMIT %d;", MAX_MESSAGES);
    g_Database.Query(OnPlayerJoinMessagesLoaded, query);
}

public Action Timer_LoadMessages(Handle timer)
{
    QueryRotatingPlayerMessages();
    QueryRotatingAdminMessages();
    QueryPlayerJoinMessages();
    return Plugin_Continue;
}

public Action Timer_RotatingPlayerMessages(Handle timer)
{
    if ((g_rotating_player_messages_offset == sizeof(rotating_player_messages)) || (StrEqual(rotating_player_messages[g_rotating_player_messages_offset], "\0")))
    {
        g_rotating_player_messages_offset = 0;
        QueryRotatingPlayerMessages();
        return Plugin_Continue;
    }

    if (is_translatable(rotating_player_messages[g_rotating_player_messages_offset]))
    {
        CPrintToChatAll("%t", rotating_player_messages[g_rotating_player_messages_offset]);
    }
    else {
        CPrintToChatAll(rotating_player_messages[g_rotating_player_messages_offset]);
    }

    g_rotating_player_messages_offset++;

    return Plugin_Continue;
}

public Action Timer_RotatingAdminMessages(Handle timer)
{
    if ((g_rotating_admin_messages_offset == sizeof(rotating_admin_messages)) || (StrEqual(rotating_admin_messages[g_rotating_admin_messages_offset], "\0")))
    {
        g_rotating_admin_messages_offset = 0;
        QueryRotatingAdminMessages();
        return Plugin_Continue;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidPlayer(client)) continue;

        int clientTeam = GetClientTeam(client);
        if (IsFakeClient(client) || clientTeam != 2) continue;

        AdminId clientAdmin = GetUserAdmin(client);
        if (clientAdmin == INVALID_ADMIN_ID) continue;

        CPrintToChat(client, rotating_admin_messages[g_rotating_admin_messages_offset]);
    }

    g_rotating_admin_messages_offset++;

    return Plugin_Continue;
}

// only show this once upon first spawn
public void Event_PlayerSpawnInit(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client)) return;

    int clientTeam = GetClientTeam(client);
    if (IsFakeClient(client) || clientTeam != 2) return;

    if (g_has_player_seen_first_connect_message[client]) return;

    char the_color[64];
    for (int i = 0; i < sizeof(player_join_messages); i++)
    {
        if (i % 2 == 0)
        {
            the_color = "{dodgerblue}";
        }
        else {
            the_color = "{yellow}";
        }

        if (StrEqual(player_join_messages[i], "")) break;

        if (is_translatable(player_join_messages[i]))
        {
            CPrintToChat(client, "%T", player_join_messages[i], client);
            continue;
        }

        CPrintToChat(client, "%s%s", the_color, player_join_messages[i]);
    }

    g_has_player_seen_first_connect_message[client] = true;
}

public void OnClientDisconnect_Post(int client)
{
    g_has_player_seen_first_connect_message[client] = false;
}

public bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}