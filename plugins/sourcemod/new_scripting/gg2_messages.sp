#include <sourcemod>
#include <sdkhooks>
//#include <sdktools>
#include <smlib>
#include <morecolors>
#include <dbi>
#include <TheaterItemsAPI>

#pragma newdecls required

#define healthkit_theater_item "weapon_healthkit"
#define defib_theater_item "weapon_defib"

Database g_Database = null;

int g_rotating_player_messages_offset = 0;
int g_rotating_admin_messages_offset = 0;
char rotating_player_messages[64][256];
char rotating_admin_messages[64][256];
char player_join_messages[64][256];
bool g_players[MAXPLAYERS+1];

int healthkit_theater_id = 0;
int defib_theater_id = 0;

int g_iNCP = 0;
int g_iACP = 0;
bool g_last_cap_not_cache;

char last_control_point_message[] = "{dodgerblue}LAST CAP:{default} {yellow}Push slowly or they will spawn up your ass!{default}";
char in_counter_attack_cache_message[] = "{dodgerblue}COUNTERATTACK:{default} {yellow}Last cap was a cache, you need only to survive the counter!";
char in_counter_attack_hold_message[] = "{dodgerblue}COUNTERATTACK:{default} {yellow}DEFEND THE CAP, DO NOT PUSH!";

/*
char translatables[][] = {
    "dontbeadick",
    "justholdit",
    "justhoditdefib",
    "findresupply",
    "dragbodies",
    "getsmoke",
    "catchfire",
    "callmedic"
}
*/

native int Ins_ObjectiveResource_GetProp(const char[] prop, int size = 4, int element = 0);
bool InCounterAttack() {
    bool retval;
    retval = view_as<bool>(GameRules_GetProp("m_bCounterAttack"));
    return retval;
}

public Plugin myinfo = {
	name = "[GG2 Messages] MESSAGES plugin",
	author = "zachm",
	description = "Get messages from the db, put them into game chat",
	version = "0.0.1",
	url = "http://sourcemod.net/"
};

public void OnMapStart() {
    CreateTimer(2.0, run_load_messages);
    CreateTimer(30.0, Timer_RotatingPlayerMessages, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(120.0, Timer_RotatingAdminMessages, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    HookEvent("round_start", Event_RoundStart);
    healthkit_theater_id = GetTheaterItemIdByWeaponName(healthkit_theater_item);
    defib_theater_id = GetTheaterItemIdByWeaponName(defib_theater_item);
}


public void OnPluginStart() {
    HookEvent("player_spawn", Event_PlayerSpawnInit, EventHookMode_Post);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured, EventHookMode_Pre);
    HookEvent("object_destroyed", Event_ObjectDestroyed, EventHookMode_Pre);
    HookEvent("weapon_deploy", Event_WeaponDeploy);
    Database.Connect(T_Connect, "insurgency_stats");
    LoadTranslations("tug.phrases");
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    g_iACP = 0;
    return Plugin_Continue;
}

public Action Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast) {
    /*
    g_iACP = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex") + 1;
    if (g_iNCP - 1 == g_iACP) {
        LogMessage("[GG MESSAGES] ACP: %i // NCP: %i (should be working on last cap now via capture)", g_iACP, g_iNCP);
        CPrintToChatAll(last_control_point_message);
    }
    */
    g_last_cap_not_cache = true;
    CreateTimer(2.0, Timer_CheckInCounter, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}


public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast) {
    /*
    g_iACP = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex") + 1;
    if (g_iNCP - 1 == g_iACP) {
        LogMessage("[GG MESSAGES] ACP: %i // NCP: %i (should be working on last cap now via object_destroyed)", g_iACP, g_iNCP);
        CPrintToChatAll(last_control_point_message);
    }
    */
    g_last_cap_not_cache = false;
    CreateTimer(2.0, Timer_CheckInCounter, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue
}

public Action Event_WeaponDeploy(Event event, const char[] name, bool dontBroadcast) {
    int weapon_id = GetEventInt(event, "weaponid");
    if (weapon_id == healthkit_theater_id) {
        int client = GetClientOfUserId(GetEventInt(event, "userid"));
        PrintHintText(client, "%T", "justholdit", client);
    }
    if (weapon_id == defib_theater_id) {
        int client = GetClientOfUserId(GetEventInt(event, "userid"));
        PrintHintText(client, "%T", "justholditdefib", client);
    }
    return Plugin_Continue;
}

public bool is_translatable(char[] phrase) {
    if (StrContains(phrase, " ") >= 0) {
        //LogMessage("[GG2 MESSAGES] Found UN-translatable phrase // %s (%i)", phrase, g_rotating_player_messages_offset);
        return false;
    }
    //LogMessage("[GG2 MESSAGES] Found translatable phrase // %s (%i)",phrase, g_rotating_player_messages_offset);
    return true;
    /*
    for (int i = 0; i < sizeof(translatables); i++) {
        if (StrEqual(phrase, translatables[i])) {
            return true;
        }
    }
    return false;
    */
}

public Action Timer_MapStart(Handle timer) {
    g_iNCP = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
    g_last_cap_not_cache = true;
    return Plugin_Continue;
}

public Action Timer_CheckInCounter(Handle timer) {
    if (InCounterAttack()) {
        LogMessage("[GG2 MESSAGES] In CounterAttack, tell them not to advance so far");
        if (g_last_cap_not_cache) {
            CPrintToChatAll(in_counter_attack_hold_message);
        } else {
            CPrintToChatAll(in_counter_attack_cache_message);
        }
    }
    g_iACP = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex") + 1;
    if (g_iNCP - 1 == g_iACP) {
        CreateTimer(1.0, Timer_FinalCPMessage, _, TIMER_FLAG_NO_MAPCHANGE | TIMER_REPEAT);
    }
    return Plugin_Continue;
}

public Action Timer_FinalCPMessage(Handle timer) {
    if (InCounterAttack()) {
        return Plugin_Continue;
    }
    CPrintToChatAll(last_control_point_message);
    return Plugin_Stop;
}



public void T_Connect(Database db, const char[] error, any data) {
    if(db == null){
        LogError("[GG2 MESSAGES] T_Connect returned invalid Database Handle");
        SetFailState("FAILED TO CONNECT TO M DB, BAILING");
        return;
    }
    g_Database = db;
    SQL_SetCharset(g_Database, "utf8mb4");    
    return;
} 

public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
    if (strlen(error) != 0) {
        LogMessage("[GG2 MESSAGES] error: %s", error);
    }
    return;
}

