#include <sourcemod>
#include <sdktools>
#include <dbi>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "0.0.1.1"
#define PLUGIN_DESCRIPTION "Stats system IMPROVED // SIMPLIFIED (mariadb)"
#define TEAM_NONE	0
#define TEAM_SPEC	1
#define TEAM_1_SEC	2
#define TEAM_2_INS	3


ConVar g_server_id;
Database g_Database = null;

bool g_db_up = false;
char g_SteamID[MAXPLAYERS+1][32];

int g_iStartScore[MAXPLAYERS+1];
int g_player_id[MAXPLAYERS+1] = {0, ...};
int g_current_map_id = 0;
char g_current_map_name[128];
char bawt_steam_id[64] = "STEAM_ID_STOP_IGNORING_RETVALS";
char g_client_last_classstring[MAXPLAYERS+1][64];
char US_ARTY_SMOKE[] = "grenade_m18_us";
int g_killstreak[MAXPLAYERS+1] = {0, ...};
//int g_killstreak_current_max[MAXPLAYERS+1] = {0, ...};

float g_fLastHitTime[MAXPLAYERS+1];
char g_bot_ids[1024][64];
char g_weapon_ids[1024][64];
char g_role_ids[24][64];
char g_amnesty_players[1024][64];

public Plugin myinfo = {
    name = "[GG2 MSTATS2] Simplified",
    author = "zachm & Bot Chris",
    version = PLUGIN_VERSION,
    description = PLUGIN_DESCRIPTION,
    url = "http://tug.gg"
};


public void OnPluginStart() {
    g_server_id = CreateConVar("gg_stats_server_id", "1", "server_id for database", FCVAR_PROTECTED, true, 0.0, true, 1024.0);
    Database.Connect(T_Connect, "insurgency_stats");

    HookEvent("player_activate", Event_PlayerActivate);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    HookEvent("player_spawn", Event_SpawnPost, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_hurt", Event_PlayerHurt);
    HookEvent("grenade_thrown", Event_GrenadeThrown);
    //HookEvent("medic_Revived", Event_MedicRevived);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured);
    HookEvent("object_destroyed", Event_ObjectDestroyed);
    HookEvent("player_suppressed", Event_PlayerSuppressed);
    
    CreateTimer(3.0, load_bot_ids);
    CreateTimer(3.0, load_weapon_ids);
    CreateTimer(3.0, load_player_ids);
    CreateTimer(3.0, load_role_ids);
    CreateTimer(5.0, show_role_ids);

    AutoExecConfig(true, "gg2_mstats2");
}

int GetGameState() {
    return GameRules_GetProp("m_iGameState");
}

public bool IsValidPlayer(int client) {
    return (0 < client <= MaxClients) && IsClientInGame(client);
}

public Action run_amnesty(Handle timer) {
    if (g_db_up) {
        get_amnesty_players();
    }
    return Plugin_Continue;
}

public bool has_amnesty(int attacker_client) {
    char attacker_steamid64[64];
    GetClientAuthId(attacker_client, AuthId_SteamID64, attacker_steamid64, sizeof(attacker_steamid64));
    bool res = false;
    for (int i = 0; i < sizeof(g_amnesty_players); i++) {
        if (StrEqual("",g_amnesty_players[i])) {
            break;
        }
        if (StrEqual(g_amnesty_players[i], attacker_steamid64)) {
            res = true;
            LogMessage("[GG2 MSTATS2] AMNESTY granted to %N", attacker_client);
        }
    }
    if (!res) {
        LogMessage("[GG2 MSTATS2] NO AMNESTY granted to %N", attacker_client);
    }
    return res;
}
public void get_amnesty_players() {
    char query[512];
    Format(query, sizeof(query), "SELECT DISTINCT steam_id, player_name FROM `redux_players` WHERE tk_amnesty = 1 AND server_id = '%i' ORDER BY steam_id ASC;", g_server_id.IntValue);
    SQL_TQuery(g_Database, load_amnesty_players, query);
}

public void load_amnesty_players(Handle owner, Handle results, const char[] error, any client) {
    int rows = SQL_GetRowCount(results);
    LogMessage("[GG2 MSTATS2] Retreived %i TK Amnesty players for server_id %i", rows, g_server_id.IntValue);
    if (rows > 0) {
        int offset = 0;
        char steamid_64[64];
        while(SQL_FetchRow(results)) {
            SQL_FetchString(results, 0, steamid_64, sizeof(steamid_64));
            g_amnesty_players[offset] = steamid_64;
            offset++;
        }
    }
}



public void clear_last_classstrings() {
    for (int client = 1; client < MaxClients; client++) {
        g_client_last_classstring[client] = "";
    }
}

public Action Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsFakeClient(client)) {
        return Plugin_Continue;
    }
    char class_template[64];
    event.GetString("class_template", class_template, sizeof(class_template));
    g_client_last_classstring[client] = class_template;
    return Plugin_Continue;
}


