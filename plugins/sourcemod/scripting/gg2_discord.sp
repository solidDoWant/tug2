#include <sourcemod>
#include <ripext>
#include <mapnames>
#include <workshopmaps>
#include <steamids>
// #include <sourcebanspp>  // SourceBansPP is not currently in use
#pragma newdecls required
#define TEAM_SPEC                1
#define TEAM_1_SEC               2
#define TEAM_2_INS               3
#define MAX_QUEUE_SIZE           100
#define MAX_DISCORD_MESSAGE_SIZE 2000
#define MAX_MESSAGE_SIZE         MAX_DISCORD_MESSAGE_SIZE

char  WebhookURL[1024];
char  AdminRoleID[32];

char  BAWT_AUTH_ID[32] = "STEAM_ID_STOP_IGNORING_RETVALS";

int   g_cps_capped     = 0;
int   g_rounds_played  = 0;

// mp_maxrounds, looked up rather than hard-coded. This used to be "#define max_rounds 3", which is
// why round-end reported "(4/3 mapname)" on a server running mp_maxrounds 5 - the numerator counted
// real rounds while the denominator was a constant that had nothing to do with the server config.
// Resolved once at load: mp_maxrounds is a stock cvar and always exists, so a null here means the
// lookup itself failed, not that the server is unconfigured.
ConVar g_cvMaxRounds = null;

// SteamID64 -> GetEngineTime() of bans already posted from OnBanClient/OnBanIdentity. The engine's
// server_addban event fires for the same ban a moment later; this is how it knows to stay quiet.
StringMap g_RecentBans = null;
#define BAN_DEDUPE_WINDOW 10.0

// Message batching queue (circular buffer)
char  g_MessageQueue[MAX_QUEUE_SIZE][MAX_MESSAGE_SIZE];
bool  g_MessagePriorities[MAX_QUEUE_SIZE];
bool  g_MessageDeleted[MAX_QUEUE_SIZE];
int   g_QueueHead          = 0;
int   g_QueueTail          = 0;
int   g_QueueCount         = 0;

// Rate limiting
bool  g_IsRateLimited      = false;
float g_RateLimitResetTime = 0.0;

// Retry logic
char  g_PendingBatch[MAX_MESSAGE_SIZE];
int   g_PendingBatchRetries = 0;
bool  g_HasPendingBatch     = false;
bool  g_RequestInFlight     = false;    // Prevents concurrent requests
#define MAX_RETRIES 3

public Plugin myinfo =
{
    name        = "[GG2 Discord] Discord Chat Relay",
    author      = "zachm",
    description = "Relays in-game chat into a Discord channel.",
    version     = "0.0.1",
};

bool LoadConfig()
{
    char[] sPath = new char[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, PLATFORM_MAX_PATH, "configs/discord.cfg");
    if (!FileExists(sPath))
    {
        LogError("[DISCORD] Configuration file not found: %s", sPath);
        return false;
    }

    // NOTE: Use an SMC parser rather than KeyValues here. KeyValues auto-types a
    // purely-numeric value as a 32-bit int, so a 64-bit Discord snowflake read
    // back via GetString is truncated to INT_MAX (2147483647) - that silently
    // breaks AdminRoleID. SMC preserves the raw string value.
    WebhookURL[0]     = '\0';
    AdminRoleID[0]    = '\0';

    SMCParser parser  = new SMCParser();
    parser.OnKeyValue = Config_OnKeyValue;
    SMCError err      = parser.ParseFile(sPath);

    if (err != SMCError_Okay)
    {
        char errMsg[256];
        parser.GetErrorString(err, errMsg, sizeof(errMsg));
        delete parser;
        LogError("[DISCORD] Failed to parse configuration file: %s (%s)", sPath, errMsg);
        return false;
    }

    delete parser;

    if (StrEqual(WebhookURL, ""))
    {
        LogError("[DISCORD] WebhookURL is not set in configuration file: %s", sPath);
        return false;
    }

    if (StrEqual(AdminRoleID, ""))
    {
        LogError("[DISCORD] AdminRoleID is not set in configuration file: %s", sPath);
        return false;
    }

    return true;
}

