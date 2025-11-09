// Same as https://raw.githubusercontent.com/NullifidianSF/insurgency_public/e6eb683a6ba407b5bba29b74817e0c0bcb9d6a0c/addons/sourcemod/scripting/bot_flashlight.sp
// but modified to add a convar to set the percentage of bots that get flashlights
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

int    ga_iWepWithFlashlightRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
bool   g_bBotHasFlashlight[MAXPLAYERS + 1]      = { false, ... };

ConVar g_cvFlashlightPercent;

public Plugin myinfo =
{
    name        = "Make bots use flashlights (Random)",
    author      = "Nullifidian, sdw",
    description = "Make a random percentage of bots use flashlights",
    version     = "1.1",
    url         = ""
};

public void OnPluginStart()
{
    HookEvent("weapon_deploy", Event_WeaponDeploy);
    HookEvent("player_spawn", Event_PlayerSpawn);
    AddNormalSoundHook(NormalSoundHook);

    g_cvFlashlightPercent = CreateConVar(
        "sm_bot_flashlight_percent",
        "0.4",
        "Percentage of bots that will use flashlights (0.0 = none, 1.0 = all)",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0);

    AutoExecConfig(true, "plugin.bot_flashlights");
}

public void OnClientDisconnect(int client)
{
    ga_iWepWithFlashlightRef[client] = INVALID_ENT_REFERENCE;
    g_bBotHasFlashlight[client]      = false;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || !IsClientInGame(client) || !IsFakeClient(client)) return Plugin_Continue;

    // Randomly determine if this bot gets a flashlight
    float percent               = g_cvFlashlightPercent.FloatValue;
    float roll                  = GetURandomFloat();
    g_bBotHasFlashlight[client] = (roll < percent);

    return Plugin_Continue;
}

public Action Event_WeaponDeploy(Event event, char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || !IsClientInGame(client) || !IsFakeClient(client)) return Plugin_Continue;

    // Check if this bot was assigned a flashlight
    if (!g_bBotHasFlashlight[client])
    {
        ga_iWepWithFlashlightRef[client] = INVALID_ENT_REFERENCE;
        return Plugin_Continue;
    }

    int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (activeWeapon < 1 || !IsValidEntity(activeWeapon) || !HasEntProp(activeWeapon, Prop_Send, "m_bFlashlightOn"))
    {
        ga_iWepWithFlashlightRef[client] = INVALID_ENT_REFERENCE;
        return Plugin_Continue;
    }

    ga_iWepWithFlashlightRef[client] = EntIndexToEntRef(activeWeapon);
    TurnOnFlashlight(client);

    return Plugin_Continue;
}

void TurnOnFlashlight(int client)
{
    int weapon = EntRefToEntIndex(ga_iWepWithFlashlightRef[client]);
    if (!IsValidEntity(weapon)) return;

    if (GetEntProp(weapon, Prop_Send, "m_bFlashlightOn") == 0)
        SetEntProp(weapon, Prop_Send, "m_bFlashlightOn", 1);
}

public Action NormalSoundHook(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
    if (entity < 1 || entity > MaxClients || !IsClientInGame(entity) || !IsFakeClient(entity)) return Plugin_Continue;

    // Only handle flashlight sounds for bots that were assigned flashlights
    if (!g_bBotHasFlashlight[entity]) return Plugin_Continue;

    if (strcmp(sample, "player/flashlight_off.wav") == 0)
    {
        if (ga_iWepWithFlashlightRef[entity] != INVALID_ENT_REFERENCE)
            TurnOnFlashlight(entity);
        return Plugin_Handled;
    }

    if (strcmp(sample, "player/flashlight_on.wav") == 0) return Plugin_Handled;
    return Plugin_Continue;
}