public void log_stats_message(char[] message) {
    char final_message[2048+64];
    Format(final_message, sizeof(final_message), "[GG2 MSTATS2 %s] %s", PLUGIN_VERSION, message);
    LogMessage(final_message);
}

public any Native_update_medic_time(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    int time_to_add = GetNativeCell(2);
    char query[512];
    Format(query, sizeof(query), "UPDATE redux_players SET medic_time = medic_time + %i WHERE id = '%i' LIMIT 1", time_to_add, g_player_id[client]);
    SQL_TQuery(g_Database, do_nothing, query, client);
    return true;
}


public any Native_update_healed_hp_count(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    int hp_amount = GetNativeCell(2);
    char query[512];
    Format(query, sizeof(query), "UPDATE redux_players SET healed_hp = healed_hp + %i WHERE id = '%i' LIMIT 1", hp_amount, g_player_id[client]);
    SQL_TQuery(g_Database, do_nothing, query, client);
    return true;
}

public any Native_update_revive_count(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    char query[512];
    Format(query, sizeof(query), "UPDATE redux_players SET revives = revives + 1 WHERE id = '%i' LIMIT 1", g_player_id[client]);
    SQL_TQuery(g_Database, do_nothing, query, client);
    return true;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    CreateNative("update_revive_count", Native_update_revive_count);
    CreateNative("update_healed_hp_count", Native_update_healed_hp_count);
    CreateNative("update_medic_time", Native_update_medic_time);
    return APLRes_Success;
}