public SMCResult Config_OnKeyValue(SMCParser smc, const char[] key, const char[] value, bool key_quotes, bool value_quotes)
{
    if (StrEqual(key, "WebhookURL", false))
    {
        strcopy(WebhookURL, sizeof(WebhookURL), value);
    }
    else if (StrEqual(key, "AdminRoleID", false))
    {
        strcopy(AdminRoleID, sizeof(AdminRoleID), value);
    }

    return SMCParse_Continue;
}

void no_ats(char[] value, int size)
{
    ReplaceString(value, size, "@", "©");
}

public void OnPluginStart()
{
    LogMessage("[DISCORD] Started");
    if (!LoadConfig())
    {
        SetFailState("Couldn't load the configuration file.");
        return;
    }

    g_cvMaxRounds = FindConVar("mp_maxrounds");
    if (g_cvMaxRounds == null)
        LogError("[DISCORD] mp_maxrounds not found - round end will report the round limit as ?");

    // Display names for the map. configs/mapnames.cfg is only the exceptions - see mapnames.inc for
    // why almost every name has to be derived from the filename rather than looked up.
    MapNames_Load();

    // Which workshop item each map came from, so the map change message can link it. Built from the
    // workshop directory once; see workshopmaps.inc.
    WorkshopMaps_Load();

    HookEvent("server_addban", Event_ServerAddBan);
    g_RecentBans = new StringMap();
    HookEvent("vote_started", Event_VoteStarted);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre);
    HookEvent("player_disconnect", Event_PlayerDisconnect);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("controlpoint_captured", Event_ControlPointCaptured, EventHookMode_Pre);
    HookEvent("object_destroyed", Event_ObjectDestroyed, EventHookMode_Pre);
    HookEvent("player_changename", Event_PlayerChangeName);
    AddCommandListener(Event_Say, "say");
    AddCommandListener(Event_Slap, "sm_slap");
    AddCommandListener(Event_Slay, "slay");
    AddCommandListener(Event_Burn, "burn");
    AddCommandListener(Event_TeamSay, "say_team");
    RegAdminCmd("discordmsg", Cmd_discordmsg, ADMFLAG_ROOT, "Discord message");

    // Start message batching timer (runs every 2 seconds)
    CreateTimer(2.0, Timer_ProcessMessageQueue, _, TIMER_REPEAT);
    LogMessage("[DISCORD] Message batching enabled (2s intervals, max queue: %d)", MAX_QUEUE_SIZE);
}

public Action Event_PlayerChangeName(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client)) return Plugin_Continue;

    char oldname[128];
    GetEventString(event, "oldname", oldname, sizeof(oldname));

    char newnamelink[256];
    gen_tug_link(client, newnamelink, sizeof(newnamelink));

    char message[1024];
    Format(message, sizeof(message), "%s Changed Name to %s", oldname, newnamelink);
    send_discord(message, sizeof(message));

    return Plugin_Continue;
}

void HandleObjectiveProgress(const char[] actionLabel)
{
    char cap = 'A' + g_cps_capped;

    char mapname[128];
    MapNames_GetCurrent(mapname, sizeof(mapname));

    char message[192];
    Format(message, sizeof(message), "**%s:** %c (%s)", actionLabel, cap, mapname);
    send_discord(message, sizeof(message));

    g_cps_capped++;
}

public Action Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    // Skip if a bot capped
    char cappers[256];
    GetEventString(event, "cappers", cappers, sizeof(cappers));

    for (int i = 0; i < strlen(cappers); i++)
    {
        if (IsFakeClient(view_as<int>(cappers[i])))
        {
            return Plugin_Continue;
        }
    }

    HandleObjectiveProgress("CP Capped");
    return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
    HandleObjectiveProgress("Cache Blown");
    return Plugin_Continue;
}

void gen_steam_link(int client, char[] url_safe, int max_size)
{
    char authID[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID)) || StrEqual(BAWT_AUTH_ID, authID))
    {
        Format(url_safe, max_size, "%N", client);
        return;
    }

    Format(url_safe, max_size, "[%N](<https://steamcommunity.com/profiles/%s>)", client, authID);
}

void gen_tug_link(int client, char[] url_safe, int max_size)
{
    // char authID[64];
    // GetClientAuthId(client, AuthId_SteamID64, authID, sizeof(authID));

    // char playerName[128];
    // GetClientName(client, playerName, sizeof(playerName));

    // Format(url_safe, max_size, "[%s](<https://www.tug.gg/player/%s>)", playerName, authID);

    // Use the steam profile link until site is back online
    gen_steam_link(client, url_safe, max_size);
}

