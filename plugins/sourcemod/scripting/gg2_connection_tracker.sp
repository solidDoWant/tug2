#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <dbi>

#define PLUGIN_VERSION "1.0.0"

Database g_Database = null;

public Plugin myinfo =
{
    name        = "Connection Tracker",
    author      = "zachm",
    description = "Log Player IPs in case we need them for bannage later",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

public void OnPluginStart()
{
    Database.Connect(OnDatabaseConnected, "insurgency-stats");
}

public void OnClientAuthorized(int client)
{
    if (IsFakeClient(client)) return;
    if (g_Database == null)
    {
        LogMessage("Database unavailable, cannot log connection for client %N", client);
        return;
    }

    char ip_addr[64];
    if (!GetClientIP(client, ip_addr, sizeof(ip_addr))) return;

    char steam_id[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steam_id, sizeof(steam_id))) return;

    LogMessage("Logging connection: %N (%s) from %s", client, steam_id, ip_addr);

    LogConnection(steam_id, ip_addr);
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

public void LogConnection(const char[] steam_id, const char[] ip_addr)
{
    if (g_Database == null)
        return;

    char escapedSteamId[129];
    if (!g_Database.Escape(steam_id, escapedSteamId, sizeof(escapedSteamId)))
    {
        LogError("Failed to escape steam ID: %s", steam_id);
        return;
    }

    char escapedIpAddr[129];
    if (!g_Database.Escape(ip_addr, escapedIpAddr, sizeof(escapedIpAddr)))
    {
        LogError("Failed to escape IP address: %s", ip_addr);
        return;
    }

    int  now = GetTime();
    char query[512];
    Format(query, sizeof(query),
           "INSERT INTO connection_log (steamId, ip_address, connect_date) VALUES ('%s', '%s', %d) ON CONFLICT (steamId, ip_address) DO UPDATE SET connect_date = EXCLUDED.connect_date",
           escapedSteamId, escapedIpAddr, now);

    g_Database.Query(OnConnectionLogged, query);
}

public void OnConnectionLogged(Database db, DBResultSet results, const char[] error, any data)
{
    HandleQueryError(results, error, "log connection");
}