public Action Event_PlayerActivate(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Continue;

	CreateTimer(1.0, Timer_GetScore, client, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Continue;
}

Action Timer_GetScore(Handle timer, int client) {
	if (!IsValidPlayer(client)) return Plugin_Continue;

	g_iStartScore[client] = GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iPlayerScore", _, client);
	return Plugin_Continue;
}

public void T_Connect(Database db, const char[] error, any data) {
    if(db == null){
        LogError("[GG2 MSTATS] T_Connect returned invalid Database Handle");
        SetFailState("FAILED TO CONNECT TO M DB, BAILING");
        return;
    }
    g_Database = db;
    SQL_SetCharset(g_Database, "utf8mb4");
    log_stats_message("Connected to Database.");
    g_db_up = true;
    return;
}

public void do_nothing(Handle owner, Handle results, const char[] error, any data) {
    if (strlen(error) != 0) {
        char message[8192];
        Format(message, sizeof(message),"%s // %N",error, data);
        log_stats_message(message);
    }
    return;
}

public void do_absolutely_nothing(Handle owner, Handle results, const char[] error, any data) {
    if (strlen(error) != 0) {
        char message[8192];
        Format(message, sizeof(message),"%s // %i",error, data);
        log_stats_message(message);
    }
    return;
}

public void OnMapStart() {
    GetCurrentMap(g_current_map_name, sizeof(g_current_map_name));
    CreateTimer(3.0, load_map_id);
    CreateTimer(2.0, run_amnesty);
}

public Action load_map_id(Handle timer) {
    char query[512];
    Format(query, sizeof(query), "SELECT id FROM maps WHERE map_name = '%s' LIMIT 1", g_current_map_name);
    SQL_TQuery(g_Database, load_map_id_callback, query, 0);
    return Plugin_Continue;
}


public Action load_player_ids(Handle timer) {
    char query[512];
    for (int client = 1; client <=MaxClients; client++) {
        if (!IsValidPlayer(client)) {
            continue;
        }
        int clientTeam = GetClientTeam(client);
        if (IsFakeClient(client) || clientTeam != TEAM_1_SEC) {
            continue;
        }
        GetClientAuthId(client, AuthId_SteamID64, g_SteamID[client], 32);
        Format(query, sizeof(query), "SELECT id FROM redux_players WHERE steam_id = '%s' AND server_id = '%i' LIMIT 1", g_SteamID[client], g_server_id.IntValue);
        SQL_TQuery(g_Database, load_player_callback, query, client);
    }
    return Plugin_Continue;
}

public void load_role_ids_callback(Handle owner, Handle results, const char[] error, any client) {
    while(SQL_FetchRow(results)) {
        int role_id = SQL_FetchInt(results, 0);
        char class_template[64];
        SQL_FetchString(results, 1, class_template, sizeof(class_template));
        g_role_ids[role_id] = class_template;
    }
}

public Action show_role_ids(Handle timer) {
    for (int role_id = 1; role_id < sizeof(g_role_ids); role_id++) {
        LogMessage("[GG2 TESTER] role_loaded --> %i ----> %s", role_id, g_role_ids[role_id]);
        if (StrEqual(g_role_ids[role_id], "")) {
            break;
        }
    }
    return Plugin_Continue;
}

public Action load_role_ids(Handle timer) {
    char query[512];
    Format(query, sizeof(query), "SELECT id, class_template FROM roles ORDER BY id ASC");
    SQL_TQuery(g_Database, load_role_ids_callback, query, 0);
    return Plugin_Continue;
}


public Action load_weapon_ids(Handle timer) {
    char query[512];
    Format(query, sizeof(query), "SELECT id, weapon_name FROM weapons ORDER BY id ASC");
    SQL_TQuery(g_Database, load_weapon_ids_callback, query, 0);
    return Plugin_Continue;
}

public Action load_bot_ids(Handle timer) {
    char query[512];
    Format(query, sizeof(query), "SELECT id, bot_name FROM bot_names ORDER BY id ASC");
    SQL_TQuery(g_Database, load_bot_ids_callback, query, 0);
    return Plugin_Continue;
}

public void load_map_id_callback(Handle owner, Handle results, const char[] error, any client) {
    while(SQL_FetchRow(results)) {
        g_current_map_id = SQL_FetchInt(results, 0);
    }
} 

public void load_weapon_ids_callback(Handle owner, Handle results, const char[] error, any client) {
    while(SQL_FetchRow(results)) {
        int weapon_id = SQL_FetchInt(results, 0);
        char weapon_name[64];
        SQL_FetchString(results, 1, weapon_name, sizeof(weapon_name));
        g_weapon_ids[weapon_id] = weapon_name;
    }
}

public void load_bot_ids_callback(Handle owner, Handle results, const char[] error, any client) {
    while(SQL_FetchRow(results)) {
        int bot_id = SQL_FetchInt(results, 0);
        char bot_name[64];
        SQL_FetchString(results, 1, bot_name, sizeof(bot_name));
        g_bot_ids[bot_id] = bot_name;
    }
}

public void load_player(int client) {
    if (StrEqual(g_SteamID[client], bawt_steam_id)) {
        //log_stats_message("final bawt check returned true for insertion check");
        return;
    }
    char query[255];
    Format(query, sizeof(query), "SELECT id FROM redux_players WHERE steam_id = '%s' AND server_id = '%i' LIMIT 1", g_SteamID[client], g_server_id.IntValue);
    SQL_TQuery(g_Database, load_player_callback, query, client);
}

public void create_player(int client) {
    // one last check for bawtness //
    if (StrEqual(g_SteamID[client], bawt_steam_id)) {
        //log_stats_message("final bawt check returned true for insertion check");
        return;
    }
    char playerName[128];
    Format(playerName, sizeof(playerName), "%N", client);
    int buffer_len = strlen(playerName) * 2 + 1;
    char[] newplayerName = new char[buffer_len];
    SQL_EscapeString(g_Database, playerName, newplayerName, buffer_len);

    char query[512];
    Format(query, sizeof(query), "INSERT INTO redux_players (server_id, steam_id, player_name) VALUES ('%i', '%s', '%s');", g_server_id.IntValue, g_SteamID[client], newplayerName);
    //LogMessage("[GG Stats (M)] Attempting to insert %s // %s into the db", newplayerName, g_SteamID[client]);
    SQL_TQuery(g_Database, create_player_callback, query, client);
}

public void create_player_callback(Handle owner, Handle results, const char[] error, any client) {
    load_player(client);
}

public void load_player_callback(Handle owner, Handle results, const char[] error, any client) {
    if(results == INVALID_HANDLE) {
        LogToFile("wtf.log", "results query failed");
        delete results;
        return;
    }
    //create_player(client); // figure out what no results looks like here...
    int player_id = 0;
    while(SQL_FetchRow(results)) {
        player_id = SQL_FetchInt(results, 0);
        g_player_id[client] = player_id;
        g_killstreak[client] = 0;
        LogMessage("LOADED PLAYER -----> player_id %i", player_id);
    }
    if (player_id == 0) {
        create_player(client);
    } else {
        int now = GetTime();
        char query[512];
        Format(query, sizeof(query), "UPDATE redux_players SET last_seen = %i WHERE id = '%i' LIMIT 1", now, player_id);
        SQL_TQuery(g_Database, do_nothing, query, client);
    }
}


public void bot_kill_callback(Handle owner, Handle results, const char[] error, DataPack bot_kill_pack) {
    if(results == INVALID_HANDLE) {
        LogToFile("wtf.log", "bot_kill_callback query failed");
        delete results;
        return;
    }
    int affected_rows = SQL_GetAffectedRows(owner);
    if (affected_rows == 0) {
        
        bot_kill_pack.Reset();
        int bot_id = bot_kill_pack.ReadCell();
        int weapon_id = bot_kill_pack.ReadCell();

        LogMessage("FOUND 0 AFFECTED ROWS FOR BOT_KILLS UPDATE, NEED TO CREATE THIS NOW --> %i // %i", bot_id, weapon_id);
        char bot_kill_query[512];
        Format(bot_kill_query, sizeof(bot_kill_query), "INSERT INTO redux_bot_kills (bot_id, weapon_id) VALUES ('%i','%i');", bot_id, weapon_id);
        SQL_TQuery(g_Database, do_absolutely_nothing, bot_kill_query, bot_id);
    }
    CloseHandle(bot_kill_pack);
}

public void player_kill_callback(Handle owner, Handle results, const char[] error, DataPack player_kill_pack) {
    if(results == INVALID_HANDLE) {
        LogToFile("wtf.log", "player_kill_callback query failed");
        delete results;
        return;
    }
    int affected_rows = SQL_GetAffectedRows(owner);
    if (affected_rows == 0) {
        
        player_kill_pack.Reset();
        int player_id = player_kill_pack.ReadCell();
        int weapon_id = player_kill_pack.ReadCell();


        LogMessage("FOUND 0 AFFECTED ROWS FOR PLAYER_KILLS UPDATE, NEED TO CREATE THIS NOW --> %i // %i", player_id, weapon_id);
        char player_kill_query[512];
        Format(player_kill_query, sizeof(player_kill_query), "INSERT INTO redux_player_kills (player_id, weapon_id) VALUES ('%i','%i');", player_id, weapon_id);
        SQL_TQuery(g_Database, do_absolutely_nothing, player_kill_query, player_id);
    }
    CloseHandle(player_kill_pack);
}


public void should_update_killstreak_callback(Handle owner, Handle results, const char[] error, int last_killstreak) {
    int last_saved_killstreak = 0;
    int player_id = 0;
    while(SQL_FetchRow(results)) {
        player_id = SQL_FetchInt(results, 0);
        last_saved_killstreak = SQL_FetchInt(results, 1);
    }
    if (last_killstreak > last_saved_killstreak) {
        char update_killstreak_query[512];
        Format(update_killstreak_query, sizeof(update_killstreak_query), "UPDATE redux_players SET killstreak = '%i' WHERE id = '%i' LIMIT 1", last_killstreak, player_id);
        SQL_TQuery(g_Database, do_absolutely_nothing, update_killstreak_query, player_id);
    }
}


// public void parseInitialMaxKillStreak(Handle owner, Handle results, const char[] error, any client)
// {
//     if(results == INVALID_HANDLE) {
//         LogToFile("wtf.log", "results query failed");
//         delete results;
//         return;
//     }
//     if (!IsClientInGame(client)) {
//         LogMessage("client was not in game, setting current_max killstreak 0... ");
//         g_killstreak_current_max[client] = 0;
//         return;
//     }
//     while(SQL_FetchRow(results)) {
//         int ks = SQL_FetchInt(results, 0);
//         g_killstreak_current_max[client] = ks;
//         char message[255];
//         Format(message, sizeof(message),"%N starting killstreak --> %i",client, ks);
        
//         log_stats_message(message);
//         //LogMessage("[GG Stats (M)] Player: %N g_killstreak_current_max: %i", client, ks);
//     }
// }

// public void getInitialMaxKillStreak(int client) {
//     char query[512];
//     Format(query, sizeof(query), "SELECT killstreak FROM redux_players WHERE steam_id = '%s' AND server_id = %i LIMIT 1", g_SteamID[client], g_server_id.IntValue);
//     SQL_TQuery(g_Database, parseInitialMaxKillStreak, query, client);
// }

// public void OnClientAuthorized(int client) {
//     if(!IsFakeClient(client) && g_Database != null) {
//         if ((g_SteamID[client][0] == '\0') || (StrEqual(g_SteamID[client], bawt_steam_id))) {
//             LogMessage("[GG2 MSTATS2] invalid steamId, not checking if should create_player_if_needed");
//             return;
//         } else {
//             LogMessage("[GG2 MSTATS2] Guess we trying to create a player now...");
//             create_player(client);
            
//             //getInitialMaxKillStreak(client);
//         }
//     }
// }
public void OnClientPostAdminCheck(int client) {
    if (!IsFakeClient(client)) {
        GetClientAuthId(client, AuthId_SteamID64, g_SteamID[client], 32);
        load_player(client);
    } else {
        g_SteamID[client] = "";
    }
}

public Action Event_SpawnPost(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsFakeClient(client)) {
        return Plugin_Continue;
    }
    // getInitialMaxKillStreak(client);
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    if (GetGameState() != 4) {
        return Plugin_Continue;
    }
    
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));

    if (!IsValidPlayer(victim)) {
        return Plugin_Continue;
    }
    if ((victim == 0) && (attacker == 0)) {
        return Plugin_Continue;
    }
    if (!IsValidPlayer(attacker)) {
        return Plugin_Continue;
    }

    char victim_name[64];
    char attacker_name[64];
    int victim_team = 0;
    int attacker_team = 0;
    char weapon[64];

    event.GetString("weapon", weapon, sizeof(weapon));

    if (victim > 0) {
        // we have a real victim
        GetClientInfo(victim, "name", victim_name, sizeof(victim_name));
        victim_team = GetClientTeam(victim);
    } else {
        victim_name = "world";
    }
    if (attacker > 0) {
        // we have a real attacker
        GetClientInfo(attacker, "name", attacker_name, sizeof(attacker_name));
        attacker_team = GetClientTeam(attacker);
    } else {
        attacker_name = "world";
    }

    if ((victim == attacker) || (attacker == 0)) {
        // suicides
        if (victim_team == TEAM_2_INS) {
            // INS suicide
            ////log_bot_suicide(victim_name, weapon);
        } else {
            char suicide_query[512];
            Format(suicide_query, sizeof(suicide_query), "UPDATE redux_players SET suicides = suicides +1 WHERE id = '%i' LIMIT 1", g_player_id[victim]);
            SQL_TQuery(g_Database, do_nothing, suicide_query, victim);
            char killstreak_query[512];
            Format(killstreak_query, sizeof(killstreak_query), "SELECT id, killstreak FROM redux_players WHERE id = '%i' LIMIT 1", g_player_id[victim]);
            SQL_TQuery(g_Database, should_update_killstreak_callback, killstreak_query, g_killstreak[victim]);
            g_killstreak[victim] = 0;
            // SEC suicide
            ////g_suicides[victim]++;
            ////g_deaths[victim]++;
            ////if (shouldUpdateKillStreak(victim)) {
            ////    set_killstreak(victim, g_killstreak[victim]);
            ////}
            ////log_player_suicide(g_SteamID[victim], weapon, victim);
        }
        return Plugin_Continue;
    } else if (victim_team == attacker_team) {
        // tks
        if (victim_team == TEAM_2_INS) {
            // INS tk
            LogMessage("[GG2 MSTATS] bawt on bawt violence, ignore");
            return Plugin_Continue;
        } else {
            int now = GetTime();
            int weapon_id = 0;
            for (weapon_id = 0; weapon_id < sizeof(g_weapon_ids); weapon_id++) {
                if (strcmp(g_weapon_ids[weapon_id], weapon) == 0) {
                    //LogMessage("FOUND WEAPON_ID --------> %i", weapon_id);
                    break;
                }
            }
            int attacker_role_id = 1;
            int victim_role_id = 1;
            for (int iter_role_id = 1; iter_role_id < sizeof(g_role_ids); iter_role_id++) {
                if (StrEqual(g_client_last_classstring[attacker], g_role_ids[iter_role_id])) {
                    attacker_role_id = iter_role_id;
                }
                if (StrEqual(g_client_last_classstring[victim], g_role_ids[iter_role_id])) {
                    victim_role_id = iter_role_id;
                }
            }
            char attacker_role_message[128];
            char victim_role_message[128];
            Format(attacker_role_message, sizeof(attacker_role_message), "TK ATTACKER role_id %i --> %s", attacker_role_id, g_client_last_classstring[attacker]);
            Format(victim_role_message, sizeof(victim_role_message), "TK VICTIM role_id %i --> %s", victim_role_id, g_client_last_classstring[victim]);
            LogMessage("[GG2 MSTATS2] TK_ROLE_MESSAGE --> %s", attacker_role_message);
            LogMessage("[GG2 MSTATS2] TK_ROLE_MESSAGE --> %s", victim_role_message);
            char given_query[512];
            char taken_query[512];
            char tks_query[512];
            int amnesty = 0;
            if (has_amnesty(attacker)) {
                amnesty = 1;
            }
            Format(given_query, sizeof(given_query), "UPDATE redux_players SET tk_given = tk_given +1 WHERE id = '%i' LIMIT 1", g_player_id[attacker]);
            Format(taken_query, sizeof(taken_query), "UPDATE redux_players SET tk_taken = tk_taken +1 WHERE id = '%i' LIMIT 1", g_player_id[victim]);
            Format(tks_query, sizeof(tks_query), "INSERT INTO redux_player_tks (attacker_id, victim_id, weapon_id, map_id, attacker_role_id, victim_role_id, amnesty, occurred) VALUES ('%i', '%i', '%i', '%i', '%i', '%i', '%i', '%i')", g_player_id[attacker], g_player_id[victim], weapon_id, g_current_map_id, attacker_role_id, victim_role_id, amnesty, now);
            SQL_TQuery(g_Database, do_nothing, given_query, attacker);
            SQL_TQuery(g_Database, do_nothing, taken_query, victim);
            SQL_TQuery(g_Database, do_nothing, tks_query, attacker);
            char killstreak_query[512];
            Format(killstreak_query, sizeof(killstreak_query), "SELECT id, killstreak FROM redux_players WHERE id = '%i' LIMIT 1", g_player_id[attacker]);
            SQL_TQuery(g_Database, should_update_killstreak_callback, killstreak_query, g_killstreak[attacker]);
            g_killstreak[attacker] = 0;
            // SEC tk
            ////g_tk_taken[victim]++;
            ////g_tk_given[attacker]++;
            ////if (shouldUpdateKillStreak(victim)) {
            ////    set_killstreak(victim, g_killstreak[victim]);
            ////}
            ////if (shouldUpdateKillStreak(attacker)) {
            ////    set_killstreak(attacker, g_killstreak[attacker]);
            ////}
            ////g_killstreak[victim] = 0;
            ////g_killstreak[attacker] = 0;
            ////log_player_tk(g_SteamID[attacker], g_SteamID[victim], weapon, attacker);
            ////g_kills_total_sec++;
        }
        return Plugin_Continue;
    } 
    else if (victim_team != attacker_team) {
        // SEC vs INS
        char kill_update_query[512];
        char death_update_query[512];
        char player_kills_query[512];
        char bot_kills_query[512];
        int weapon_id;
        for (weapon_id = 0; weapon_id < sizeof(g_weapon_ids); weapon_id++) {
            if (strcmp(g_weapon_ids[weapon_id], weapon) == 0) {
                //LogMessage("FOUND WEAPON_ID --------> %i", weapon_id);
                break;
            }
        }
        if (victim_team == TEAM_2_INS) {
            if (g_player_id[attacker] == 0) {
                load_player(attacker);
            }
            
            
            //Format(kill_update_query, sizeof(kill_update_query), "UPDATE redux_players SET kills = kills + 1 WHERE steam_id = '%s' and server_id = '%i'", g_SteamID[attacker], g_server_id.IntValue);
            Format(kill_update_query, sizeof(kill_update_query), "UPDATE redux_players set kills = kills + 1 WHERE id = '%i' LIMIT 1", g_player_id[attacker]);
            Format(player_kills_query, sizeof(player_kills_query), "UPDATE redux_player_kills set kill_count = kill_count +1 WHERE player_id = '%i' AND weapon_id = '%i'", g_player_id[attacker], weapon_id);
            DataPack player_kill_pack = new DataPack();
            player_kill_pack.WriteCell(g_player_id[attacker]);
            player_kill_pack.WriteCell(weapon_id);
            SQL_TQuery(g_Database, do_nothing, kill_update_query, attacker);
            SQL_TQuery(g_Database, player_kill_callback, player_kills_query, player_kill_pack);
            g_killstreak[attacker]++;
            // SEC killed INS
            ////g_kills[attacker]++;
            ////g_killstreak[attacker]++;
            ////if (g_killstreak[attacker] > g_killstreak_current_max[attacker]) {
            ////    g_killstreak_current_max[attacker] = g_killstreak[attacker];
            ////}
            ////log_player_kill(g_SteamID[attacker], victim_name, weapon, attacker);
            ////g_kills_total_sec++;
        } else {
            int bot_id;
            for (bot_id = 0; bot_id < sizeof(g_bot_ids); bot_id++) {
                if (strcmp(g_bot_ids[bot_id], attacker_name) == 0) {
                    //LogMessage("FOUND BOT_ID --------> %i", bot_id);
                    break;
                }
            }
            //Format(death_update_query, sizeof(death_update_query), "UPDATE redux_players SET deaths = deaths + 1 WHERE steam_id = '%s' and server_id = '%i'", g_SteamID[attacker], g_server_id.IntValue);
            Format(death_update_query, sizeof(death_update_query), "UPDATE redux_players SET deaths = deaths + 1 WHERE id = '%i' LIMIT 1", g_player_id[victim]);
            Format(bot_kills_query, sizeof(bot_kills_query), "UPDATE redux_bot_kills SET kill_count = kill_count +1 WHERE bot_id = '%i' AND weapon_id = '%i'", bot_id, weapon_id);
            DataPack bot_kill_pack = new DataPack();
            bot_kill_pack.WriteCell(bot_id);
            bot_kill_pack.WriteCell(weapon_id);
            SQL_TQuery(g_Database, do_nothing, death_update_query, victim);
            SQL_TQuery(g_Database, bot_kill_callback, bot_kills_query, bot_kill_pack);
            char killstreak_query[512];
            Format(killstreak_query, sizeof(killstreak_query), "SELECT id, killstreak FROM redux_players WHERE id = '%i' LIMIT 1", g_player_id[victim]);
            SQL_TQuery(g_Database, should_update_killstreak_callback, killstreak_query, g_killstreak[victim]);
            g_killstreak[victim] = 0;
            // INS killed SEC
            ////g_deaths[victim]++;
            ////if (shouldUpdateKillStreak(victim)) {
            ////    set_killstreak(victim, g_killstreak[victim]);
            ////    g_killstreak[victim] = 0;
            ////}
            ////g_kills_total_ins++;
            ////log_bot_kill(attacker_name, g_SteamID[victim], weapon);
        }
        return Plugin_Continue;
    }
    LogMessage("[GG2 MSTATS] UNKNOWN DEATH_TYPE xxxxxxxx victim: (client: %i) (name: %s) (team: %i) // attacker: (client: %i) (name: %s) (team: %i) // weapon: %s", victim, victim_name, victim_team, attacker, attacker_name, attacker_team, weapon);
    return Plugin_Continue;
}