// SourceBansPP is not currently in use
// public void SBPP_OnBanPlayer(int iAdmin, int iTarget, int iTime, const char[] sReason)
// {
//     char message[1024];
//     Format(message, sizeof(message), "[DISCORD] SBPP_OnBanPlayer:: iAdmin: %i // iTarget: %i // iTime: %i // sReason: %s", iAdmin, iTarget, iTime, sReason);
//     if (iAdmin != 0)
//     {
//         LogMessage("[DISCORD] SBPP_OnBanPlayer: %N banned %N for %i minutes", iAdmin, iTarget, iTime);
//     }
//     else {
//         LogMessage("[DISCORD] SBPP_OnBanPlayer: CONSOLE banned %N for %i minutes", iTarget, iTime);
//     }
//     LogMessage(message);
// }
public Action Event_VoteStarted(Event event, const char[] name, bool dontBroadcast)
{
    char issue[128];
    GetEventString(event, "issue", issue, 128);

    // WTF is param1?
    char param1[128];
    GetEventString(event, "param1", param1, 128);

    int team      = GetEventInt(event, "team");
    int initiator = GetEventInt(event, "initiator");

    LogMessage("[DISCORD] vote_started: issue: %s // param1: %s // team: %d, initiator: %d", issue, param1, team, initiator);

    return Plugin_Continue;
}

// ---------------------------------------------------------------------------------------------
// Bans
// ---------------------------------------------------------------------------------------------
//
// Bans used to be reported only from the engine's server_addban event, and that event has no
// player name whenever the player is kicked before the engine records the ban - which is every
// !ban of a connected player, because core kicks first and then issues banid. Those were all
// dropped ("Ignoring empty playername ban"), so admin bans never reached Discord; only the
// team-kill auto-bans of players who stayed connected did. Found on main 2026-09-23.
//
// SourceMod's OnBanClient/OnBanIdentity fire before the kick, with the client still valid and
// the admin and reason attached, so they are now the primary source. server_addban remains as a
// fallback for bans SourceMod never sees - the native vote kick and a raw `banid` over RCON -
// and is suppressed for a SteamID those forwards have just reported.

public Action OnBanClient(int client, int time, int flags, const char[] reason, const char[] kick_message, const char[] command, any source)
{
    if (IsFakeClient(client)) return Plugin_Continue;

    char target[256];
    gen_steam_link(client, target, sizeof(target));

    char steamid64[32];
    if (GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64)))
        MarkBanReported(steamid64);

    PostBan(target, time, reason, source, (flags & BANFLAG_IP) != 0);
    return Plugin_Continue;
}

public Action OnBanIdentity(const char[] identity, int time, int flags, const char[] reason, const char[] command, any source)
{
    char target[256];
    char steamid64[32];

    if (!(flags & BANFLAG_IP) && SteamIdTo64(identity, steamid64, sizeof(steamid64)))
    {
        // Not connected, so there is no name to show - link the id itself to the profile.
        Format(target, sizeof(target), "[%s](<https://steamcommunity.com/profiles/%s>)", identity, steamid64);
        MarkBanReported(steamid64);
    }
    else
    {
        strcopy(target, sizeof(target), identity);
    }

    PostBan(target, time, reason, source, (flags & BANFLAG_IP) != 0);
    return Plugin_Continue;
}

void PostBan(const char[] target, int minutes, const char[] reason, any source, bool byIP)
{
    char admin[256];
    int  adminClient = view_as<int>(source);
    if (adminClient >= 1 && adminClient <= MaxClients && IsClientInGame(adminClient) && !IsFakeClient(adminClient))
        gen_steam_link(adminClient, admin, sizeof(admin));
    else
        strcopy(admin, sizeof(admin), "Console");

    char duration[64];
    FormatBanDuration(minutes, duration, sizeof(duration));

    char message[MAX_MESSAGE_SIZE];
    Format(message, sizeof(message), "**BAN:** %s%s banned by %s %s", target, byIP ? " (IP)" : "", admin, duration);

    // basebans passes the reason as typed, so a quoted reason arrives with its quotes attached.
    char text[512];
    strcopy(text, sizeof(text), reason);
    TrimString(text);
    StripQuotes(text);
    TrimString(text);

    if (text[0] != '\0')
        Format(message, sizeof(message), "%s - \"%s\"", message, text);

    send_discord(message, sizeof(message));
}

