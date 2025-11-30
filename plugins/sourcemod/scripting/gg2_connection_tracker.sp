#include <sourcemod>
#include <sdktools>
#include <dbi>

#pragma newdecls required

ConVar g_server_id;
Database g_Database = null;

public Plugin myinfo = {
	name = "[GG2 Connection Tracker]",
	author = "zachm",
	description = "Log Player IPs in case we need them for bannage later",
	version = "0.0.1",
	url = "http://sourcemod.net/"
};


public void OnPluginStart() {
    Database.Connect(T_Connect, "insurgency_stats");
}

public void OnClientAuthorized(int client) {
    if (IsFakeClient(client)) {
        return;
    }
    char ip_addr[64];
    if (GetClientIP(client, ip_addr, sizeof(ip_addr))) {
        LogMessage("[GG2 CTracker] Logged new connect: (server_id: %i) %N --> %s", g_server_id.IntValue, client, ip_addr);
        int now = GetTime();
        char steam_id[64];
        GetClientAuthId(client, AuthId_SteamID64, steam_id, sizeof(steam_id));
        char query[512];
        Format(query, sizeof(query), "INSERT INTO connection_log (server_id, steamId, ip_address, connect_date) VALUES ('%i', '%s', '%s', %i);", g_server_id.IntValue, steam_id, ip_addr, now);
        SQL_TQuery(g_Database, do_nothing, query);
    }
    
}

public void T_Connect(Database db, const char[] error, any data) {
    if(db == null){
        LogError("[GG2 CTracker] T_Connect returned invalid Database Handle");
        SetFailState("FAILED TO CONNECT TO M DB, BAILING");
        return;
    }
    g_Database = db;
    SQL_SetCharset(g_Database, "utf8mb4");
    return;
} 

public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
    if (strlen(error) != 0) {
        LogMessage("[GG2 CTracker] error: %s", error);
    }
    return;
}

public void OnAllPluginsLoaded() {
	g_server_id = FindConVar("gg_stats_server_id");
}
