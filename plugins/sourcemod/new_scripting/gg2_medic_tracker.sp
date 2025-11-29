#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <morecolors>
#include <stats>

#pragma newdecls required


public Plugin myinfo =
{
  name = "[GG2 Medic Tracker]",
  author = "zachm",
  description = "Don't let shit ass medics be medics",
  version = "0.1",
  url = "https://tug.gg"
};


Database g_Database = null;
char g_client_ids[MAXPLAYERS+1][64];
char g_client_last_classstring[MAXPLAYERS+1][64]
int g_client_medic_class_tracker[MAXPLAYERS+1] = {0, ...};

int g_round_medic_revives[MAXPLAYERS+1] = {0, ...};
int g_round_medic_heals[MAXPLAYERS+1] = {0, ...};
int g_current_revivable = 0;
int g_current_fatal = 0;
char medic_template[32] = "template_combat_medic";

ConVar g_server_id;

public void T_Connect(Database db, const char[] error, any data) {
    if(db == null) {
        LogError("[GG2 Medic Tracker] T_Connect returned invalid Database Handle");
        return;
    }
    g_Database = db;
    LogMessage("[GG2 Medic Tracker] Connected to Database.");
    return;
} 

public void OnAllPluginsLoaded() {
    g_server_id = FindConVar("gg_stats_server_id");
}

public void OnPluginStart() {
    Database.Connect(T_Connect, "insurgency_stats");
    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
    RegAdminCmd("medic_stats2", get_current_medic_stats2, ADMFLAG_BAN, "Show stats for the current medics (medic class)");
}

