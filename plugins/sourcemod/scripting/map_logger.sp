#pragma newdecls required
#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.1.0"

Database g_Database = null;
char     g_sMapName[128];
bool     g_bMapStartRecorded = false;

public Plugin myinfo =
{
    name        = "Map Change Logger",
    author      = "sdw",
    description = "Logs map changes and tracks playtime",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

public void OnPluginStart()
{
    Database.Connect(OnDatabaseConnected, "insurgency-stats");
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Failed to connect to database: %s", error);
        SetFailState("Database connection failed");
        return;
    }

    g_Database = db;
    LogMessage("Successfully connected to database");
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    LogMessage("Attempting to reconnect to database...");
    g_Database = null;
    Database.Connect(OnDatabaseReconnected, "insurgency-stats");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Failed to reconnect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("Successfully reconnected to database");
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database == null)
        ReconnectDatabase();

    return Plugin_Stop;
}

public void OnMapStart()
{
    GetCurrentMap(g_sMapName, sizeof(g_sMapName));
    g_bMapStartRecorded = false;

    if (g_Database == null)
    {
        LogMessage("Database unavailable at map start, attempting reconnection...");
        ReconnectDatabase();
        return;    // Functions will be called after reconnection succeeds
    }

    UpdateMapLastStart(g_sMapName);
}

public void OnMapEnd()
{
    char currentMap[64], nextMap[64];
    GetCurrentMap(currentMap, sizeof(currentMap));
    GetNextMap(nextMap, sizeof(nextMap));
    PrintToServer("Map changing from %s to %s", currentMap, nextMap);
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (g_Database == null || !g_bMapStartRecorded) return Plugin_Continue;

    UpdateMapTimePlayed(g_sMapName);
    return Plugin_Continue;
}

// Helper function to handle database query errors
void HandleQueryError(DBResultSet results, const char[] error, const char[] operationName)
{
    if (results != null) return;

    // Check if the error is due to lost connection
    if (StrContains(error, "no connection to the server", false) != -1)
    {
        LogError("Lost connection to database: %s - attempting to reconnect", error);
        ReconnectDatabase();
        return;
    }

    LogError("Failed to %s: %s", operationName, error);
}

public void UpdateMapLastStart(const char[] map_name)
{
    if (g_Database == null)
        return;

    char query[512];
    g_Database.Format(query, sizeof(query),
                      "INSERT INTO maps (map_name, play_time, last_start) VALUES ('%s', '0 seconds'::INTERVAL, CURRENT_TIMESTAMP) ON CONFLICT (map_name) DO UPDATE SET last_start = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP",
                      map_name);
    g_Database.Query(OnMapLastStartUpdated, query);
}

public void OnMapLastStartUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "update map last start");

    g_bMapStartRecorded = (results != null);
}

public void UpdateMapTimePlayed(const char[] map_name)
{
    if (g_Database == null)
        return;

    char query[512];
    g_Database.Format(query, sizeof(query),
                      "INSERT INTO maps (map_name, play_time, last_start) VALUES ('%s', '0 seconds'::INTERVAL, CURRENT_TIMESTAMP) ON CONFLICT (map_name) DO UPDATE SET play_time = maps.play_time + (CURRENT_TIMESTAMP - maps.last_start), last_start = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP",
                      map_name);
    g_Database.Query(OnMapTimeUpdated, query);
}

public void OnMapTimeUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "update map play time");
}
