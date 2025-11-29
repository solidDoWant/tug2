#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <discord>
#include <morecolors>
#include <dbi>

#define DMG_BURN    (1 << 3)
#define TEAM_SEC	2
#define TEAM_INS	3

public Plugin myinfo =  {
    name = "[INS GG] TeamKilling",
    author = "zachm",
    description = "TeamKill System",
    version = "0.0.2",
    url = ""
}


Database g_Database = null;
ConVar cvarBanBaseTime;
ConVar g_server_id;
GlobalForward TKForgivenForward;
GlobalForward TKAutoBanFiredForward;
bool DEBUG = false;
bool g_db_up = false;
int g_iPlayerTKCounter[MAXPLAYERS+1][3];
int g_iPlayerTKS[MAXPLAYERS+1];
int emptyarray[3] = {0,0,0};
int g_iTotalTK;
//int g_iKickTime = 5.0; // 5.0 min
int g_iKickPeriod = 600; // 5 min worth of seconds -->  10 min worth of seconds
char bawt_steam_id[64] = "STEAM_ID_STOP_IGNORING_RETVALS";

char g_amnesty_players[1024][64];
char g_offender_players[1024][64];

public void OnPluginStart() {
    LogMessage("[INS GG] TeamKilling System started");
    cvarBanBaseTime = CreateConVar("tk_ban_basetime", "5", "Base ban time (min)", FCVAR_PROTECTED);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("player_death", Event_PlayerDeath);
    RegConsoleCmd("forgive", Cmd_Forgive, "Forgive your attacker TK");
    RegConsoleCmd("пробачити", Cmd_Forgive, "Forgive in ukr");
    RegConsoleCmd("許す", Cmd_Forgive, "Forgive in ukr");
    RegConsoleCmd("原谅", Cmd_Forgive, "Forgive in chinese");
    RegConsoleCmd("простить", Cmd_Forgive, "Forgive in russ");
    RegConsoleCmd("perdonar", Cmd_Forgive, "Forgive in spanish");
    RegConsoleCmd("perdoar", Cmd_Forgive, "Forgive in portug");
    RegConsoleCmd("affetmek", Cmd_Forgive, "Forgive in turk");
    
    Database.Connect(T_Connect, "insurgency_stats");
    TKForgivenForward = new GlobalForward("TK_Forgiven", ET_Event, Param_Cell);
    TKAutoBanFiredForward = new GlobalForward("TK_AutoBan", ET_Event, Param_Cell);

    LoadTranslations("tug.phrases");
    AutoExecConfig(true, "gg2_teamkill");
}

public void OnAllPluginsLoaded() {
    g_server_id = FindConVar("gg_stats_server_id");
}

public void T_Connect(Database db, const char[] error, any data) {
    if(db == null){
        LogError("[GG2 TEAMKILL] T_Connect returned invalid Database Handle");
        //SetFailState("FAILED TO CONNECT TO M DB, BAILING");
        return;
    }
    g_Database = db;
    SQL_SetCharset(g_Database, "utf8mb4");
    g_db_up = true;
    return;
} 

public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
    if (strlen(error) != 0) {
        LogMessage("[GG2 TEAMKILL] error: %s", error);
    }
    return;
}

public void OnClientAuthorized(int client) {
    char steam_id[64];
    GetClientAuthId(client, AuthId_SteamID64, steam_id, 32);
    
    if (StrEqual(steam_id, bawt_steam_id)) {
        return;
    }
    LogMessage("[GG2 TEAMKILL] Player joined // %s", steam_id);
    if(!IsFakeClient(client) && g_Database != null) {
        if (StrEqual(steam_id, "\0") || (StrEqual(steam_id, bawt_steam_id))) {
            LogMessage("[GG2 TEAMKILL] Not Full Connect, returning");
            return;
        }

        if (player_is_offender(steam_id)) {
            LogMessage("[GG2 TEAMKILL] DISPLAY KNOWN OFFENDER TO ALL PLAYERS HERE");
            CPrintToChatAll("{fullred}[KNOWN TK OFFENDER]{common} %N joined, watch out for this dickhead", client);
        }
        
    }
}
/*
public void OnClientPostAdminCheck(int client) {
    if (!IsFakeClient(client)) {
        char steam_id[64];
        GetClientAuthId(client, AuthId_SteamID64, steam_id, 32);
        LogMessage("[GG2 TEAMKILL] Player joined // %s", steam_id);
        if (player_is_offender(steam_id)) {
            LogMessage("[GG2 TEAMKILL] DISPLAY KNOWN OFFENDER TO ALL PLAYERS HERE");
            CPrintToChatAll("{fullred}[KNOWN TK OFFENDER]{common} %N joined, watch out for this dickhead", client);
        }
    }
}
*/


