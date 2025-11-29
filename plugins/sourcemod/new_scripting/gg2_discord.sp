#include <sourcemod>
#include <ripext>
#include <sourcebanspp>
#pragma newdecls required
#define TEAM_SPEC	1
#define TEAM_1_SEC	2
#define TEAM_2_INS	3
#define max_rounds 3

char WebhookURL[1024];
char WebhookRELAY[1024];

char BAWT_AUTH_ID[64] = "STEAM_ID_STOP_IGNORING_RETVALS";

char g_cps[26] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
int g_cps_capped = 0;

int g_rounds_played = 0;

public Plugin myinfo = {
    name = "[GG2 Discord] Discord Chat Relay",
    author = "zachm",
    description = "Relays in-game chat into a Discord channel.",
    version = "0.0.1",
}

bool LoadConfig() {
    char[] sPath = new char[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, PLATFORM_MAX_PATH, "configs/discord.cfg");
    if (!FileExists(sPath)) {
        SetFailState("File Not Found: %s", sPath);
        return false;
    }
    KeyValues hConfig = new KeyValues("Discord");
    hConfig.ImportFromFile(sPath);
    hConfig.GotoFirstSubKey();
    do
    {
        hConfig.GetString("WebhookURL", WebhookURL, sizeof(WebhookURL));
        hConfig.GetString("WebhookRELAY", WebhookRELAY, sizeof(WebhookRELAY));
    } while (hConfig.GotoNextKey());
    delete hConfig;
    return true;
}

void EscapeString(char[] value, int size) {
    ReplaceString(value, size, "\\", "\\\\");
    ReplaceString(value, size, "\"", "\\\"");
    ReplaceString(value, size, "\b", "\\b");
    ReplaceString(value, size, "\t", "\\t");
    ReplaceString(value, size, "\n", "\\n");
    ReplaceString(value, size, "\f", "\\f");
    ReplaceString(value, size, "\r", "\\r");
}

void no_ats(char[] value, int size) {
    ReplaceString(value, size, "@", "©");
}

public void OnPluginStart() {
    LogMessage("[DISCORD] Started");
    if(!LoadConfig()) {
        SetFailState("Couldn't load the configuration file.");
    }
    
    HookEvent("server_addban", Event_ServerAddBan);
    HookEvent("vote_started", Event_VoteStarted);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre);
    HookEvent("player_disconnect", Event_PlayerDisconnect);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured, EventHookMode_Pre);
    HookEvent("object_destroyed", Event_ObjectDestroyed, EventHookMode_Pre);
    HookEvent("player_changename", Event_PlayerChangeName);
    AddCommandListener(Event_Say, "say");
    //AddCommandListener(Event_Slap, "sm_slap");
    //AddCommandListener(Event_Slay, "slay");
    //AddCommandListener(Event_Burn, "burn");
    AddCommandListener(Event_TeamSay, "say_team");
    //HookEvent("Medic_Revived", Event_medic_revived);
    RegAdminCmd("discordmsg", Cmd_discordmsg, ADMFLAG_ROOT, "Discord message");
}

public Action Event_medic_revived(Event event, const char[] name, bool dontBroadcast) {
    /*
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client)) {
        return;
    }
    */
    int medic_id = GetEventInt(event, "iMedic");
    int injured_id = GetEventInt(event, "iInjured");
    LogMessage("[GG2 Discord] got forward medic_revived // medic: %N // healed: %N", medic_id, injured_id);
    return Plugin_Continue;
}

public Action Event_PlayerChangeName(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client)) {
        return Plugin_Continue;
    }
    char oldname[128];
    char newname[128];
    char message[1024];
    char authID[64];
    char oldnamelink[2048];
    char newnamelink[2048];

    GetEventString(event, "oldname", oldname, sizeof(oldname));
    GetEventString(event, "newname", newname, sizeof(newname));
    GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));

    if (StrEqual(BAWT_AUTH_ID, authID)) {
        oldnamelink = oldname;
        newnamelink = newname;
    } else {
        oldnamelink = gen_tug_link(oldname, authID);
        newnamelink = gen_tug_link(newname, authID);
    }
    
    Format(message, sizeof(message), "%s Changed Name to %s", oldnamelink, newnamelink);
    send_discord(message);
    return Plugin_Continue;
}