void MarkBanReported(const char[] steamid64)
{
    g_RecentBans.SetValue(steamid64, GetEngineTime());
}

bool WasBanReported(const char[] steamid64)
{
    float when;
    return g_RecentBans.GetValue(steamid64, when) && GetEngineTime() - when < BAN_DEDUPE_WINDOW;
}

// "for 8 hours", "for 1 day", "permanently". Exact multiples only, so 90 stays "90 minutes".
void FormatBanDuration(int minutes, char[] buffer, int maxlen)
{
    if (minutes <= 0)
    {
        strcopy(buffer, maxlen, "permanently");
        return;
    }

    int    amount = minutes;
    char   unit[8] = "minute";
    if (minutes % 1440 == 0)    { amount = minutes / 1440; unit = "day"; }
    else if (minutes % 60 == 0) { amount = minutes / 60;   unit = "hour"; }

    Format(buffer, maxlen, "for %d %s%s", amount, unit, amount == 1 ? "" : "s");
}

public Action Event_ServerAddBan(Event event, const char[] name, bool dontBroadcast)
{
    char networkid[64];
    GetEventString(event, "networkid", networkid, sizeof(networkid));

    char steamid64[32];
    bool hasSteamId = SteamIdTo64(networkid, steamid64, sizeof(steamid64));

    if (hasSteamId && WasBanReported(steamid64))
        return Plugin_Continue;

    char playerName[128];
    GetEventString(event, "name", playerName, sizeof(playerName));

    char target[256];
    if (hasSteamId)
        Format(target, sizeof(target), "[%s](<https://steamcommunity.com/profiles/%s>)",
               playerName[0] != '\0' ? playerName : networkid, steamid64);
    else if (playerName[0] != '\0')
        strcopy(target, sizeof(target), playerName);
    else
        strcopy(target, sizeof(target), networkid);

    char by[128];
    GetEventString(event, "by", by, sizeof(by), "Console");

    // Already reads "for 60.00 minutes" / "permanently" - the old message added its own "for".
    char duration[64];
    GetEventString(event, "duration", duration, sizeof(duration));

    char message[MAX_MESSAGE_SIZE];
    Format(message, sizeof(message), "**BAN:** %s banned by %s %s", target, by, duration);
    send_discord(message, sizeof(message));

    LogMessage("[DISCORD] %s banned %s (%s) %s (not seen by SourceMod)", by, playerName, networkid, duration);
    return Plugin_Continue;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // State reset
    g_cps_capped = 0;
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_rounds_played++;

    int  winner           = GetEventInt(event, "winner");
    char winning_team[16] = "Insurgent";
    if (winner == TEAM_1_SEC)
    {
        winning_team = "Security";
    }

    char mapname[128];
    MapNames_GetCurrent(mapname, sizeof(mapname));

    // mp_maxrounds 0 means "no limit", so print the count on its own rather than "4/0".
    int max_rounds = (g_cvMaxRounds != null) ? g_cvMaxRounds.IntValue : -1;

    char round_progress[16];
    if (max_rounds > 0) Format(round_progress, sizeof(round_progress), "%i/%i", g_rounds_played, max_rounds);
    else if (max_rounds == 0) Format(round_progress, sizeof(round_progress), "%i", g_rounds_played);
    else Format(round_progress, sizeof(round_progress), "%i/?", g_rounds_played);

    char round_message[1024];
    Format(round_message, sizeof(round_message), "**ROUND END:** __%s Forces WIN!__ (%s %s)", winning_team, round_progress, mapname);
    send_discord(round_message, sizeof(round_message));

    return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client == 0) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;

    char disconnect_reason[128];
    GetEventString(event, "reason", disconnect_reason, sizeof(disconnect_reason));

    char playerLink[256];
    gen_tug_link(client, playerLink, sizeof(playerLink));

    char message[1024];
    Format(message, sizeof(message), "%s Left the server (%s)", playerLink, disconnect_reason);
    send_discord(message, sizeof(message));

    return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client)) return Plugin_Continue;

    // FILTER ON BOTS, NOT ON TEAM. This used to be "if (team == TEAM_2_INS) return", which is only
    // a bot filter by coincidence: insurgents are the bots in checkpoint. Survival swaps the sides -
    // players are insurgents, bots are security - so that line silenced every human join and let the
    // entire bot team through instead, once per respawn wave, each one rendering as a bare
    // " Joined Security Forces" because a bot has no Steam id and no name yet at player_team time.
    // Event_PlayerDisconnect above already filters this way; this is the same test.
    if (IsFakeClient(client)) return Plugin_Continue;

    int  team             = GetEventInt(event, "team");
    char joined_team[20]  = "Spectators";    // "Insurgent Forces" is 16 chars, so not [16]
    if (team == TEAM_1_SEC)      joined_team = "Security Forces";
    else if (team == TEAM_2_INS) joined_team = "Insurgent Forces";

    char link[256];
    gen_tug_link(client, link, sizeof(link));

    // player_team fires before the name is set on a first connect, so %N inside the link can come
    // back empty and leave the message starting with a space. The event carries the name for exactly
    // this reason - use it rather than posting a nameless line.
    if (link[0] == '\0' || StrContains(link, "[]") == 0)
    {
        char eventName[MAX_NAME_LENGTH];
        event.GetString("name", eventName, sizeof(eventName));
        if (eventName[0] == '\0') return Plugin_Continue;
        strcopy(link, sizeof(link), eventName);
    }

    char message[1024];
    Format(message, sizeof(message), "%s Joined %s", link, joined_team);
    send_discord(message, sizeof(message));

    return Plugin_Continue;
}