public void load_rotating_player_messages(Handle owner, Handle results, const char[] error, any client) {
    int rows = SQL_GetRowCount(results);
    LogMessage("[GG2 MESSAGES] Retreived %i rotating player messages", rows);
    if (rows > 0) {
        int offset = 0;
        char message[256];
        while(SQL_FetchRow(results)) {
            SQL_FetchString(results, 0, message, sizeof(message));
            rotating_player_messages[offset] = message;
            offset++;
        }
    }
}
public void load_rotating_admin_messages(Handle owner, Handle results, const char[] error, any client) {
    int rows = SQL_GetRowCount(results);
    LogMessage("[GG2 MESSAGES] Retreived %i rotating admin messages", rows);
    if (rows > 0) {
        int offset = 0;
        char message[256];
        while(SQL_FetchRow(results)) {
            SQL_FetchString(results, 0, message, sizeof(message));
            rotating_admin_messages[offset] = message;
            offset++;
        }
    }
}
public void load_player_join_messages(Handle owner, Handle results, const char[] error, any client) {
    int rows = SQL_GetRowCount(results);
    
    if (rows > 0) {
        int offset = 0;
        char message[256];
        while(SQL_FetchRow(results)) {
            SQL_FetchString(results, 0, message, sizeof(message));
            
            if (!StrEqual(message, "")) {
                player_join_messages[offset] = message;
                //if (is_translatable(message)) {
                //    LogMessage("[GG2 MESSAGES] Got Translatable Message: %s", message);
                //}
                offset++;
            }// else {
            //    LogMessage("[GG2 MESSAGES] Got empty join message, disregarding that bullshit");
            //}
        }
    }
    LogMessage("[GG2 MESSAGES] Retreived %i player join messages", rows);
}

public void get_rotating_player_messages() {
    char query[512];
    Format(query, sizeof(query), "SELECT message FROM gg2_messages_rotating_player WHERE enabled = 1 ORDER BY id ASC;");
    SQL_TQuery(g_Database, load_rotating_player_messages, query);
}
public void get_rotating_admin_messages() {
    char query[512];
    Format(query, sizeof(query), "SELECT message FROM gg2_messages_rotating_admin WHERE enabled = 1 ORDER BY id ASC;");
    SQL_TQuery(g_Database, load_rotating_admin_messages, query);
}
public void get_player_join_messages() {
    char query[512];
    Format(query, sizeof(query), "SELECT message FROM gg2_messages_join_player WHERE enabled = 1 ORDER BY id ASC;");
    SQL_TQuery(g_Database, load_player_join_messages, query);
}

public Action run_load_messages(Handle timer) {
    get_rotating_player_messages();
    get_rotating_admin_messages();
    get_player_join_messages();
    return Plugin_Continue;
}