public Action Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast) {

    char cappers[256];
    GetEventString(event, "cappers", cappers, sizeof(cappers));
    for (int i = 0; i < strlen(cappers); i++) {
        if (IsFakeClient(cappers[i])) {
            return Plugin_Continue;
        }
    }
    char message[128];
    char cap = g_cps[g_cps_capped];
    char mapname[64];
    GetCurrentMap(mapname, sizeof(mapname));
    Format(message, sizeof(message), "**CP Capped:** %s (%s)", cap, mapname);
    send_discord(message);
    g_cps_capped++;
    return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast) {
    char message[128];
    char cap = g_cps[g_cps_capped];
    char mapname[64];
    GetCurrentMap(mapname, sizeof(mapname));
    Format(message, sizeof(message), "**Cache Blown:** %s (%s)", cap, mapname);
    send_discord(message);
    g_cps_capped++;
    return Plugin_Continue;
}

/*
char gen_steam_link(char[] playerName, char[] authID) {
    char url[1024];
    char url_safe[2048];
    Format(url, 1024, "[%s](<https://steamcommunity.com/profiles/%s>)", playerName, authID);
    FormatEx(url_safe, sizeof(url_safe), "%s", url);
    EscapeString(url_safe, sizeof(url_safe));
    return url_safe;
}
*/

char[] gen_tug_link(char[] playerName, char[] authID) {
    char url[1024];
    char url_safe[2048];
    Format(url, 1024, "[%s](<https://www.tug.gg/player/%s>)", playerName, authID);
    FormatEx(url_safe, sizeof(url_safe), "%s", url);
    EscapeString(url_safe, sizeof(url_safe));
    return url_safe;
}


public void SBPP_OnBanPlayer(int iAdmin, int iTarget, int iTime, const char[] sReason) {
    char message[1024];
    Format(message, sizeof(message),"[DISCORD] SBPP_OnBanPlayer:: iAdmin: %i // iTarget: %i // iTime: %i // sReason: %s", iAdmin, iTarget, iTime, sReason);
    if (iAdmin != 0) {
        LogMessage("[DISCORD] SBPP_OnBanPlayer: %N banned %N for %i minutes", iAdmin, iTarget, iTime);
    } else {
        LogMessage("[DISCORD] SBPP_OnBanPlayer: CONSOLE banned %N for %i minutes", iTarget, iTime);
    }
    LogMessage(message);
}

public Action Event_VoteStarted(Event event, const char[] name, bool dontBroadcast) {
    char issue[128];
    char param1[128];
    int team;
    int initiator;

    GetEventString(event, "issue", issue, 128);
    GetEventString(event, "param1", param1, 128);
    team = GetEventInt(event, "team");
    initiator = GetEventInt(event, "initiator");
    LogMessage("[DISCORD] vote_started: issue: %s // param1: %s // team: %d, initiator: %d", issue, param1, team, initiator);
    return Plugin_Continue;
}

