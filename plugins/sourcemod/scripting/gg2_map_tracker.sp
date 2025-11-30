#pragma newdecls required
#include <sourcemod>
#include <sdktools>

Database g_Database = null;
bool g_db_up = false;

public Plugin myinfo =  {
    name = "[GG2 Map Tracker]",
    author = "zachm and Bot Chris",
    description = "Log time on maps",
    version = "0.0.2",
    url = "https://tug.gg"
}

char g_sMapName[128];
int g_MapTime;

public void T_Connect(Database db, const char[] error, any data) {
    if(db == null) {
        LogError("[GG2 Map Tracker] T_Connect returned invalid Database Handle");
        return;
    }
    g_Database = db;
    SQL_SetCharset(g_Database, "utf8mb4");
    LogMessage("[GG2 Map Tracker] Connected to Database.");
    g_db_up = true;
    return;
} 

public void OnPluginStart() {
	Database.Connect(T_Connect, "insurgency_stats");
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
}

public void OnMapStart() {
	g_MapTime = GetTime();
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	if (g_db_up) {
		update_map_last_start(g_sMapName, g_MapTime);
	}
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
	g_MapTime = GetTime();
	return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
	int iTimer = GetTime()-g_MapTime;
	if (iTimer > 0)
	{
		update_map_time_played(g_sMapName, iTimer);
		LogMessage("[GG2 Map Tracker] add %dsec to %s", iTimer, g_sMapName);
		g_MapTime = GetTime();
	}
	return Plugin_Continue;
}

public void update_map_last_start(char[] map_name, int timestamp) {
	char query[512];
	Format(query, sizeof(query), "UPDATE maps SET last_start = %i WHERE map_name = '%s' LIMIT 1", timestamp, map_name);
	SQL_TQuery(g_Database, do_nothing, query);
}

public void update_map_time_played(char[] map_name, int timer) {
	char query[512];
	Format(query, sizeof(query), "UPDATE maps SET play_time = play_time + %i WHERE map_name = '%s' LIMIT 1", timer, map_name);
	SQL_TQuery(g_Database, do_nothing, query);
}

public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
	if (strlen(error) != 0) {
		LogMessage("[GG2 Map Tracker] error: %s", error);
	}
	return;
}