public void OnMapStart()
{
    g_rounds_played = 0;

    // The only message that carries the filename as well as the display name: this is the one an
    // admin reads to find out what to type into changelevel or a vote, and "District Night" is not
    // that. It is also where the workshop link belongs - the filename is what identifies the item,
    // and linking it answers "which item is this" without repeating a URL every round. The messages
    // that recur - round end, captures - print the display name alone.
    char mapfile[128], mapname[128];
    GetCurrentMap(mapfile, sizeof(mapfile));
    MapNames_Get(mapfile, mapname, sizeof(mapname));

    char url[192];
    bool linked = WorkshopMaps_GetUrl(mapfile, url, sizeof(url));

    char strMsg[1024];
    if (linked) Format(strMsg, 1024, "**Map Change:** __%s__ ([%s](%s))", mapname, mapfile, url);
    else if (!StrEqual(mapname, mapfile)) Format(strMsg, 1024, "**Map Change:** __%s__ (%s)", mapname, mapfile);
    else Format(strMsg, 1024, "**Map Change:** __%s__", mapname);
    send_discord(strMsg, sizeof(strMsg));
}

Action HandleAdminAction(int client, const char[] actionLabel)
{
    if (!IsValidPlayer(client)) return Plugin_Continue;

    char message[1024];
    GetCmdArgString(message, sizeof(message));
    StripQuotes(message);

    char link[256];
    gen_tug_link(client, link, sizeof(link));

    char message_entire[2048];
    Format(message_entire, sizeof(message_entire), "%s **(%s):** %s", link, actionLabel, message);
    send_discord(message_entire, sizeof(message_entire));

    return Plugin_Continue;
}

public Action Event_Slap(int client, const char[] command, int argc)
{
    return HandleAdminAction(client, "SLAPPED");
}

public Action Event_Slay(int client, const char[] command, int argc)
{
    return HandleAdminAction(client, "SLAYED");
}

public Action Event_Burn(int client, const char[] command, int argc)
{
    return HandleAdminAction(client, "BURNED");
}

Action HandleChatMessage(int client, const char[] prefix)
{
    if (!IsValidPlayer(client)) return Plugin_Continue;

    char message[1024];
    GetCmdArgString(message, sizeof(message));
    StripQuotes(message);

    if (StrEqual(message, "")) return Plugin_Continue;
    if (StrEqual(message, "/forgive", false)) return Plugin_Continue;

    char link[256];
    gen_tug_link(client, link, sizeof(link));

    char message_entire[2048];
    Format(message_entire, sizeof(message_entire), "%s%s %s", link, prefix, message);

    if (StrContains(message, "!calladmin", false) == 0)
    {
        Call_Admin(client, message_entire, sizeof(message_entire));
        return Plugin_Continue;
    }

    send_discord(message_entire, sizeof(message_entire));
    return Plugin_Continue;
}

