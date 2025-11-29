#include <sourcemod>
#include <sdktools>
#include <dbi>
#pragma newdecls required

Database g_Database = null;

public Plugin myinfo = {
    name = "[GG2 SmokeReset] Reset Smoke",
    author = "zachm",
    description = "Sets player has_smoke value in db to 0",
    version = "0.0.1",
}

public void OnPluginStart() {
    Database.Connect(T_Connect, "insurgency_stats");
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs) {
    if (StrContains(sArgs[0], "!reset_smoke", false) == 0) {
        reset_smoke_status(client);
        return Plugin_Handled;
    }
    return Plugin_Continue;
}


public void T_Connect(Database db, const char[] error, any data) {
    if(db == null) {
        LogError("[GG Reset Smoke] T_Connect returned invalid Database Handle");
        return;
    }
    g_Database = db;
    LogMessage("[GG Reset Smoke] Connected to Database.");
    return;
} 

public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
    if (strlen(error) != 0) {
        LogMessage("[GG Reset Smoke] error: %s", error);
    }
    return;
}

public void reset_smoke_status(int client) {
    char steamId[64];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));
    char query[512];
    Format(query, sizeof(query), "UPDATE players SET has_smoke = 0 WHERE steamId = '%s'",steamId);
    SQL_TQuery(g_Database, do_nothing, query);
    LogMessage("[GG Reset Smoke] Set has_smoke to 0 for %N", client);
    PrintToChat(client, "Smoke status reset, reconnect to the server to force cache");
}


