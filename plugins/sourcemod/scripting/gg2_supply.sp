#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

int playerTokensCount = 100;
int botTokensCount = 35;

public Plugin myinfo =
{
  name = "[GG2 Supply] Supply Point Manager",
  author = "zachm",
  description = "Set player supply points",
  version = "0.1",
  url = "https://insurgency.lol"
};

public void OnPluginStart() {
  // Hook to start of round, for storing players Supply
  HookEvent("round_start", Event_RoundStart);

  // Hook (& Command) to explicitly set a player's supply points. Applies _before_ player spawns in world.
  HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
}

 void gib(int client, int token_count) {
     int currentTokens = GetEntProp(client, Prop_Send, "m_nRecievedTokens");
     if (currentTokens < token_count) {
         SetEntProp(client, Prop_Send, "m_nRecievedTokens",token_count);
     }
 }

public Action Event_RoundStart(Handle event, const char[] name, bool dontBroadcast) {
    for (int client = 1; client <= MaxClients; client++) {
        //int client = GetClientOfUserId(GetEventInt(event, "userid"));
        if (!IsClientInGame(client)) {
            continue;
        }
        if (IsFakeClient(client)) {
            gib(client, botTokensCount);
        } else {
            gib(client, playerTokensCount);
        }
    }
    return Plugin_Continue;
}


public Action Event_PlayerTeam(Handle event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsFakeClient(client)) {
        gib(client, botTokensCount);
    } else {
        gib(client, playerTokensCount);
    }
    return Plugin_Continue;
}
