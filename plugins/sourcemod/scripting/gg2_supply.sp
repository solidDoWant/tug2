#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

ConVar           g_cvPlayerTokensCount;
ConVar           g_cvBotTokensCount;

public Plugin myinfo =
{
    name        = "[GG2 Supply] Supply Point Manager",
    author      = "zachm",
    description = "Set player supply points",
    version     = "0.1",
    url         = "https://insurgency.lol"
};

public void OnPluginStart()
{
    // Create ConVars
    g_cvPlayerTokensCount = CreateConVar("sm_supply_player_tokens", "100", "Supply tokens for players", FCVAR_NOTIFY);
    g_cvBotTokensCount    = CreateConVar("sm_supply_bot_tokens", "35", "Supply tokens for bots", FCVAR_NOTIFY);

    // Hook to start of round, for storing players Supply
    HookEvent("round_start", Event_RoundStart);

    // Hook (& Command) to explicitly set a player's supply points. Applies _before_ player spawns in world.
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
}

void SetSupplyTokens(int client)
{
    if (client <= 0 || client > MaxClients) return;
    if (!IsClientInGame(client)) return;

    int token_count   = IsFakeClient(client) ? g_cvBotTokensCount.IntValue : g_cvPlayerTokensCount.IntValue;

    int currentTokens = GetEntProp(client, Prop_Send, "m_nRecievedTokens");
    if (currentTokens >= token_count) return;

    SetEntProp(client, Prop_Send, "m_nRecievedTokens", token_count);
}

public Action Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        SetSupplyTokens(client);
    }
    return Plugin_Continue;
}

public Action Event_PlayerTeam(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    SetSupplyTokens(client);

    return Plugin_Continue;
}