public Action Event_ServerAddBan(Event event, const char[] name, bool dontBroadcast) {
    char playerName[128];
    char networkid[128];
    char ip[128];
    char duration[128];
    char by[128];
    bool kicked;
    char discord_message[1024];
    GetEventString(event, "name", playerName, 128);
    GetEventString(event, "networkid", networkid, 128, "no_networkid_registered");
    GetEventString(event, "ip", ip, 128, "no_ip_registered");
    GetEventString(event, "duration", duration, 128, "no_duration_registered");
    GetEventString(event, "by", by, 128, "no_by_registered");
    kicked = GetEventBool(event, "kicked");
    if (StrEqual(playerName, "")) {
        LogMessage("[DISCORD] Ignoring empty playername ban (%s)", networkid);
        return Plugin_Continue;
    }
    Format(discord_message, sizeof(discord_message), "**BAN:** %s is banned by %s for %s", playerName, by, duration);
    send_discord(discord_message);
    if (kicked) {
        LogMessage("[DISCORD] %s banned %s (%s) at IP %s for %s (was kicked)", by, playerName, networkid, ip, duration);
    } else {
        LogMessage("[DISCORD] %s banned %s (%s) at IP %s for %s (was NOT kicked)", by, playerName, networkid, ip, duration);
    }
    return Plugin_Continue;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    g_cps_capped = 0;
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    g_rounds_played++;
    int winner = GetEventInt(event, "winner");
    int reason = GetEventInt(event, "reason");
    LogMessage("[DISCORD] got round_end reason: %d", reason);
    //char reason[64];
    //GetEventString(event, "reason", reason, sizeof(reason));
    //LogMessage("[DISCORD] got round_end reason: %s", reason);
    char round_message[1024];
    char mapname[32];
    GetCurrentMap(mapname, sizeof(mapname));
    LogMessage("[DISCORD] round ended, winner: %i", winner);
    if (winner == TEAM_1_SEC) {
        Format(round_message, sizeof(round_message),"**ROUND END:** __Security Forces WIN!__ (%i/%i %s)", g_rounds_played, max_rounds, mapname);
    } else {
        Format(round_message, sizeof(round_message),"**ROUND END:** __Insurgents Forces WIN!__ (%i/%i %s)", g_rounds_played, max_rounds, mapname);
    }
    send_discord(round_message);
    return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client == 0) {
        return Plugin_Continue;
    }
    if (IsFakeClient(client)) {
        return Plugin_Continue;
    }
    char authID[64];
    char message[1024];
    char playerName[128];
    char link[2048];
    char disconnect_reason[128];
    GetEventString(event, "reason", disconnect_reason, sizeof(disconnect_reason));
    GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));
    GetClientName(client, playerName, sizeof(playerName));
    //link = gen_steam_link(playerName, authID);
    link = gen_tug_link(playerName, authID);
    Format(message, sizeof(message), "%s Left the server (%s)", link, disconnect_reason);
    send_discord(message);
    return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    int team = GetEventInt(event, "team");
    if (team == TEAM_2_INS) {
        return Plugin_Continue;
    }
    char joined_team[16];
    if (team == TEAM_1_SEC) {
        joined_team = "Security Forces";
    } else {
        joined_team = "Spectators";
    }
    char authID[64];
    char message[1024];
    char playerName[128];
    char link[2048];
    GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));
    GetClientName(client, playerName, sizeof(playerName));
    //link = gen_steam_link(playerName, authID);
    link = gen_tug_link(playerName, authID);
    Format(message, sizeof(message), "%s Joined %s", link, joined_team);
    send_discord(message);
    return Plugin_Continue;
}

public void OnMapStart(){
    g_rounds_played = 0;
    char mapname[32];
    char strMsg[1024];
    GetCurrentMap(mapname, sizeof(mapname));
    Format(strMsg, 1024, "**Map Change:** __%s__", mapname);
    send_discord(strMsg);
}

public Action Event_Slap(int client, const char[] command, int argc) {
    char message[1024];
    char message_entire[4096];
    GetCmdArgString(message, sizeof(message));

    StripQuotes(message);
    char authID[64];
    char playerName[128];
    char link[2048];
    GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));
    GetClientName(client, playerName, sizeof(playerName));
    //link = gen_steam_link(playerName, authID);
    link = gen_tug_link(playerName, authID);
    Format(message_entire, sizeof(message_entire), "%s **(SLAPPED):** %s",link, message);
    send_discord(message_entire);
    return Plugin_Continue;
}

public Action Event_Slay(int client, const char[] command, int argc) {
    char message[1024];
    char message_entire[4096];
    GetCmdArgString(message, sizeof(message));

    StripQuotes(message);
    char authID[64];
    char playerName[128];
    char link[2048];
    GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));
    GetClientName(client, playerName, sizeof(playerName));
    //link = gen_steam_link(playerName, authID);
    link = gen_tug_link(playerName, authID);
    Format(message_entire, sizeof(message_entire), "%s **(SLAYED):** %s",link, message);
    send_discord(message_entire);
    return Plugin_Continue;
}

public Action Event_Burn(int client, const char[] command, int argc) {
    char message[1024];
    char message_entire[4096];
    GetCmdArgString(message, sizeof(message));

    StripQuotes(message);
    char authID[64];
    char playerName[128];
    char link[2048];
    GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));
    GetClientName(client, playerName, sizeof(playerName));
    //link = gen_steam_link(playerName, authID);
    link = gen_tug_link(playerName, authID);
    Format(message_entire, sizeof(message_entire), "%s **(BURNED):** %s",link, message);
    send_discord(message_entire);
    return Plugin_Continue;
}