public void OnMapStart() {
    clear_last_classstrings();
    clear_medic_tracker();
    CreateTimer(10.0, getBannedMedics_Timer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(5.0, medicClassTracker_Timer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action get_current_medic_stats2(int caller_client, int args) {
    bool any_medics = false;
    char message[128];
    char status[8];
    for (int client = 1; client <= MaxClients; client++) {
        if (is_medic(client)) {
            any_medics = true;
            if (IsPlayerAlive(client)) {
                status = "alive";
            } else {
                status = "dead";
            }
            
            int minutes = g_client_medic_class_tracker[client] % 3600 / 60;
            int seconds = g_client_medic_class_tracker[client] % 60;
            Format(message, sizeof(message),"%N (%s) heals: %i // revives: %i // medic_time: %02d:%02d", client, status, g_round_medic_heals[client], g_round_medic_revives[client],minutes,seconds);
            ReplyToCommand(caller_client, message);
        }
    }
    if (!any_medics) {
        ReplyToCommand(caller_client, "0 Medics in game right now, please try your call later");
    } else {
        ReplyToCommand(caller_client, "current revivable: %i // current fatal: %i (right now)", g_current_revivable, g_current_fatal);
    }
    return Plugin_Continue;
}

public bool is_medic(int client) {
    return ((StrEqual(g_client_last_classstring[client], medic_template)) || (StrContains(g_client_last_classstring[client], "medic") != -1));
}

public Action Dead_Count(int revivable, int fatal) {
    g_current_revivable = revivable;
    g_current_fatal = fatal;
    return Plugin_Continue;
}

public Action Medic_Revived(int reviver_client, int saved_client) {
    g_round_medic_revives[reviver_client]++;
    return Plugin_Continue;

}

public Action Medic_Healed(int healer_client, int saved_client) {
    g_round_medic_heals[healer_client]++;
    return Plugin_Continue;

}

public void OnMapEnd() {
    for (int client = 1; client < MaxClients; client++) {
        if (!IsClientConnected(client)) {
            continue;
        }
        if (g_client_medic_class_tracker[client] != 0) {
            LogMessage("[GG2 Medic Tracker] %N spent %i seconds as a MEDIC", client, g_client_medic_class_tracker[client]);
        }
    }
}

public void clear_medic_tracker() {
    for (int client = 1; client < MaxClients; client++) {
        g_client_medic_class_tracker[client] = 0;
    }
}


public void clear_last_classstrings() {
    for (int client = 1; client < MaxClients; client++) {
        g_client_last_classstring[client] = "";
    }
}

public void OnClientPostAdminCheck(int client) {
    GetClientAuthId(client, AuthId_SteamID64, g_client_ids[client], sizeof(g_client_ids[]));
}

public void check_if_medic_time_updated(Handle owner, Handle results, const char[] error, any client) {
    if (results == INVALID_HANDLE) {
        LogError("[GG2 Medic Tracker] update medic time failed: %s", error);
        return;
    }
    if (SQL_GetAffectedRows(results) == 0) {
        if (IsClientConnected(client)) {
            LogError("[GG2 Medic Tracker] 0 affected rows for client %N", client);
        } else {
            LogMessage("[GG2 Medic Tracker]  0 affected rows for client (disconnected)");
        }
    }
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    for (int client = 1; client < MaxClients; client++) {
        if (!IsClientConnected(client)) {
            continue;
        }
        if (IsFakeClient(client)) {
            continue;
        }
        if (!shouldUpdateMedicTimeDB(client)) {
            continue;
        }
        //if (StrEqual(g_client_last_classstring[client], medic_template)) {
        if (is_medic(client)) {
            char query[512];
            Format(query, sizeof(query), "UPDATE medics SET medic_time = medic_time + %i WHERE steamId = '%s' AND server_id = '%i' LIMIT 1", g_client_medic_class_tracker[client], g_client_ids[client], g_server_id.IntValue);
            LogMessage("[GG2 Medic Tracker] round_end update medic_time %N + %i", client, g_client_medic_class_tracker[client]);
            SQL_TQuery(g_Database, check_if_medic_time_updated, query, client);
            update_medic_time(client, g_client_medic_class_tracker[client]);

            g_client_medic_class_tracker[client] = 0;
        }
        g_round_medic_revives[client] = 0;
        g_round_medic_heals[client] = 0;
        g_current_revivable = 0;
        g_current_fatal = 0;
    }
    return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client)) {
        return Plugin_Continue;
    }
    if (!shouldUpdateMedicTimeDB(client)) {
        return Plugin_Continue;
    }
    //if (StrEqual(g_client_last_classstring[client], medic_template)) {
    if (is_medic(client)) {
        char query[512];
        Format(query, sizeof(query), "UPDATE medics SET medic_time = medic_time + %i WHERE steamId = '%s' AND server_id = '%i' LIMIT 1", g_client_medic_class_tracker[client], g_client_ids[client], g_server_id.IntValue);
        LogMessage("[GG2 Medic Tracker] player_disconnect update medic_time %N + %i", client, g_client_medic_class_tracker[client]);
        SQL_TQuery(g_Database, check_if_medic_time_updated, query, client);
        update_medic_time(client, g_client_medic_class_tracker[client]);
    }
    g_client_ids[client] = "";
    g_client_last_classstring[client] = "";
    g_round_medic_revives[client] = 0;
    g_round_medic_heals[client] = 0;
    g_client_medic_class_tracker[client] = 0;
    return Plugin_Continue;
}

public Action Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsFakeClient(client)) {
        return Plugin_Continue;
    }
    char class_template[64];
    event.GetString("class_template", class_template, sizeof(class_template));

    // they're changing from medic to something else //
    //if (StrEqual(g_client_last_classstring[client], medic_template)) {
    if (is_medic(client)) {
        if (shouldUpdateMedicTimeDB(client)) {
            char query[512];
            Format(query, sizeof(query), "UPDATE medics SET medic_time = medic_time + %i WHERE steamId = '%s' AND server_id = '%i' LIMIT 1", g_client_medic_class_tracker[client], g_client_ids[client], g_server_id.IntValue);
            LogMessage("[GG2 Medic Tracker] pick_squad (change from medic) update medic_time %N + %i", client, g_client_medic_class_tracker[client]);
            SQL_TQuery(g_Database, do_nothing, query);
            update_medic_time(client, g_client_medic_class_tracker[client])
        }
        g_client_last_classstring[client] = class_template;
        return Plugin_Continue;
    }
    g_client_last_classstring[client] = class_template;
    
    //if (StrEqual(class_template, medic_template)) {
    char query[256];
    Format(query, sizeof(query), "SELECT id FROM medics WHERE steamId = '%s' AND server_id = '%i' LIMIT 1", g_client_ids[client], g_server_id.IntValue);
    SQL_TQuery(g_Database, parse_medic_exists, query, client);
    //}
    return Plugin_Continue;
}

