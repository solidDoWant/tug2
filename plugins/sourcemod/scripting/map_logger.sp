#pragma newdecls required
#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.1.0"

Database g_Database = null;
char     g_sMapName[128];
int      g_MapTime;

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
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
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

    // Ensure the map exists in the database
    if (g_sMapName[0] == '\0') return;

    EnsureMapExists(g_sMapName);
    UpdateMapLastStart(g_sMapName, g_MapTime);
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

    // Re-initialize current map tracking
    if (g_sMapName[0] == '\0') return;

    EnsureMapExists(g_sMapName);
    UpdateMapLastStart(g_sMapName, g_MapTime);
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database == null)
        ReconnectDatabase();

    return Plugin_Stop;
}

public void OnMapStart()
{
    g_MapTime = GetTime();
    GetCurrentMap(g_sMapName, sizeof(g_sMapName));

    if (g_Database == null)
    {
        LogMessage("Database unavailable at map start, attempting reconnection...");
        ReconnectDatabase();
        return;    // Functions will be called after reconnection succeeds
    }

    EnsureMapExists(g_sMapName);
    UpdateMapLastStart(g_sMapName, g_MapTime);
}

public void OnMapEnd()
{
    char currentMap[64], nextMap[64];
    GetCurrentMap(currentMap, sizeof(currentMap));
    GetNextMap(nextMap, sizeof(nextMap));
    PrintToServer("Map changing from %s to %s", currentMap, nextMap);
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_MapTime = GetTime();
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    int iTimer = GetTime() - g_MapTime;
    if (iTimer <= 0 || g_Database == null) return Plugin_Continue;

    UpdateMapTimePlayed(g_sMapName, iTimer);
    LogMessage("[Map Logger] Added %d seconds to %s", iTimer, g_sMapName);
    g_MapTime = GetTime();
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

// Helper function to execute a map query with automatic escaping
// First format parameter (%s) will be the escaped map name, additional params come from varargs
void ExecuteMapQuery(SQLQueryCallback callback, const char[] operationName, const char[] mapName, const char[] queryFormat, any...)
{
    if (g_Database == null)
        return;

    char escapedMapName[257];
    if (!g_Database.Escape(mapName, escapedMapName, sizeof(escapedMapName)))
    {
        LogError("Failed to escape map name for %s: %s", operationName, mapName);
        return;
    }

    // Format the query: first %s is escaped map name, rest comes from varargs
    char query[512];
    char formattedQuery[512];

    // First, format any varargs into a temporary string
    VFormat(formattedQuery, sizeof(formattedQuery), queryFormat, 5);

    // Then format the escaped map name as the first parameter
    Format(query, sizeof(query), formattedQuery, escapedMapName);

    g_Database.Query(callback, query);
}

public void EnsureMapExists(const char[] map_name)
{
    ExecuteMapQuery(OnMapEnsured, "ensure map exists", map_name,
                    "INSERT INTO maps (map_name, play_time, last_start) VALUES ('%s', 0, 0) ON CONFLICT (map_name) DO NOTHING");
}

public void OnMapEnsured(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "ensure map exists");
}

public void UpdateMapLastStart(const char[] map_name, int timestamp)
{
    ExecuteMapQuery(OnMapLastStartUpdated, "update map last start", map_name,
                    "UPDATE maps SET last_start = %d, updated_at = CURRENT_TIMESTAMP WHERE map_name = '%s'",
                    timestamp);
}

public void OnMapLastStartUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "update map last start");
}

public void UpdateMapTimePlayed(const char[] map_name, int timer)
{
    if (g_Database == null)
        return;

    char query[512];
    char escapedMapName[257];
    if (!g_Database.Escape(map_name, escapedMapName, sizeof(escapedMapName)))
    {
        LogError("Failed to escape map name: %s", map_name);
        return;
    }

    Format(query, sizeof(query),
           "UPDATE maps SET play_time = play_time + %d, updated_at = CURRENT_TIMESTAMP WHERE map_name = '%s'",
           timer, escapedMapName);
    g_Database.Query(OnMapTimeUpdated, query);
}

public void OnMapTimeUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "update map play time");
}
