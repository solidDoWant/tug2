/*-------------------------------------

    This plugin is to ignite the player when they taking fire damage
    The fire damage stack up the longer the player in the fire
    They will have to prone to remove all fire on them

---------------------------------------*/

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

public Plugin myinfo =
{
    name        = "[GG2 BURN] Burn",
    description = "Ignite player when player taking fire damage",
    author      = "Neko- || zachm",
    version     = "1.0.5.1",
};

enum Teams
{
    TEAM_NONE = 0,
    TEAM_SPECTATORS,
    TEAM_SECURITY,
    TEAM_INSURGENTS,
};

// Weapons here will ignite players impacted by damage from them, even if the damage is not fire damage already
char fireWeapons[][32] = {
    "grenade_molotov",
    "grenade_anm14",
    "grenade_m203_incid",
    "grenade_gp25_incid",
};

// Fire armor is not currently used or implemented
// int g_iPlayerEquipGear;
// int nArmorFireResistance = 6;
public void OnPluginStart()
{
    // g_iPlayerEquipGear = FindSendPropInfo("CINSPlayer", "m_EquippedGear");

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Pre);
}

public void OnMapStart()
{
    CreateTimer(1.0, Timer_SpreadBurn, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client)
{
    // Hook damage taken to change the damage it deals
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
    if (!IsPlayerAlive(client)) return Plugin_Continue;

    // Get player stance
    int nStance = GetEntProp(client, Prop_Send, "m_iCurrentStance");

    // Check if prone
    if (nStance != 2) return Plugin_Continue;

    // Remove all fire
    int ent = GetEntPropEnt(client, Prop_Data, "m_hEffectEntity");
    if (!IsValidEdict(ent)) return Plugin_Continue;

    // Reset to 0.0 to remove all fire
    SetEntPropFloat(ent, Prop_Data, "m_flLifetime", 0.0);

    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    char weaponCheck[64];
    GetEventString(event, "weapon", weaponCheck, sizeof(weaponCheck));

    if (!StrEqual(weaponCheck, "entityflame", false)) return Plugin_Continue;

    // Rename [entityflame] to [Flame] for the top right (Killfeed)
    SetEventString(event, "weapon", "Burnt Up");

    return Plugin_Continue;
}

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));

    int health = GetEventInt(event, "health");
    if (health <= 0)
    {
        int ent = GetEntPropEnt(client, Prop_Data, "m_hEffectEntity");
        if (ent == -1) return Plugin_Continue;

        // Reset to 0.0 to remove all fire on death
        SetEntPropFloat(ent, Prop_Data, "m_flLifetime", 0.0);

        return Plugin_Continue;
    }

    // Set the player on fire if hurt by fire weapons
    char sWeapon[32];
    GetEventString(event, "weapon", sWeapon, sizeof(sWeapon));

    // Check if the weapon is in the fireWeapons array
    bool isFireWeapon = false;
    for (int i = 0; i < sizeof(fireWeapons); i++)
    {
        if (!StrEqual(sWeapon, fireWeapons[i])) continue;
        isFireWeapon = true;
        break;
    }

    if (!isFireWeapon) return Plugin_Continue;

    IgniteEntity(client, 7.0);

    int client_team = GetClientTeam(client);
    if (client_team != view_as<int>(TEAM_SECURITY)) return Plugin_Continue;

    PrintToChat(client, "You are on fire, go prone to put it out!!");

    return Plugin_Continue;
}

public Action OnTakeDamage(int client, int& attacker, int& inflictor, float& damage, int& damagetype)
{
    // Get weapon name
    char sWeapon[32];
    GetEdictClassname(inflictor, sWeapon, sizeof(sWeapon));

    bool isWeaponFlame = StrEqual(sWeapon, "entityflame");
    if (isWeaponFlame && GetEntPropEnt(client, Prop_Send, "m_hEffectEntity") <= 0) return Plugin_Handled;

    if (!isWeaponFlame) return Plugin_Continue;

    // Per fire damage (This damage stack up if player have more than 1 fire on them)
    damage = 0.5;
    return Plugin_Changed;
}

public Action Timer_SpreadBurn(Handle Timer)
{
    for (int nPlayer = 1; nPlayer <= MaxClients; nPlayer++)
    {
        if (!IsClientInGame(nPlayer)) continue;
        if (!IsPlayerAlive(nPlayer)) continue;
        if (GetClientTeam(nPlayer) == view_as<int>(TEAM_SPECTATORS)) continue;

        int effectEntity = GetEntPropEnt(nPlayer, Prop_Data, "m_hEffectEntity");
        if (!IsValidEdict(effectEntity)) continue;

        for (int nPlayerTarget = 1; nPlayerTarget <= MaxClients; nPlayerTarget++)
        {
            if (!IsClientInGame(nPlayerTarget)) continue;
            if (!IsPlayerAlive(nPlayerTarget)) continue;
            if (nPlayerTarget == nPlayer) continue;

            // // Get player ArmorID, skip if have fire resistance armor
            // int nArmorItemID = GetEntData(nPlayerTarget, g_iPlayerEquipGear);
            // if (nArmorItemID == nArmorFireResistance) continue;

            // Get player stance, skip if prone
            int nStance = GetEntProp(nPlayerTarget, Prop_Send, "m_iCurrentStance");
            if (nStance == 2) continue;

            // If distance more than 95.0, skip
            float fDistance = GetDistance(nPlayer, nPlayerTarget);
            if (fDistance > 95.0) continue;

            IgniteEntity(nPlayerTarget, 7.0);
        }
    }

    return Plugin_Continue;
}

float GetDistance(int nClient, int nTarget)
{
    float fClientOrigin[3];
    GetClientAbsOrigin(nClient, fClientOrigin);

    float fTargetOrigin[3];
    GetClientAbsOrigin(nTarget, fTargetOrigin);

    return GetVectorDistance(fClientOrigin, fTargetOrigin);
}