public Action SendForwardTKForgiven(int client) {	// tug stats forward
	Action result;
	Call_StartForward(TKForgivenForward);
	Call_PushCell(client);
	Call_Finish(result);
	return result;
}
public Action SendForwardTKAutoBanFired(int client) {	// tug stats forward
	Action result;
	Call_StartForward(TKAutoBanFiredForward);
	Call_PushCell(client);
	Call_Finish(result);
	return result;
}


public Action run_amnesty(Handle timer) {
    if (g_db_up) {
        get_amnesty_players();
    }
    return Plugin_Continue;
}
public Action run_tks(Handle timer) {
    if (g_db_up) {
        get_offender_players();
    }
    return Plugin_Continue;
}


public void db_forgive_player(int attacker, int victim) {
    char attacker_steamid64[64];
    GetClientAuthId(attacker, AuthId_SteamID64, attacker_steamid64, sizeof(attacker_steamid64));
    char victim_steamid64[64];
    GetClientAuthId(victim, AuthId_SteamID64, victim_steamid64, sizeof(victim_steamid64));
    char query[1024];
    //Format(query, sizeof(query), "SELECT id FROM redux_players WHERE steam_id = '%s' AND server_id = '%i' LIMIT 1", g_SteamID[client], g_server_id.IntValue);
    Format(query, sizeof(query), "UPDATE redux_player_tks SET forgiven = 1 WHERE victim_id = (SELECT id FROM redux_players WHERE steam_id = '%s' AND server_id = '%i' LIMIT 1) AND attacker_id = (SELECT id FROM redux_players WHERE steam_id = '%s' AND server_id = '%i' LIMIT 1) ORDER BY id DESC limit 1", victim_steamid64, g_server_id.IntValue, attacker_steamid64, g_server_id.IntValue);
    //update redux_player_tks set forgiven = 1 where victim_id = (select id from redux_players where steam_id = '76561198853680002' and server_id = 1 limit 1) and attacker_id = (select id from redux_players where steam_id = '76561198009222027' and server_id = 1 limit 1) limit 1
    SQL_TQuery(g_Database, db_forgive_player_callback, query, attacker);
}
public void db_forgive_player_callback(Handle owner, Handle results, const char[] error, any client) {
    if(results == INVALID_HANDLE) {
        LogToFile("wtf.log", "db_forgive_player call failed");
        delete results;
        return;
    }
    LogMessage("[GG2 TEAMKILL] Forgiven was set in db for %N", client);
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
            LogMessage("[GG2 TEAMKILL] AMNESTY granted to %N", attacker_client);
        }
    }
    if (!res) {
        LogMessage("[GG2 TEAMKILL] NO AMNESTY granted to %N", attacker_client);
    }
    return res;
}