public void parse_medic_exists(Handle owner, Handle results, const char[] error, any client) {
    int rows = SQL_GetRowCount(results);
    if (rows == 0) {
        char query[512];
        Format(query, sizeof(query), "INSERT INTO medics (steamId, banned, medic_time, server_id) VALUES ('%s','0','0','%i')", g_client_ids[client], g_server_id.IntValue);
        LogMessage("[GG2 Medic Tracker] found no medic so creating %N", client);
        SQL_TQuery(g_Database, do_nothing, query);
    }
}
public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
    if (strlen(error) != 0) {
        LogMessage("[GG2 Medic Tracker] error: %s", error);
    }
    return;
}

public bool shouldUpdateMedicTimeDB(int client) {
    if (g_client_medic_class_tracker[client] == 0) {
        return false;
    }
    return true;
}

bool IsPlayingSolo() {
    int count = 0;
    for (int client = 1; client < MaxClients; client++) {
        if (IsClientConnected(client) && !IsFakeClient(client)) count++;
        if (count > 1) return false;
    }
    return true;
}



public Action medicClassTracker_Timer(Handle timer) {
    if (GetGameState() != 4) {
        return Plugin_Continue;
    }
    if (IsPlayingSolo()) {
        return Plugin_Continue;
    }
    for (int client = 1; client < MaxClients; client++) {
        if (!IsClientConnected(client)) {
            continue;
        }
        if (IsFakeClient(client)) {
            continue;
        }
        //if (StrEqual(g_client_last_classstring[client], medic_template)) {
        if (is_medic(client)) {
            g_client_medic_class_tracker[client] = g_client_medic_class_tracker[client] + 5;
        }
    }
    return Plugin_Continue;
}
public Action getBannedMedics_Timer(Handle timer) {
    char query[128] = "SELECT steamId FROM medics WHERE banned = '1' ORDER BY id ASC";
    SQL_TQuery(g_Database, parse_banned_medics_query, query);
    return Plugin_Continue;
}

public void parse_banned_medics_query(Handle owner, Handle results, const char[] error, any UNUSED) {
    int rows = SQL_GetRowCount(results);
    if (rows == 0) {
        //LogMessage("[GG2 Medic Tracker] Found no banned medics, bailing");
        return;
    }

    char banned_id[64];
    while (SQL_FetchRow(results)) {
        SQL_FetchString(results, 0, banned_id, sizeof(banned_id));
        //LogMessage("got banned id: %s",banned_id);
        for (int client = 1; client < MaxClients; client++) {
            if (!IsClientConnected(client)) {
                g_client_last_classstring[client] = "";
                continue;
            }
            if (StrEqual(banned_id, g_client_ids[client])) {
                //if (StrEqual(g_client_last_classstring[client], medic_template)) {
                if (is_medic(client)) {
                    LogMessage("this player (%N) IS BANNED from being a medic", client);
                }
            }
        }
    }
}

public bool IsValidPlayer(int client) {
    return (0 < client <= MaxClients) && IsClientInGame(client);
}
int GetGameState() {
    return GameRules_GetProp("m_iGameState");
}
