#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

Database g_Database = null;
StringMap playerList;
ConVar gg2_always_retry;
bool g_bIsRetrying[MAXPLAYERS+1];


public Plugin myinfo = {
	name = "[GG2 ForceRetry] Force Retry",
	author = "Bot Chris // zachm",
	description = "To precache smoke/etc for players not having the particles already",
	version = "1.0.0",
	url = ""
}


public void OnPluginStart() 
{
    Database.Connect(T_Connect, "insurgency_stats");
    playerList = new StringMap();
    HookEvent("round_start", Event_RoundStart);
    HookEvent("player_disconnect", Event_PlayerDisconnect_Pre, EventHookMode_Pre);
    gg2_always_retry = CreateConVar("gg2_always_retry", "0", "should we always force reconnect");
    AutoExecConfig(true, "gg2_forceretry");
}

public void OnMapStart()
{
	//if (playerList != INVALID_HANDLE) playerList.Clear();
}

public void OnClientPostAdminCheck(int client)
{
	if (!IsValidPlayer(client) || IsFakeClient(client)) return;

	g_bIsRetrying[client] = false;
	char steamId[32];
	int temp;
	GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
	if (StrContains(steamId, "STEAM_", false) != -1 && !playerList.GetValue(steamId, temp))
	{
		db_check_player_has_smoke(client);
		playerList.SetValue(steamId, temp, true);
		//CreateTimer(0.2, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_ForceRetry(Handle timer, int client)
{
	if (IsValidPlayer(client))
	{
		LogMessage("[INS GG] Force retry for %N", client);
		g_bIsRetrying[client] = true;
		ClientCommand(client, "retry");
        
	}
	return Plugin_Continue;
}

public Action Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
	char steamId[32];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i)) continue;
		GetClientAuthId(i, AuthId_Steam2, steamId, sizeof(steamId));
		playerList.SetValue(steamId, 1, true);
	}
	return Plugin_Continue;
}

public Action Event_PlayerDisconnect_Pre(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IsValidPlayer(client) || IsFakeClient(client) || g_bIsRetrying[client]) return Plugin_Continue;

	char steamId[32];
	GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
	if (StrContains(steamId, "STEAM_", false) != -1)
	{
		//RemoveFromTrie(playerList, steamId)
		playerList.Remove(steamId);
	}
	return Plugin_Continue;
}

public void OnMapEnd() {
	//if (playerList != INVALID_HANDLE) playerList.Clear();
}

public void OnPluginEnd() {
	if (playerList != INVALID_HANDLE) CloseHandle(playerList);
}

bool IsValidPlayer(int client) {
	return (0 < client <= MaxClients) && IsClientInGame(client);
}


// actions to track whether player has smoke particles downloaded, reconnect them if they don't //
public void db_check_player_has_smoke(int client) {
    //int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsFakeClient(client)) {
        return;// Plugin_Continue;
    }
    char steamId[64];
    char query[512];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));
    Format(query, sizeof(query), "SELECT has_smoke FROM redux_players WHERE steam_id = '%s' LIMIT 1", steamId);
    SQL_TQuery(g_Database, check_if_player_has_smoke, query, client);
    return;// Plugin_Continue;
}

public void check_if_player_has_smoke(Handle owner, Handle results, const char[] error, any client) {
    if (gg2_always_retry.IntValue == 1) {
        CreateTimer(0.2, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
        delete results;
        return;
    }
    if(results == INVALID_HANDLE) {
        LogToFile("wtf.log", "check if has_smoke results query failed");
        delete results;
        return;
    }
    if (!IsClientInGame(client)) {
        delete results;
        return;
    }
    int rows = SQL_GetRowCount(results);
    if (rows == 0) {
        CreateTimer(0.2, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
        delete results;
        return;
    }
    while(SQL_FetchRow(results)) {
        int has_smoke = SQL_FetchInt(results, 0);
        if (has_smoke == 0) {
            //("[INS GG] force retry would reconnect %N since they do not have smoke particles", client);
            //ReconnectClient(client);
            CreateTimer(0.2, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
            
            delete results;
            return;
        }
        LogMessage("[INS GG] force retry %N has smoke particles, moving along", client);
    }
    delete results;
    //ClientCommand(client, "retry");
    return;
}




public void T_Connect(Database db, const char[] error, any data) {
    if(db == null) {
        LogError("[INS GG] force retry T_Connect returned invalid Database Handle");
        return;
    }
    g_Database = db;
    LogMessage("[INS GG] force retry Connected to Database.");
    return;
} 

public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
    if (strlen(error) != 0) {
        LogMessage("[INS GG] force retry error: %s", error);
    }
    return;
}