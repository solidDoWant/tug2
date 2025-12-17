#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <discord>

#pragma newdecls required

#define TEAM_1_SEC    2
#define TEAM_2_INS    3
#define HITGROUP_HEAD 1

public Plugin myinfo =
{
    name        = "[GG2 DAMAGE] One Shot Kills and NERFS",
    author      = "zachm",
    description = "Adjust damage for one-shot kill weapons",
    version     = "0.2",
    url         = "https://insurgency.lol"
};

bool   g_isBomber[MAXPLAYERS + 1];
int    g_playerGaveTeamDamageCooldown[MAXPLAYERS + 1] = { 0, ... };
// Track last time attacker was notified about bomber headshots (uses GetGameTime() in seconds)
float  g_fLastBomberNotifyTime[MAXPLAYERS + 1];

char   GRENADE_IED[12] = "grenade_ied";

ConVar gg_bomber_headshot_multiplier;
ConVar gg_bomber_nonheadshot_value;
ConVar gg_notification_cooldown;

char   g_one_shot_weapons[][] = {
    "weapon_defib",
    "weapon_kabar",
    "weapon_sandstorm_kabar",
    "weapon_sandstorm_m24",
    "weapon_sandstorm_mosin",
    "weapon_vietnam_m40",
    "weapon_enfield",
    "weapon_kar98",
    "weapon_springfield",
    "weapon_remingtonmsr",
    "weapon_m40a1",
    "weapon_mosin"
};

public bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

public void OnPluginStart()
{
    HookEvent("player_disconnect", Event_PlayerDisconnect);
    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    gg_bomber_headshot_multiplier = CreateConVar("gg_bomber_headshot_multiplier", "500.0", "Multiply headshot on bombers by this much");
    gg_bomber_nonheadshot_value   = CreateConVar("gg_bomber_nonheadshot_value", "35.0", "Non-Headshots on bombers give this much damage");
    gg_notification_cooldown      = CreateConVar("gg_bomber_notification_cooldown", "3.0", "Cooldown time in seconds for bomber hit notifications");
    AutoExecConfig(true, "gg2_damage");

    LoadTranslations("tug.phrases.txt");
}

public void OnMapStart()
{
    CreateTimer(1.0, Timer_DecrementTeamDamageCooldown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);

    // Only hook fake clients (bots) for TraceAttack
    if (!IsFakeClient(client)) return;
    SDKHook(client, SDKHook_TraceAttack, SHook_TraceAttack);
}

public Action Timer_DecrementTeamDamageCooldown(Handle Timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_playerGaveTeamDamageCooldown[client] <= 0) continue;
        g_playerGaveTeamDamageCooldown[client]--;
    }

    return Plugin_Continue;
}

public Action Event_PlayerPickSquad(Handle event, char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client == 0) return Plugin_Continue;

    // Only track class for bots (used for bomber detection)
    if (!IsFakeClient(client)) return Plugin_Continue;

    char class_template[64];
    GetEventString(event, "class_template", class_template, sizeof(class_template));
    g_isBomber[client] = (StrContains(class_template, "bomber") != -1);

    return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, char[] name, bool dontBroadcast)
{
    int UserId = event.GetInt("userid");
    if (UserId == 0) return Plugin_Continue;

    int client = GetClientOfUserId(UserId);
    if (client == 0) return Plugin_Continue;

    SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    g_isBomber[client] = false;

    if (!IsFakeClient(client)) return Plugin_Continue;
    SDKUnhook(client, SDKHook_TraceAttack, SHook_TraceAttack);

    return Plugin_Continue;
}

public Action SHook_TraceAttack(int victim, int& attacker, int& inflictor, float& damage, int& damagetype, int& ammotype, int hitbox, int hitgroup)
{
    if (!(damagetype & DMG_BULLET)) return Plugin_Continue;
    if (!g_isBomber[victim]) return Plugin_Continue;
    if (GetClientTeam(victim) != TEAM_2_INS) return Plugin_Continue;

    if (hitgroup == HITGROUP_HEAD)
    {
        damage *= gg_bomber_headshot_multiplier.FloatValue;
        return Plugin_Changed;
    }

    damage                = gg_bomber_nonheadshot_value.FloatValue;

    // Send "shoot in head" notification to attacker periodically
    float currentGameTime = GetGameTime();
    if (g_fLastBomberNotifyTime[attacker] >= currentGameTime - gg_notification_cooldown.FloatValue) return Plugin_Changed;

    g_fLastBomberNotifyTime[attacker] = currentGameTime;
    if (gg_bomber_nonheadshot_value.IntValue < 10)
    {
        PrintToChat(attacker, "%T", "bomber_shoot_in_the_head", attacker);
    }

    return Plugin_Changed;
}

