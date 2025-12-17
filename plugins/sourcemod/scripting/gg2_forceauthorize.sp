#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

ConVar           cvarConnectMessage;
ConVar           cvarConnectTime;
ConVar           cvarFailureMethod;
StringMap        g_strmapAuthCount;

public Plugin myinfo =
{
    name        = "[GG2 ForceAuth] Force Authorize",
    author      = "JoinedSenses",
    description = "Forces players to authenticate by reconnecting them.",
    version     = "1.0.0",
    url         = ""
};

public void OnPluginStart()
{
    cvarConnectMessage = CreateConVar("sm_forceauth_connect", "0", "Enable connect message until player has authenticated?", FCVAR_NONE, true, 0.0, true, 1.0);
    cvarConnectTime    = CreateConVar("sm_forceauth_time", "10.0", "How many seconds to wait until checking that the client has authenticated.", FCVAR_NONE, true, 0.0);
    cvarFailureMethod  = CreateConVar("sm_forceauth_method", "reconnect", "Method of dealing with clients who have failed to authenticate (Options: reconnect, kick)");
    cvarFailureMethod.AddChangeHook(cvarChanged_FailureMethod);

    g_strmapAuthCount = new StringMap();

    HookEvent("player_connect", Event_PlayerConnect, EventHookMode_Pre);
}

public void cvarChanged_FailureMethod(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (StrEqual(newValue, "reconnect", false) || StrEqual(newValue, "kick", false)) return;

    convar.SetString(oldValue);
}

public void OnMapEnd()
{
    g_strmapAuthCount.Clear();
}

public void OnClientPostAdminCheck(int client)
{
    if (!cvarConnectMessage.BoolValue) return;

    PrintToChatAll("%N connected", client);
}

public void OnClientPutInServer(int client)
{
    CreateTimer(cvarConnectTime.FloatValue, Timer_CheckAuth, GetClientUserId(client));
}

public Action Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast)
{
    if (!cvarConnectMessage.BoolValue) return Plugin_Continue;

    event.BroadcastDisabled = true;
    return Plugin_Continue;
}

public Action Timer_CheckAuth(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || IsFakeClient(client)) return Plugin_Stop;

    char ipAddress[32];
    char clientName[MAX_NAME_LENGTH];
    char clientKey[64];

    if (!GetClientIP(client, ipAddress, sizeof(ipAddress)) || ipAddress[0] == '\0')
    {
        LogError("[GG2 ForceAuthorize] Failed to get IP address for client %d. Kicking.", client);
        KickClient(client, "Unable to verify connection");
        return Plugin_Continue;
    }

    if (!GetClientName(client, clientName, sizeof(clientName)) || clientName[0] == '\0')
    {
        LogError("[GG2 ForceAuthorize] Failed to get name for client %d (%s). Kicking.", client, ipAddress);
        KickClient(client, "Unable to verify connection");
        return Plugin_Continue;
    }

    Format(clientKey, sizeof(clientKey), "%s:%s", ipAddress, clientName);

    if (IsClientAuthorized(client))
    {
        g_strmapAuthCount.Remove(clientKey);
        return Plugin_Continue;
    }

    char dealMethod[10];
    cvarFailureMethod.GetString(dealMethod, sizeof(dealMethod));

    bool exceededConnectCount;
    if (StrEqual(dealMethod, "reconnect", false))
    {
        int count = 0;
        g_strmapAuthCount.GetValue(clientKey, count);
        count++;

        if (count < 3)
        {
            g_strmapAuthCount.SetValue(clientKey, count);
            CreateTimer(5.0, Timer_Reconnect, GetClientUserId(client));
            if (cvarConnectTime.FloatValue >= 5.0)
            {
                PrintToChat(client, "Failed to authenticate. Reconnecting in 5 seconds.");
            }

            return Plugin_Continue;
        }

        // Kick after 2 failed reconnects
        exceededConnectCount = true;
        g_strmapAuthCount.Remove(clientKey);
    }

    if (exceededConnectCount || StrEqual(dealMethod, "kick", false))
    {
        // LogError("%N failed to authenticate. Kicking.", client);
        LogMessage("[GG2 ForceAuthorize] %N failed to authenticate. Kicking.", client);
        KickClient(client, "Authentication failure");
        return Plugin_Continue;
    }

    LogError("Unknown auth failure method (%s) for sm_forceauth_method. Options are reconnect or kick.", dealMethod);
    return Plugin_Continue;
}

public Action Timer_Reconnect(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || IsFakeClient(client)) return Plugin_Continue;

    LogMessage("[GG2 ForceAuthorize] %N failed to authenticate. Reconnecting.", client);
    ClientCommand(client, "retry");

    return Plugin_Continue;
}