public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast) {
    int hitgroup = GetEventInt(event, "hitgroup");
    if (hitgroup != 1) {
        return Plugin_Continue;
    }
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    
    // "world"
    if (!IsValidPlayer(victim) || !IsValidPlayer(attacker)) {
        return Plugin_Continue;
    }

    int attacker_team = GetClientTeam(attacker);
    int victim_team = GetClientTeam(victim);

    // bawt on bawt violence, ignore
    if ((attacker_team == victim_team) && (attacker_team == TEAM_2_INS)) {
        return Plugin_Continue;
    }

    if (IsValidPlayer(attacker) && g_fLastHitTime[attacker] != GetGameTime()) {
        g_fLastHitTime[attacker] = GetGameTime();
        // char vic_name[64];
        // char att_name[64];
        // GetClientInfo(victim, "name", vic_name, sizeof(vic_name));
        // GetClientInfo(attacker, "name", att_name, sizeof(att_name));
        
        if (victim_team == TEAM_2_INS) {
            //g_headshot_given[attacker]++;
            char hs_given_query[512];
            Format(hs_given_query, sizeof(hs_given_query), "UPDATE redux_players SET headshot_given = headshot_given +1 WHERE id = '%i' LIMIT 1", g_player_id[attacker]);
            SQL_TQuery(g_Database, do_nothing, hs_given_query, attacker);
            //LogMessage("[GG Stats (M)] %N headshot bawt // headshot_given: %i", attacker, g_headshot_given[attacker]);
            //PrintToChat(attacker, "HeadShot TO %s", vic_name);
        } else {
            //g_headshot_taken[victim]++;
            char hs_taken_query[512];
            Format(hs_taken_query, sizeof(hs_taken_query), "UPDATE redux_players SET headshot_taken = headshot_taken +1 WHERE id = '%i' LIMIT 1", g_player_id[victim]);
            SQL_TQuery(g_Database, do_nothing, hs_taken_query, victim);
            //LogMessage("[GG Stats (M)] %N headshot BY a bawt // headshot_taken: %i", victim, g_headshot_taken[victim]);
            //PrintToChat(victim, "HeadShot BY %s", att_name);
        }
    }
    return Plugin_Continue;
}


