#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

Database  g_Database = null;
// Any player in this list will have reconnected at least one point in the past so they should have smoke particles cached
StringMap playerList;
ConVar    gg2_always_retry;
bool      g_bIsRetrying[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "[GG2 ForceRetry] Force Retry",
    author      = "Bot Chris // zachm",
    description = "To precache smoke/etc for players not having the particles already. Includes !resetsmoke command.",
    version     = "1.1.0",
    url         = ""
};

public void OnPluginStart()
{
    Database.Connect(OnDatabaseConnected, "insurgency-stats");

    playerList = new StringMap();

    HookEvent("player_disconnect", Event_PlayerDisconnect_Pre, EventHookMode_Pre);

    gg2_always_retry = CreateConVar("gg2_always_retry", "0", "should we always force reconnect");

    AutoExecConfig(true, "gg2_forceretry");
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (!StrEqual(sArgs, "!resetsmoke", false)) return Plugin_Continue;

    ResetSmokeStatus(client);
    return Plugin_Handled;
}

void ResetSmokeStatus(int client)
{
    if (!IsValidPlayer(client)) return;
    if (IsFakeClient(client)) return;

    db_reset_player_has_smoke(client);
}

public void OnMapStart()
{
    if (playerList == null) return;

    playerList.Clear();
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidPlayer(client) || IsFakeClient(client)) return;

    g_bIsRetrying[client] = false;
    char steamId[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId))) return;

    if (StrContains(steamId, "STEAM_", false) != 0) return;

    bool hasSmoke;
    if (playerList.GetValue(steamId, hasSmoke))
    {
        if (hasSmoke) return;

        // In this case, the player must have reconnected (otherwise, they wouldn't be in the map).
        // This means they now have smoke particles cached.
        db_update_player_has_smoke(client);
        return;
    }

    playerList.SetValue(steamId, false, true);
    db_check_player_has_smoke(client);
}

public Action Timer_ForceRetry(Handle timer, int client)
{
    if (!IsValidPlayer(client)) return Plugin_Continue;

    LogMessage("[INS GG] Force retry for %N", client);
    g_bIsRetrying[client] = true;
    ClientCommand(client, "retry");
    return Plugin_Continue;
}

public Action Event_PlayerDisconnect_Pre(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Continue;

    // Store retry state before resetting
    bool wasRetrying      = g_bIsRetrying[client];
    g_bIsRetrying[client] = false;

    // If player was being forced to retry, keep them in playerList
    if (wasRetrying) return Plugin_Continue;

    // Normal disconnect - remove from tracking
    char steamId[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId))) return Plugin_Continue;

    if (StrContains(steamId, "STEAM_", false) == 0)
    {
        playerList.Remove(steamId);
    }

    return Plugin_Continue;
}

public void OnPluginEnd()
{
    if (playerList != null) delete playerList;
}

bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

// Helper function to handle database query errors
void HandleQueryError(DBResultSet results, const char[] error, const char[] operationName)
{
    if (results != null) return;

    // Check if the error is due to lost connection
    if (StrContains(error, "no connection to the server", false) != -1)
    {
        LogError("[INS GG ForceRetry] Lost connection to database: %s - attempting to reconnect", error);
        ReconnectDatabase();
        return;
    }

    LogError("[INS GG ForceRetry] Failed to %s: %s", operationName, error);
}

// Helper function to execute a player query with automatic escaping
// First format parameter (%s) will be the escaped SteamID64, additional params come from varargs
void ExecutePlayerQuery(SQLQueryCallback callback, const char[] operationName, int client, const char[] queryFormat, any...)
{
    if (g_Database == null)
    {
        LogError("[INS GG ForceRetry] Database unavailable for %s", operationName);
        return;
    }

    if (!IsClientInGame(client) || IsFakeClient(client))
        return;

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        LogError("[INS GG ForceRetry] Failed to get SteamID for %s", operationName);
        return;
    }

    char escapedSteamId[128];
    if (!g_Database.Escape(steamId, escapedSteamId, sizeof(escapedSteamId)))
    {
        LogError("[INS GG ForceRetry] Failed to escape SteamID for %s: %s", operationName, steamId);
        return;
    }

    // Format the query: first %s is escaped SteamID, rest comes from varargs
    char query[512];
    char formattedQuery[512];

    // First, format any varargs into a temporary string
    VFormat(formattedQuery, sizeof(formattedQuery), queryFormat, 5);

    // Then format the escaped SteamID as the first parameter
    Format(query, sizeof(query), formattedQuery, escapedSteamId);

    g_Database.Query(callback, query, client);
}

// actions to track whether player has smoke particles downloaded, reconnect them if they don't //
public void db_check_player_has_smoke(int client)
{
    ExecutePlayerQuery(OnPlayerSmokeCacheChecked, "check player smoke cache", client,
                       "SELECT has_smoke FROM players_smoke_cache WHERE steam_id = '%s' LIMIT 1");
}

public void db_update_player_has_smoke(int client)
{
    ExecutePlayerQuery(OnPlayerSmokeCacheUpdated, "update player smoke cache", client,
                       "INSERT INTO players_smoke_cache (steam_id, has_smoke) VALUES ('%s', 1) ON CONFLICT (steam_id) DO UPDATE SET has_smoke = 1");
}

public void db_reset_player_has_smoke(int client)
{
    ExecutePlayerQuery(OnPlayerSmokeCacheReset, "reset player smoke cache", client,
                       "INSERT INTO players_smoke_cache (steam_id, has_smoke) VALUES ('%s', 0) ON CONFLICT (steam_id) DO UPDATE SET has_smoke = 0");
}

public void OnPlayerSmokeCacheUpdated(Database db, DBResultSet results, const char[] error, any client)
{
    HandleQueryError(results, error, "update player smoke cache");
    if (results == null) return;

    // Update the playerList map to reflect the change
    if (!IsClientInGame(client)) return;

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId))) return;

    playerList.SetValue(steamId, true, true);
}

public void OnPlayerSmokeCacheReset(Database db, DBResultSet results, const char[] error, any client)
{
    HandleQueryError(results, error, "reset player smoke cache");
    if (results == null) return;

    // Update the playerList map to reflect the change
    if (!IsClientInGame(client)) return;

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId))) return;

    playerList.SetValue(steamId, false, true);

    PrintToChat(client, "Smoke status reset, reconnect to the server to force cache");
}

public void OnPlayerSmokeCacheChecked(Database db, DBResultSet results, const char[] error, any client)
{
    // Handle always_retry ConVar
    if (gg2_always_retry.IntValue == 1)
    {
        CreateTimer(0.2, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    HandleQueryError(results, error, "check player smoke cache");
    if (results == null) return;

    if (!IsClientInGame(client))
        return;

    // If no rows, player not in cache - trigger retry
    if (results.RowCount == 0)
    {
        CreateTimer(0.2, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    // Check the has_smoke value
    if (!results.FetchRow()) return;

    int has_smoke = results.FetchInt(0);
    if (has_smoke == 0)
    {
        CreateTimer(0.2, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    // Player has smoke cached - update the map
    char steamId[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId))) return;

    playerList.SetValue(steamId, true, true);
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[INS GG ForceRetry] Failed to connect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("[INS GG ForceRetry] Connected to database");
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    LogMessage("[INS GG ForceRetry] Attempting to reconnect to database...");
    g_Database = null;
    Database.Connect(OnDatabaseReconnected, "insurgency-stats");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[INS GG ForceRetry] Failed to reconnect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("[INS GG ForceRetry] Successfully reconnected to database");
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database != null) return Plugin_Stop;

    ReconnectDatabase();

    return Plugin_Stop;
}