public Action Event_TeamSay(int client, const char[] command, int argc) {
    char message[1024];
    char message_entire[4096];
    GetCmdArgString(message, sizeof(message));
    
    if ((StrContains(message, "!", false) == 0) && (StrContains(message, "!calladmin", false) != 0)) {
        return Plugin_Continue;
    }
    
    StripQuotes(message);
    char authID[64];
    char playerName[128];
    char link[2048];
    GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));
    GetClientName(client, playerName, sizeof(playerName));
    //link = gen_steam_link(playerName, authID);
    link = gen_tug_link(playerName, authID);
    Format(message_entire, sizeof(message_entire), "%s **(TEAM):** %s",link, message);
    send_discord(message_entire);
    return Plugin_Continue;
}

public Action Event_Say(int client, const char[] command, int argc) {
    if (client != 0) {
        if(!IsValidPlayer(client)) {
            return Plugin_Continue;
        }
    }
    char message[1024];
    char message_entire[4096];
    GetCmdArgString(message, sizeof(message));
    
    if ((StrContains(message, "!", false) == 0) && (StrContains(message, "!calladmin", false) != 0)) {
        return Plugin_Continue;
    }
    if (StrContains(message, "/forgive", false) == 0) {
        return Plugin_Continue;
    }
    
    StripQuotes(message);
    char link[2048];
    if (client != 0) {
        char authID[64];
        char playerName[128];
        GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));
        GetClientName(client, playerName, sizeof(playerName));
        //link = gen_steam_link(playerName, authID);
        link = gen_tug_link(playerName, authID);
    } else {
        link = "**GAWD**";
    }
    Format(message_entire, sizeof(message_entire), "%s: %s",link, message);
    if (StrContains(message, "!calladmin", false) == 0) {
        Call_Admin(client, message_entire);
        return Plugin_Continue;
    }
    send_discord(message_entire);
    return Plugin_Continue;
}

public void Call_Admin(int client, char[] message) {
    char admin_message[4096];
    no_ats(message, 4096);
    Format(admin_message, sizeof(admin_message), "<@&844952562600116254> ```%s```", message);
    send_discord_calladmin(admin_message);
}

public Action Cmd_discordmsg(int client, int args) {
    LogMessage("[DISCORD] got admin command, %N with %i args", client, args);
    char full[4096];
    GetCmdArgString(full, sizeof(full));
    LogMessage("[DISCORD] request to send message: %s", full);
    send_discord(full);
    return Plugin_Continue;
}

public any Native_send_to_discord(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    int stringLength;
    GetNativeStringLength(2, stringLength);
    char[] message = new char[stringLength + 1];
    GetNativeString(2, message, stringLength + 1); 
    char message_entire[4096];
    char link[2048];
    char authID[64];
    char playerName[128];
    GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));
    GetClientName(client, playerName, sizeof(playerName));
    //link = gen_steam_link(playerName, authID);
    if (StrEqual(BAWT_AUTH_ID, authID)) {
        link = playerName;
    } else {
        link = gen_tug_link(playerName, authID);
    }
    
    Format(message_entire, sizeof(message_entire), "%s: %s",link, message);
    send_discord(message_entire);
    return true;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("send_to_discord", Native_send_to_discord);
	return APLRes_Success;
}

public void send_discord_calladmin(char[] content) {
    //no_ats(content, 4096);
    JSONObject discord_content = new JSONObject();
    discord_content.SetString("username", "In-Game Chat");
    discord_content.SetString("content", content);
    HTTPRequest request = new HTTPRequest(WebhookRELAY);
    request.SetHeader("X-WEBHOOK-URL", WebhookURL);
    request.Post(discord_content, onRequestFinished);
    delete discord_content;
}

public void send_discord(char[] content) {
    no_ats(content, 4096);
    JSONObject discord_content = new JSONObject();
    discord_content.SetString("username", "In-Game Chat");
    discord_content.SetString("content", content);
    //discord_content.SetString("content", "okthenwtf...");
    HTTPRequest request = new HTTPRequest(WebhookRELAY);
    request.SetHeader("X-WEBHOOK-URL", WebhookURL);
    //request.Put(discord_content, onRequestFinished);
    request.Post(discord_content, onRequestFinished);
    delete discord_content;
}

public void onRequestFinished(HTTPResponse response, any value, const char[] error){
    if (response.Status != HTTPStatus_OK) {
        LogMessage("[DISCORD FAIL] Request Failed to SEND %i",response.Status);
        LogMessage("[DISCORD FAIL] ERROR: %s", error);
        return;
    }
    return;
}

public bool IsValidPlayer(int client) {
    return (0 < client <= MaxClients) && IsClientInGame(client);
}