public Action Event_PlayerSuppressed(Event event, const char[] name, bool dontBroadcast ) {
    int victim   = GetClientOfUserId(GetEventInt(event, "victim"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsValidPlayer(victim) || !IsValidPlayer(attacker)) return Plugin_Continue;
    int victim_team = GetClientTeam(victim);
    int attacker_team = GetClientTeam(attacker);
    // If attacker or victim is invalid, attacker is victim, or same team, do not reward
    if (attacker == victim || victim_team == attacker_team) {
        return Plugin_Continue;
    }
    char query[512];
    Format(query, sizeof(query), "UPDATE redux_players SET suppressions = suppressions +1 WHERE id = '%i' LIMIT 1", g_player_id[attacker]);
    SQL_TQuery(g_Database, do_nothing, query, attacker);
    return Plugin_Continue;
}

public Action Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast) {
    char cappers[256];
    char cpname[64];
    char capper_query[512];
    GetEventString(event, "cappers", cappers, sizeof(cappers));
    GetEventString(event, "cpname", cpname, sizeof(cpname));
    for (int i = 0; i < strlen(cappers); i++) {
        int client = cappers[i];
        if(client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client)) {
            //g_caps[client]++;
            Format(capper_query, sizeof(capper_query), "UPDATE redux_players SET caps = caps +1 WHERE id = '%i' LIMIT 1", g_player_id[client]);
            SQL_TQuery(g_Database, do_nothing, capper_query, client);
            LogMessage("[GG2 MSTATS] %N awarded cap", client);
        }
    }
    return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast) {

    int attacker, assister;
    attacker = GetEventInt(event, "attacker");
    if (!IsValidPlayer(attacker) || IsFakeClient(attacker)) return Plugin_Continue; //mc bot can destroy cache when CA

    char attacker_query[512];
    Format(attacker_query, sizeof(attacker_query), "UPDATE redux_players SET caps = caps +1 WHERE id = '%i' LIMIT 1", g_player_id[attacker]);
    SQL_TQuery(g_Database, do_nothing, attacker_query, attacker);

    assister = GetEventInt(event, "assister");
    if (!IsValidPlayer(assister) || IsFakeClient(assister)) return Plugin_Continue; //mc bot can destroy cache when CA

    char assister_query[512];
    Format(assister_query, sizeof(assister_query), "UPDATE redux_players SET caps = caps +1 WHERE id = '%i' LIMIT 1", g_player_id[assister]);
    SQL_TQuery(g_Database, do_nothing, assister_query, assister);
    return Plugin_Continue;
}