public Action Timer_RotatingPlayerMessages(Handle timer) {
    if ((g_rotating_player_messages_offset == sizeof(rotating_player_messages)) ||
        (StrEqual(rotating_player_messages[g_rotating_player_messages_offset], "\0"))) {
        g_rotating_player_messages_offset = 0;
        get_rotating_player_messages();
    }
    if (is_translatable(rotating_player_messages[g_rotating_player_messages_offset])) {
         CPrintToChatAll("%t", rotating_player_messages[g_rotating_player_messages_offset]);
    }
    /*
    if (StrEqual(rotating_player_messages[g_rotating_player_messages_offset], "dontbeadick")) {
        CPrintToChatAll("{red}PROTIP: {common}%t", rotating_player_messages[g_rotating_player_messages_offset]);
    } else if (StrEqual(rotating_player_messages[g_rotating_player_messages_offset], "findresupply")) {
        CPrintToChatAll("{red}PROTIP: {common}%t", rotating_player_messages[g_rotating_player_messages_offset]);
    } else if (StrEqual(rotating_player_messages[g_rotating_player_messages_offset], "dragbodies")) {
        CPrintToChatAll("{red}PROTIP: {common}%t", rotating_player_messages[g_rotating_player_messages_offset]);
    } else if (StrEqual(rotating_player_messages[g_rotating_player_messages_offset], "getsmoke")) {
        CPrintToChatAll("{red}PROTIP: {common}%t", rotating_player_messages[g_rotating_player_messages_offset]);
    } else if (StrEqual(rotating_player_messages[g_rotating_player_messages_offset], "catchfire")) {
        CPrintToChatAll("{red}PROTIP: {common}%t", rotating_player_messages[g_rotating_player_messages_offset]);
    } 
    */
    else {
        CPrintToChatAll(rotating_player_messages[g_rotating_player_messages_offset]);
    }
    g_rotating_player_messages_offset++;
    return Plugin_Continue;
}

public Action Timer_RotatingAdminMessages(Handle timer) {
    if ((g_rotating_admin_messages_offset == sizeof(rotating_admin_messages)) ||
        (StrEqual(rotating_admin_messages[g_rotating_admin_messages_offset], "\0"))) {
        g_rotating_admin_messages_offset = 0;
        get_rotating_admin_messages();
    }
    int client;
    for (client = 1; client <=MaxClients; client++) {
        if (!IsValidPlayer(client)) {
            continue;
        }
        int clientTeam = GetClientTeam(client);
        if (IsFakeClient(client) || clientTeam != 2) {
            continue;
        } 
        AdminId clientAdmin = GetUserAdmin(client);
        if(clientAdmin == INVALID_ADMIN_ID) {
            continue;
        }
        CPrintToChat(client, rotating_admin_messages[g_rotating_admin_messages_offset]);
    }
    g_rotating_admin_messages_offset++;
    return Plugin_Continue;
}

// only show this once upon first spawn
public void Event_PlayerSpawnInit(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client)) {
        return;
    }
    int clientTeam = GetClientTeam(client);
    // not a bot
    if (IsFakeClient(client) || clientTeam != 2) {
        return;
    } 
    if (!g_players[client]) {
        char the_color[64];
        for (int i = 0; i < sizeof(player_join_messages)-1; i++) {
            //LogMessage("[GG2 MESSAGES] Iterating join message offset %i", i);
            if (i % 2 == 0) {
                the_color = "{dodgerblue}";
            } else {
                the_color = "{yellow}";
            }

            if (StrEqual(player_join_messages[i], "")) {
                //LogMessage("[GG2 MESSAGES] Found empty message..  breaking nao");
                break;
            }
            
            if (is_translatable(player_join_messages[i])) {
                //LogMessage("[GG2 MESSAGES] trying to translate: %s at offset %i", player_join_messages[i], i);
                //char join_message_wtf[255];
                //char join_message_trans[255];
                //strcopy(join_message_wtf, sizeof(join_message_wtf), player_join_messages[i]);
                CPrintToChat(client, "%T", player_join_messages[i], client);
                //Format(join_message_trans, sizeof(join_message_trans), "%t", join_message_wtf, client);
                //CPrintToChat(client, "%T", player_join_messages[i], client);
                //CPrintToChat(client, join_message_trans);
            } else {
                CPrintToChat(client, "%s%s", the_color, player_join_messages[i]);
            }
            
            //CPrintToChat(client, "%s", player_join_messages[i]);
        }
        g_players[client] = true;
    }
    
}

public void OnClientDisconnect_Post(int client) {
    if (g_players[client]) {
        g_players[client] = false;
    }
}

public bool IsValidPlayer(int client) {
    return (0 < client <= MaxClients) && IsClientInGame(client);
}