public Action Event_TeamSay(int client, const char[] command, int argc)
{
    return HandleChatMessage(client, " **(TEAM):**");
}

public Action Event_Say(int client, const char[] command, int argc)
{
    return HandleChatMessage(client, ":");
}

public void Call_Admin(int client, char[] message, int max_size)
{
    char admin_message[4096];
    no_ats(message, max_size);
    // This will @ the admin role in Discord
    Format(admin_message, sizeof(admin_message), "<@&%s> ```%s```", AdminRoleID, message);
    send_discord_calladmin(admin_message, sizeof(admin_message));
}

public Action Cmd_discordmsg(int client, int args)
{
    LogMessage("[DISCORD] got admin command, %N with %i args", client, args);

    char full[4096];
    GetCmdArgString(full, sizeof(full));

    LogMessage("[DISCORD] request to send message: %s", full);
    send_discord(full, sizeof(full));

    return Plugin_Continue;
}

public any Native_send_to_discord(Handle plugin, int numParams)
{
    int  client = GetNativeCell(1);

    char link[256];
    gen_tug_link(client, link, sizeof(link));

    int stringLength;
    GetNativeStringLength(2, stringLength);

    int maxMessageSize = stringLength + 1;
    char[] message     = new char[maxMessageSize];
    GetNativeString(2, message, maxMessageSize);

    char message_entire[2048];
    Format(message_entire, sizeof(message_entire), "%s: %s", link, message);
    send_discord(message_entire, sizeof(message_entire));

    return true;
}

public any Native_discord_player_link(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    char link[256];
    gen_tug_link(client, link, sizeof(link));
    SetNativeString(2, link, GetNativeCell(3));

    return true;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("send_to_discord", Native_send_to_discord);
    CreateNative("discord_player_link", Native_discord_player_link);
    return APLRes_Success;
}

public void send_discord_calladmin(char[] content, int maxSize)
{
    send_discord_raw(content, maxSize, true, true);
}

public void send_discord(char[] content, int maxSize)
{
    send_discord_raw(content, maxSize, false, false);
}

public void send_discord_raw(char[] content, int maxSize, bool allowDiscordAts, bool isPriority)
{
    if (!allowDiscordAts)
    {
        no_ats(content, maxSize);
    }

    // Queue the message instead of sending directly
    QueueDiscordMessage(content, isPriority);
}

void SendDiscordMessageDirect(const char[] content)
{
    // Mark request as in-flight to prevent concurrent sends
    g_RequestInFlight          = true;

    JSONObject discord_content = new JSONObject();
    discord_content.SetString("username", "In-Game Chat");
    discord_content.SetString("content", content);

    // Restrict (and enable) mentions to the admin role only. Webhook role
    // mentions are left unresolved and render as "@unknown-role" unless the
    // role is explicitly listed in allowed_mentions. Every non-calladmin
    // message is already run through no_ats(), so the admin role is the only
    // mention the plugin ever emits.
    JSONObject allowed_mentions = new JSONObject();
    JSONArray  allowed_roles    = new JSONArray();
    allowed_roles.PushString(AdminRoleID);
    allowed_mentions.Set("roles", allowed_roles);
    discord_content.Set("allowed_mentions", allowed_mentions);

    HTTPRequest request = new HTTPRequest(WebhookURL);
    request.SetHeader("Content-Type", "application/json");
    request.Post(discord_content, onRequestFinished);

    delete allowed_roles;
    delete allowed_mentions;
    delete discord_content;
}