public bool player_is_offender(char[] steam_id) {
    bool res = false;
    for (int i = 0; i < sizeof(g_offender_players); i++) {
        if (StrEqual("",g_offender_players[i])) {
            break;
        }
        if (StrEqual(g_offender_players[i], steam_id)) {
            res = true;
            LogMessage("[GG2 TEAMKILL] KNOWN OFFENDER JOINED NOTICE %s", steam_id);
        }
    }
    if (!res) {
        LogMessage("[GG2 TEAMKILL] Player not a KNOWN TK OFFENDER");
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
    LogMessage("[GG2 TEAMKILL] Retreived %i TK Amnesty players for server_id %i", rows, g_server_id.IntValue);
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

public void get_offender_players() {
    char query[512];
    int now = GetTime();
    int time_cutoff = (now - 7776000);
    Format(query, sizeof(query), "SELECT DISTINCT steam_id FROM `redux_players` WHERE kills >= 500 AND (kills/tk_given) < 100 AND last_seen > %i AND server_id = '%i' ORDER BY steam_id ASC;", time_cutoff, g_server_id.IntValue);
    SQL_TQuery(g_Database, load_offender_players, query);
}

public void load_offender_players(Handle owner, Handle results, const char[] error, any client) {
    int rows = SQL_GetRowCount(results);
    LogMessage("[GG2 TEAMKILL] Retreived %i TK Offenders for server_id %i", rows, g_server_id.IntValue);
    if (rows > 0) {
        int offset = 0;
        char steamid_64[64];
        while(SQL_FetchRow(results)) {
            SQL_FetchString(results, 0, steamid_64, sizeof(steamid_64));
            g_offender_players[offset] = steamid_64;
            offset++;
        }
    }
}


public void OnMapStart() {
    int i;
    for (i = 0; i <= MAXPLAYERS; i++) {
        clear_tks(i);
    }
    CreateTimer(2.0, run_amnesty);
    CreateTimer(2.0, run_tks);
}

public void OnClientDisconnect(int client) {
    if (!IsFakeClient(client)) {
		clear_tks(client);
    }
}

public Action Cmd_Forgive(int client, any args) {
    int i;
    bool forgiven = false;
    //char chat_message[1024];
    int attacker;
    for (i = 0; i <= MAXPLAYERS; i++) {
        if (g_iPlayerTKS[i] == client) {
            attacker = i;
            LogMessage("[GG TK_AUTO_BAN] %N forgave %N, popping last entry in tk timer",client, attacker);
            g_iPlayerTKS[i] = 0;
            int j;
            for (j = 2; j >= 0; j--) {
                if (g_iPlayerTKCounter[i][j] != 0) {
                    g_iPlayerTKCounter[i][j] = 0;
                    forgiven = true;
                    SendForwardTKForgiven(client);
                    db_forgive_player(attacker, client);
                    break;
                }
            }
            if (forgiven) {
                break;
            }
        }
    }
    if (!forgiven) {
        //Format(chat_message, sizeof(chat_message), "\x07FF0000[TeamKill]\x07F8F8FF \x0700FA9A NO PLAYER TO FORGIVE!");
        CPrintToChat(client, "%T", "teamkill_noone_to_forgive", client);
        //PrintToChat(client, chat_message);
        LogMessage("[GG TK_AUTO_BAN] %N attempted to forgive but nobody was forgivable", client);
    } else {
        char discord_message[1024];
        char forgiver_name[64];
        char forgiven_name[64];
        Format(forgiver_name, sizeof(forgiver_name), "%N", client);
        Format(forgiven_name, sizeof(forgiven_name), "%N", attacker);
        FormatEx(discord_message, sizeof(discord_message), "[TK Auto-Ban] %N has forgiven %N for TK", client, attacker);
        //Format(chat_message, sizeof(chat_message), "\x07FF0000[TeamKill]\x07F8F8FF \x07FF0000%N\x0700FA9A FORGAVE\x07FFD700 %N for TKing", client, attacker);
        //PrintToChatAll(chat_message);
        CPrintToChatAll("%t", "teamkill_player_forgiven", forgiver_name, forgiven_name);
        send_to_discord(client, discord_message);
    }
    return Plugin_Handled;
}


public bool IsValidPlayer(int client){
    return (0 < client <= MaxClients) && IsClientInGame(client);
}

void clear_tks(int client) {
    g_iPlayerTKCounter[client] = emptyarray;
    g_iPlayerTKS[client] = 0;
}

void add_tk(int client, int victim) {
    int tk_inserted = -1;
    int now = GetTime();
    int i;
    g_iPlayerTKS[client] = victim;
    for (i = 0; i < 3; i++) {
        if (g_iPlayerTKCounter[client][i] == 0) {
            g_iPlayerTKCounter[client][i] = now;
            tk_inserted = i;
            break;
        }
    }
    // shift arrays if we didn't insert
    if (tk_inserted == -1) {
        g_iPlayerTKCounter[client][0] = g_iPlayerTKCounter[client][1];
        g_iPlayerTKCounter[client][1] = g_iPlayerTKCounter[client][2];
        g_iPlayerTKCounter[client][2] = now;
    }
}

int calc_tks(int client) {
    int i;
    int now = GetTime();
    int skips = 0;

    for (i = 0; i < 3; i++) {
        int span = now - g_iPlayerTKCounter[client][i];
        if (span > g_iKickPeriod) {
            skips++;
        }
        if (g_iPlayerTKCounter[client][i] == 0) {
            break;
            //return i;
        }
    }
    return i - skips;
    //return 3;
}

public bool should_log(char[] weapon) {
    return true;
    // rocket_arty kills are covered as 155 kills
    /*
    char blacklist_weapons[][] = {
        "grenade_m777_us",
        "grenade_m777_ins"
    };
    for (int i = 0; i <= sizeof(blacklist_weapons)-1; i++) {
        if (StrEqual(weapon, blacklist_weapons[i])) {
            return false;
        }
    }
    return true;
    */
}

bool should_ban(int client) {
    
    int span = g_iPlayerTKCounter[client][2] - g_iPlayerTKCounter[client][0];
    if (span < 0) {
        return false;
    }
    if (span < g_iKickPeriod) {
        return true;
    }
    return false;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    LogMessage("[GG TK_AUTO_BAN] clearing TK entries");
    int client;
    for (client = 0; client <= MaxClients; client++) {
        clear_tks(client);
    }
    return Plugin_Continue;
}
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    char weapon[32];
    GetEventString(event, "weapon", weapon, sizeof(weapon));
    if ((StrContains(weapon, "cache", false) != -1) || (!should_log(weapon))) {
        return Plugin_Continue;
    }
    int damagetype = GetEventInt(event, "damagebits");
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (victim == 0) {
        return Plugin_Continue;
    }
    if (IsFakeClient(victim)) return Plugin_Continue;
    if (!IsValidPlayer(attacker)) return Plugin_Continue;
    AdminId admin = GetUserAdmin(attacker);

    if (victim == attacker) {
        return Plugin_Continue;
    }
    if (damagetype & DMG_BURN ) {
        if (!StrEqual("weapon_flamethrower", weapon)) {
            return Plugin_Continue;
        }
    }
    
    int ateam = (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) ? GetClientTeam(attacker) : -1);
    int vteam = (IsValidPlayer(victim) ? GetClientTeam(victim) : -1);

    if (vteam == TEAM_INS || ateam == TEAM_INS) return Plugin_Continue;

    if (vteam == ateam) {
        char strAuth[64];
        GetClientAuthId(attacker, AuthId_Steam2, strAuth, sizeof(strAuth));

        g_iTotalTK++;

        LogMessage("[GG TK_AUTO_BAN] %N killed a teammate (%N)", attacker, victim);
        
        char d_message[192];

        if ((admin != INVALID_ADMIN_ID) || (has_amnesty(attacker))) {
            Format(d_message, sizeof(d_message), "__***TK'd***__ %N (%s) (AMNESTY GRANTED)", victim, weapon);
            char amnesty_attacker[64];
            Format(amnesty_attacker, sizeof(amnesty_attacker), "%N", attacker);
            CPrintToChat(victim,"%T","teamkiller_has_amnesty",victim,amnesty_attacker);
        } else {
            Format(d_message, sizeof(d_message), "__***TK'd***__ %N (%s)", victim, weapon);
        }
        send_to_discord(attacker, d_message);
        if ((admin != INVALID_ADMIN_ID) || (has_amnesty(attacker))) {
            return Plugin_Continue;
        }
        
        add_tk(attacker, victim);
        char chatMessage[256];
        if (should_ban(attacker)) {
            SendForwardTKAutoBanFired(attacker);
            char message[96];
            int playerId = GetClientUserId(attacker);
            LogMessage("[GG TK_AUTO_BAN] auto banning %N // %i / %i / %i // %d ", attacker, g_iPlayerTKCounter[attacker][0], g_iPlayerTKCounter[attacker][1], g_iPlayerTKCounter[attacker][2],cvarBanBaseTime.IntValue);
            if (!DEBUG) {
                Format(message, sizeof(message), "Banned for %i minutes (TK AUTO-BAN)", cvarBanBaseTime.IntValue);
            } else {
                Format(message, sizeof(message), "Banned for %i minutes (TK AUTO-BAN) !!DEBUG, not actually banned!!", cvarBanBaseTime.IntValue);
            }
            send_to_discord(attacker, message);
            if (!DEBUG) {
                ServerCommand("sm_ban #%d %d Team Killing", playerId, cvarBanBaseTime.IntValue);
                //Format(chatMessage, sizeof(chatMessage), "\x07FF0000[TeamKill]\x0700FA9A %N WAS BANNED 5min FOR TKs", attacker);
                //PrintToChatAll(chatMessage);
                char attacker_name[64];
                Format(attacker_name, sizeof(attacker_name), "%N", attacker);
                CPrintToChatAll("%t", "teamkill_player_banned", attacker_name);
            } else {
                
                Format(chatMessage, sizeof(chatMessage), "\x07FF0000[TeamKill]\x0700FA9A BE MORE CAREFUL, IF THIS WASN'T DEBUG, YOU WOULD HAVE BEEN BANNED 5min FOR TKs");
                PrintToChat(attacker, chatMessage);
                Format(chatMessage, sizeof(chatMessage), "\x07FF0000[TeamKill]\x0700FA9A IF THIS WASN'T DEBUG, %N WOULD HAVE BEEN BANNED 5min FOR TKs", attacker);
                PrintToChatAll(chatMessage);
            }
            clear_tks(attacker);
        } else {
            int tk_count = calc_tks(attacker);
            //Format(chatMessage, sizeof(chatMessage),"\x07FF0000[TeamKill]\x0700FA9A BE MORE CAREFUL, TK COUNT: %i/3", tk_count);
            //PrintToChat(attacker, chatMessage);
            if (tk_count == 1) {
                ForcePlayerSuicide(attacker);
            }
            CPrintToChat(attacker, "%T", "teamkill_be_careful", attacker, tk_count+1);
            //PrintToChat(victim, "\x07FF0000[TeamKill]\x07F8F8FF Type\x0700FA9A /forgive\x07F8F8FF in your chat to forgive your TKer. Otherwise, they may be banned.");
            CPrintToChat(victim, "%T", "teamkill_how_to_forgive", victim);
        }

    }
    return Plugin_Continue;
}