public Action OnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype)
{
    float scaledIEDDamage = CalculateScaledIEDDamage(victim, inflictor, damage, damagetype);
    if (scaledIEDDamage != damage)
    {
        damage = scaledIEDDamage;
        return Plugin_Changed;
    }

    if (!IsValidPlayer(attacker)) return Plugin_Continue;

    char weapon[32];
    GetClientWeapon(attacker, weapon, sizeof(weapon));

    float teamDamage = CalculateTeamDamage(victim, attacker, weapon, damage, damagetype);
    if (teamDamage != damage)
    {
        damage = teamDamage;

        PrintToChat(victim, "%N If you are in the way, fucking move", victim);
        PrintToChat(attacker, "%N Check your fire and watch out for fucking idiots in the way", attacker);

        if (g_playerGaveTeamDamageCooldown[attacker] == 0)
        {
            PrintHintText(victim, "");
            PrintHintText(victim, "If you are in the way, fucking move");

            PrintHintText(attacker, "");
            PrintHintText(attacker, "Check your fire, you are shooting teammates");

            char d_message[512];
            Format(d_message, sizeof(d_message), "__***Attacked Teammate***__ %N (%s)", victim, weapon);
            send_to_discord(attacker, d_message);

            g_playerGaveTeamDamageCooldown[attacker] = gg_notification_cooldown.IntValue;
        }

        return Plugin_Changed;
    }

    if (IsOneShotKillWeapon(weapon))
    {
        damage = 1024.0;
        return Plugin_Changed;
    }

    return Plugin_Continue;
}

float CalculateScaledIEDDamage(int victim, int inflictor, float baseDamage, int damagetype)
{
    if ((damagetype & DMG_BLAST) == 0) return baseDamage;

    if (!IsValidEntity(inflictor)) return baseDamage;

    char blast_weapon[32];
    GetEdictClassname(inflictor, blast_weapon, sizeof(blast_weapon));

    if (!StrEqual(GRENADE_IED, blast_weapon)) return baseDamage;

    float distanceFromIED = GetEntitiesDistance(inflictor, victim);

    // y = baseDamage * 1/(2.2^(distance/75))
    // Exponential damage falloff, cut by 2.2 every 75 units away. Max distance is determined by the IED damage radius.
    return baseDamage / Pow(2.2, distanceFromIED / 75.0);
}

float CalculateTeamDamage(int victim, int attacker, char[] weapon, float baseDamage, int damagetype)
{
    if ((damagetype & (DMG_BULLET | DMG_SLASH)) == 0) return baseDamage;
    if (!IsValidPlayer(attacker)) return baseDamage;
    if (IsFakeClient(attacker)) return baseDamage;
    if (GetClientTeam(victim) != TEAM_1_SEC) return baseDamage;
    if (GetClientTeam(attacker) != TEAM_1_SEC) return baseDamage;

    if (StrEqual(weapon, "weapon_defib", false)) return baseDamage;

    // Require ~2.2x more damage to TK than normal
    return baseDamage / 2.2;
}

public bool IsOneShotKillWeapon(char[] weapon)
{
    for (int i = 0; i < sizeof(g_one_shot_weapons); i++)
    {
        if (StrEqual(weapon, g_one_shot_weapons[i], false)) return true;
    }

    return false;
}

stock float GetEntitiesDistance(int ent1, int ent2)
{
    float orig1[3];
    GetEntPropVector(ent1, Prop_Send, "m_vecOrigin", orig1);

    float orig2[3];
    GetEntPropVector(ent2, Prop_Send, "m_vecOrigin", orig2);

    return GetVectorDistance(orig1, orig2);
}