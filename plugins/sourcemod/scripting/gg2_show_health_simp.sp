#include <sourcemod>

#pragma newdecls required


ConVar cvar_show_health_display_delay;

bool g_bIsInit = false;
float g_fDisplayDelay;

public Plugin myinfo =
{
  name = "[GG2 Show Health]",
  author = "zachm",
  description = "Show health on the screen",
  version = "0.1",
  url = "https://tug.gg"
};

public void OnPluginStart() {

    cvar_show_health_display_delay = CreateConVar("sm_show_health_display_delay", "10", "Defines display delay time", 0);

    HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    LoadTranslations("common.phrases");
    LoadTranslations("showhealth.phrases");

    if(!g_bIsInit) {
        g_bIsInit = true;
        g_fDisplayDelay = GetConVarFloat(cvar_show_health_display_delay);
        CreateTimer(g_fDisplayDelay, Timer_RefreshHealthText, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}


public void OnMapStart() {
    if(!g_bIsInit) {
        g_bIsInit = true;
        g_fDisplayDelay = GetConVarFloat(cvar_show_health_display_delay);
        CreateTimer(g_fDisplayDelay, Timer_RefreshHealthText, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
}
public void OnMapEnd() {
    g_bIsInit = false;
}


public Action Event_PlayerHurt(Handle event, char[] name, bool dontBroadcast) {	
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	int health = GetEventInt(event, "health");
	
	if (health > 0 && IsClientInGame(client) && !IsFakeClient(client))
	{
		ShowHealth(client, health);
	}
	
	return Plugin_Continue;
}

public Action Event_PlayerDeath(Handle event, char[] name, bool dontBroadcast) {

	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if (client == 0)
		return Plugin_Continue;
	
	if (IsClientInGame(client) && !IsFakeClient(client))
	{
		ShowHealth(client, 0);
	}
	
	return Plugin_Continue;
}


public Action Timer_RefreshHealthText(Handle timer) {
    for (int client = 1; client <= MaxClients; client++) {
        if (IsClientInGame(client) && !IsFakeClient(client) && !IsClientObserver(client)) {
            ShowHealth(client, GetClientHealth(client));
        }
    }
    return Plugin_Continue;
}

public void ShowHealth(int client, int health) {
    PrintHintText(client, "%t", "HintText Health Text", health);
}