public void onRequestFinished(HTTPResponse response, any value, const char[] error)
{
    // Clear in-flight flag first (always, regardless of success/failure)
    g_RequestInFlight = false;

    if (response.Status >= 200 && response.Status < 300)
    {
        // Success - clear pending batch and reset retry counter
        g_HasPendingBatch     = false;
        g_PendingBatchRetries = 0;

        // Check if we're getting close to rate limit
        char remaining[32];
        if (response.GetHeader("X-RateLimit-Remaining", remaining, sizeof(remaining)))
        {
            int remainingRequests = StringToInt(remaining);
            if (remainingRequests <= 2)
            {
                LogMessage("[DISCORD] Warning: Only %d requests remaining before rate limit", remainingRequests);
            }
        }
        return;
    }

    // Handle fatal errors that could result in Discord bans if repeated
    if (response.Status == HTTPStatus_Unauthorized || response.Status == HTTPStatus_Forbidden || response.Status == HTTPStatus_NotFound)
    {
        char errorMsg[256];
        Format(errorMsg, sizeof(errorMsg), "Discord webhook failed with HTTP %d. Check webhook configuration to prevent ban.", response.Status);
        SetFailState(errorMsg);
        return;
    }

    // Check for rate limiting (don't count as failure, will retry automatically)
    if (response.Status == HTTPStatus_TooManyRequests)
    {
        char resetAfter[32];
        if (response.GetHeader("X-RateLimit-Reset-After", resetAfter, sizeof(resetAfter)))
        {
            float delaySeconds   = StringToFloat(resetAfter);
            g_RateLimitResetTime = GetGameTime() + delaySeconds + 1.0;    // Add 1 second buffer
            g_IsRateLimited      = true;
            LogMessage("[DISCORD] Rate limited! Waiting %.1f seconds before resuming", delaySeconds);
        }
        else
        {
            // Fallback: wait 60 seconds if header not available
            g_RateLimitResetTime = GetGameTime() + 60.0;
            g_IsRateLimited      = true;
            LogMessage("[DISCORD] Rate limited! Waiting 60 seconds (default) before resuming");
        }
        return;
    }

    // Handle retries for other failures (5xx errors, network errors, etc.)
    LogMessage("[DISCORD FAIL] Request Failed to SEND %i", response.Status);
    LogMessage("[DISCORD FAIL] ERROR: %s", error);

    if (!g_HasPendingBatch) return;

    g_PendingBatchRetries++;

    if (g_PendingBatchRetries < MAX_RETRIES)
    {
        LogMessage("[DISCORD] Will retry batch on next timer cycle (attempt %d/%d)", g_PendingBatchRetries + 1, MAX_RETRIES);
        return;
    }

    LogMessage("[DISCORD] Max retries (%d) reached, dropping batch", MAX_RETRIES);
    g_HasPendingBatch     = false;
    g_PendingBatchRetries = 0;
}

public bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

// ============================================================================
// Message Batching Timer
// ============================================================================
public Action Timer_ProcessMessageQueue(Handle timer)
{
    // Check if a request is already in-flight (wait for response before sending next)
    if (g_RequestInFlight) return Plugin_Continue;

    // Check if we're rate limited
    if (g_IsRateLimited)
    {
        float currentTime = GetGameTime();
        // Still rate limited, skip this cycle
        if (currentTime < g_RateLimitResetTime) return Plugin_Continue;

        // Rate limit has expired
        g_IsRateLimited = false;
        LogMessage("[DISCORD QUEUE] Rate limit expired, resuming message processing");
    }

    // Check if there is a pending batch to retry
    if (g_HasPendingBatch)
    {
        LogMessage("[DISCORD QUEUE] Retrying pending batch (attempt %d/%d), %d chars", g_PendingBatchRetries + 1, MAX_RETRIES, strlen(g_PendingBatch));
        SendDiscordMessageDirect(g_PendingBatch);
        return Plugin_Continue;
    }

    // Check if queue is empty
    if (g_QueueCount == 0) return Plugin_Continue;

    // Build batched message
    // Declared outside loop to avoid repeated stack allocation
    char currentMessage[MAX_MESSAGE_SIZE];
    char batchedMessage[MAX_DISCORD_MESSAGE_SIZE];
    int  batchedLength   = 0;
    int  messagesInBatch = 0;

    while (g_QueueCount > 0)
    {
        // Skip deleted messages
        if (g_MessageDeleted[g_QueueTail])
        {
            g_MessageDeleted[g_QueueTail] = false;
            g_QueueTail                   = (g_QueueTail + 1) % MAX_QUEUE_SIZE;
            continue;
        }

        // Check if next message will fit (peek without dequeuing)
        int messageLen = strlen(g_MessageQueue[g_QueueTail]);
        int newLength  = batchedLength + messageLen;

        // Add newline separator if not first message
        if (messagesInBatch > 0)
        {
            newLength += 1;    // For '\n'
        }

        // Check if adding this message would exceed limit
        if (newLength > MAX_DISCORD_MESSAGE_SIZE)
        {
            // Can't fit this message, send what we have
            break;
        }

        // Now dequeue the message (we know it fits)
        if (!DequeueMessage(currentMessage, sizeof(currentMessage)))
        {
            break;    // Queue became empty
        }

        // Add to batch
        if (messagesInBatch > 0)
        {
            StrCat(batchedMessage, sizeof(batchedMessage), "\n");
            batchedLength += 1;
        }

        StrCat(batchedMessage, sizeof(batchedMessage), currentMessage);
        batchedLength += messageLen;
        messagesInBatch++;
    }

    if (messagesInBatch > 0)
    {
        LogMessage("[DISCORD QUEUE] Sending batch of %d message(s), %d chars", messagesInBatch, batchedLength);
    }

    // Send the batched message if we have anything
    if (batchedLength > 0)
    {
        // Store the batch in case we need to retry
        strcopy(g_PendingBatch, sizeof(g_PendingBatch), batchedMessage);
        g_HasPendingBatch = true;

        SendDiscordMessageDirect(batchedMessage);
    }

    return Plugin_Continue;
}