public Action Event_GrenadeThrown(Handle event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client)) {
        return Plugin_Continue;
    }
    int nade_id = GetEventInt(event, "entityid");
    if (nade_id < 0) {
        return Plugin_Continue;
    }
    char grenade_name[32];
    GetEntityClassname(nade_id, grenade_name, sizeof(grenade_name));
    // LogMessage("got nade throw --> %s", grenade_name);
    if (StrEqual(grenade_name, US_ARTY_SMOKE)) {
        char arty_throw_query[512];
        Format(arty_throw_query, sizeof(arty_throw_query), "UPDATE redux_players SET arty_thrown = arty_thrown +1 WHERE id = '%i' LIMIT 1", g_player_id[client]);
        SQL_TQuery(g_Database, do_nothing, arty_throw_query, client);
    }
    return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    //LogMessage("[GG Stats (M)] player %N left, writing stats to db, clearing client globals (if it's not a bawt)", client);
    if (IsValidPlayer(client)) {
        if (GetClientTeam(client) == TEAM_1_SEC) {
            int player_score = GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iPlayerScore", _, client)-g_iStartScore[client];
            if (player_score > 0) {
                //set_score(client, player_score);
                char score_query[512];
                Format(score_query, sizeof(score_query), "UPDATE redux_players SET score = score + %i WHERE id = %i LIMIT 1", player_score, g_player_id[client]);
                SQL_TQuery(g_Database, do_nothing, score_query, client);
            }
        }
        //clear_stats(client);
    }
    g_client_last_classstring[client] = "";
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    LogMessage("[GG2 MSTATS] round_end called, running set_score");
    int winner = GetEventInt(event, "winner");
    int player_win, player_loss = 0;
    int player_score;
    if (winner == TEAM_1_SEC) {
        player_win = 1;
    } else {
        player_loss = 1;
    }
    char player_name[128];
    for (int client = 1; client <= MaxClients; client++) {
        
        if (!IsClientInGame(client)) {
            continue;
        }
        if (GetClientTeam(client) != TEAM_1_SEC) {
            continue;
        }
        player_score = GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iPlayerScore", _, client);
        Format(player_name, sizeof(player_name), "%N", client);
        if (player_score-g_iStartScore[client] > 0 && GetClientTeam(client) == TEAM_1_SEC) {
            PrintToChat(client, "GG2 // Player: %s Score: %i", player_name, player_score);
            //set_score(client, player_score-g_iStartScore[client]);
            int updated_score = player_score-g_iStartScore[client];
            char score_query[512];
            Format(score_query, sizeof(score_query), "UPDATE redux_players SET score = score + %i, wins = wins +%i, losses = losses + %i WHERE id = %i LIMIT 1", updated_score, player_win, player_loss, g_player_id[client]);
            SQL_TQuery(g_Database, do_nothing, score_query, client);
            g_iStartScore[client] = player_score;
        }
        char killstreak_query[512];
        Format(killstreak_query, sizeof(killstreak_query), "SELECT id, killstreak FROM redux_players WHERE id = '%i' LIMIT 1", g_player_id[client]);
        SQL_TQuery(g_Database, should_update_killstreak_callback, killstreak_query, g_killstreak[client]);
        g_killstreak[client] = 0;
    }
    char map_win_loss_query[512];
    Format(map_win_loss_query, sizeof(map_win_loss_query), "UPDATE maps SET wins = wins +%i, losses = losses +%i WHERE id = %i LIMIT 1", player_win, player_loss, g_current_map_id);
    SQL_TQuery(g_Database, do_absolutely_nothing, map_win_loss_query, 0);
    char server_win_loss_query[512];
    Format(server_win_loss_query, sizeof(server_win_loss_query), "UPDATE server_stats SET security_wins = security_wins +%i, insurgent_wins = insurgent_wins +%i WHERE server_id = %i LIMIT 1", player_win, player_loss, g_server_id.IntValue);
    SQL_TQuery(g_Database, do_absolutely_nothing, server_win_loss_query, 0);
    int now = GetTime();
    char win_loss_log_query[512];
    Format(win_loss_log_query, sizeof(win_loss_log_query), "INSERT INTO win_loss_log (server_id, map_id, occurred, win) VALUES ('%i', '%i', '%i', '%i')", g_server_id.IntValue, g_current_map_id, now, player_win);
    SQL_TQuery(g_Database, do_absolutely_nothing, win_loss_log_query, 0);
    return Plugin_Continue;
}

// FIGURE THIS OUT
// public Action Event_MedicRevived(Event event, const char[] name, bool dontBroadcast) {
//     int medic_id = GetEventInt(event, "iMedic");
//     int injured_id = GetEventInt(event, "iInjured");
//     char message[512];
//     Format(message, sizeof(message), "GOT EVENT MEDIC REVIVE ----> %N revived %N", medic_id, injured_id);
//     log_stats_message(message);
//     return Plugin_Continue;
// }