// ============================================================================
// Message Queue Management Functions
// ============================================================================

int FindOldestNonPriorityMessage()
{
    int searchPos = g_QueueTail;
    int checked   = 0;

    // Search through all messages currently in queue (not just until head)
    while (checked < g_QueueCount)
    {
        // Skip deleted messages
        if (!g_MessageDeleted[searchPos] && !g_MessagePriorities[searchPos])
        {
            return searchPos;
        }

        searchPos = (searchPos + 1) % MAX_QUEUE_SIZE;
        checked++;
    }

    return -1;    // All messages are priority or deleted
}

void RemoveMessageAtIndex(int index)
{
    // Mark the message as deleted instead of shifting all messages
    // DequeueMessage will skip deleted slots when processing
    g_MessageDeleted[index] = true;
    g_QueueCount--;
}

bool QueueDiscordMessage(const char[] message, bool isPriority)
{
    int messageLen = strlen(message);

    // Validate message length
    if (messageLen > MAX_DISCORD_MESSAGE_SIZE)
    {
        LogMessage("[DISCORD QUEUE] Message rejected: exceeds %d chars (was %d chars)", MAX_DISCORD_MESSAGE_SIZE, messageLen);
        LogMessage("[DISCORD QUEUE] Rejected message: %s", message);
        return false;
    }

    // Check if queue is full
    if (g_QueueCount >= MAX_QUEUE_SIZE)
    {
        if (isPriority)
        {
            // Try to find and remove oldest non-priority message
            int oldestNonPriority = FindOldestNonPriorityMessage();
            if (oldestNonPriority != -1)
            {
                LogMessage("[DISCORD QUEUE] Queue full, removing non-priority message to make room for priority message");
                RemoveMessageAtIndex(oldestNonPriority);
            }
            else
            {
                LogMessage("[DISCORD QUEUE] Queue full with only priority messages, cannot add new priority message");
                return false;
            }
        }
        else
        {
            LogMessage("[DISCORD QUEUE] Queue full, dropping non-priority message: %s", message);
            return false;
        }
    }

    // Add message to queue
    strcopy(g_MessageQueue[g_QueueHead], MAX_MESSAGE_SIZE, message);
    g_MessagePriorities[g_QueueHead] = isPriority;
    g_MessageDeleted[g_QueueHead]    = false;
    g_QueueHead                      = (g_QueueHead + 1) % MAX_QUEUE_SIZE;
    g_QueueCount++;

    return true;
}

bool DequeueMessage(char[] buffer, int bufferSize)
{
    // Skip deleted messages
    while (g_QueueCount > 0)
    {
        if (!g_MessageDeleted[g_QueueTail])
        {
            // Found a non-deleted message
            strcopy(buffer, bufferSize, g_MessageQueue[g_QueueTail]);
            g_QueueTail = (g_QueueTail + 1) % MAX_QUEUE_SIZE;
            g_QueueCount--;
            return true;
        }

        // Skip this deleted slot
        g_MessageDeleted[g_QueueTail] = false;    // Clear the flag for reuse
        g_QueueTail                   = (g_QueueTail + 1) % MAX_QUEUE_SIZE;
    }

    return false;    // Queue is empty
}
