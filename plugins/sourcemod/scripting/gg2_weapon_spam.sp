#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <morecolors>
#include <discord>
#include <TheaterItemsAPI>

public Plugin myinfo =
{
    name        = "[GG2 Weapon Spam]",
    author      = "zachm",
    description = "Find weapon spammers",
    version     = "0.0.1",
    url         = ""
};

int  current_firing_duration[MAXPLAYERS + 1];
int  round_max_firing_duration[MAXPLAYERS + 1];
int  last_warning_message_time[MAXPLAYERS + 1];

char ouch_sounds[][] = {
    "player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated1.ogg",
    "player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated3.ogg",
    "player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated5.ogg"
};

bool g_playerHasSpammableWeapon[MAXPLAYERS + 1] = { false, ... };

// Add/Remove Spammable weapons to/from here
char g_spammable_weapons[][]                    = {
    "weapon_sandstorm_galil_sar",
    "weapon_sandstorm_m249",
    "weapon_sandstorm_m240",
    "weapon_sandstorm_rpk",
    "weapon_galil_sar",
    "weapon_m249",
    "weapon_mg42",
    "weapon_mk46",
    "weapon_m60",
    "weapon_pecheneg",
    "weapon_m240",
    "weapon_doi2ins_mg42",
    "weapon_doi2ins_m1919",
    "weapon_doi2ins_vickers"
};

int g_spammable_weapon_ids[16] = { -1, ... };

#define SPAM_TIME_WARN   50
#define SPAM_TIME_PUNISH 100

public void OnPluginStart()
{
    HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
    HookEvent("weapon_deploy", Event_WeaponDeploy);
    HookEvent("player_disconnect", Event_PlayerDisconnect);

    LoadTranslations("tug.phrases.txt");
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client)) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;

    current_firing_duration[client]    = 0;
    round_max_firing_duration[client]  = 0;
    last_warning_message_time[client]  = 0;
    g_playerHasSpammableWeapon[client] = false;

    return Plugin_Continue;
}

public bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

public void OnMapStart()
{
    CreateTimer(0.1, Timer_WeaponDurationCounter, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    for (int i = 0; i < sizeof(ouch_sounds); i++)
    {
        PrecacheSound(ouch_sounds[i]);
    }

    for (int i = 0; i < sizeof(g_spammable_weapons); i++)
    {
        g_spammable_weapon_ids[i] = GetTheaterItemIdByWeaponName(g_spammable_weapons[i]);
        if (g_spammable_weapon_ids[i] != -1) continue;
        LogError("[GG2 Weapon Spam] could not find weapon ID for spammable weapon name: %s", g_spammable_weapons[i]);
    }
}

public void PlayOuchSound(int client)
{
    int ouch_sound_number = GetRandomInt(0, 2);
    EmitSoundToAll(ouch_sounds[ouch_sound_number], client, SNDCHAN_AUTO, _, _, 1.0);
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        int client_max_firing_duration    = round_max_firing_duration[client];
        round_max_firing_duration[client] = 0;

        if (client_max_firing_duration == 0) continue;
        if (!IsClientInGame(client)) continue;
        if (!IsClientConnected(client)) continue;
        if (IsFakeClient(client)) continue;

        if (client_max_firing_duration > SPAM_TIME_WARN)
        {
            CPrintToChat(client, "{common}Max Burst Length: {default}{red}%i Seconds", client_max_firing_duration / 10);
            continue;
        }
        CPrintToChat(client, "{common}Max Burst Length: {default}{darkolivegreen}%i Seconds", client_max_firing_duration / 10);
    }

    return Plugin_Continue;
}

public Action Event_WeaponDeploy(Event event, const char[] name, bool dontBroadcast)
{
    int weapon_id = GetEventInt(event, "weaponid");
    int client    = GetClientOfUserId(GetEventInt(event, "userid"));
    // Don't check this when the player is a bot
    if (IsFakeClient(client)) return Plugin_Continue;

    g_playerHasSpammableWeapon[client] = IsWeaponSpammable(weapon_id);

    return Plugin_Continue;
}

public bool IsWeaponSpammable(int weapon_id)
{
    for (int i = 0; i < sizeof(g_spammable_weapon_ids); i++)
    {
        if (weapon_id == g_spammable_weapon_ids[i]) return true;
    }

    return false;
}

public Action Timer_WeaponDurationCounter(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!g_playerHasSpammableWeapon[client]) continue;
        if (!IsClientInGame(client)) continue;
        if (!IsClientConnected(client)) continue;
        if (IsFakeClient(client)) continue;

        if ((GetClientButtons(client) & IN_ATTACK) == 0)
        {
            // Reset and update the max firing duration if needed
            if (round_max_firing_duration[client] < current_firing_duration[client])
            {
                round_max_firing_duration[client] = current_firing_duration[client];
            }
            current_firing_duration[client] = 0;
            continue;
        }
        current_firing_duration[client]++;

        if (current_firing_duration[client] > SPAM_TIME_PUNISH)
        {
            char current_weapon[64];
            GetClientWeapon(client, current_weapon, sizeof(current_weapon));

            // Is this actually needed? Why not use `g_playerHasSpammableWeapon` here?
            int current_weapon_id = GetTheaterItemIdByWeaponName(current_weapon);
            if (!IsWeaponSpammable(current_weapon_id)) continue;

            int active_weapon_entity = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
            if (!IsValidEntity(active_weapon_entity))
            {
                LogMessage("[GG2 Weapon Spam] weapon_spam triggered but weapon is not valid entity");
                continue;
            }

            // Put weapon on fire and drop it
            IgniteEntity(active_weapon_entity, 5.0, false, 0.0, false);
            SDKHooks_DropWeapon(client, active_weapon_entity, NULL_VECTOR, NULL_VECTOR);
            PlayOuchSound(client);

            // This is needed because sourcemod formatting with translations doesn't support %N inside the translation string
            char spammer_name[64];
            Format(spammer_name, sizeof(spammer_name), "%N", client);

            CPrintToChatAll("{common}MG SPAM ACTION: %t", "mg_spam_action_all", spammer_name);
            PrintHintText(client, "%T", "weapon_too_hot", client);

            char d_message[512];
            Format(d_message, sizeof(d_message), "weapon_spam dropped %N weapon (%s)", client, current_weapon);
            send_to_discord(client, d_message);

            LogMessage("[GG2 Weapon Spam] over max, %N weapon drop triggered", client);
            continue;
        }

        // Warn after SPAM_TIME_WARN
        if (current_firing_duration[client] < SPAM_TIME_WARN) continue;

        int now = GetTime();
        if (now < last_warning_message_time[client] + 1) continue;

        CPrintToChat(client, "{common}MG SPAM WARN: {fullred}3-5sec Bursts Plz");
        PrintHintText(client, "%T", "mg_spam_warn", client);
        last_warning_message_time[client] = now;

        LogMessage("[GG2 Weapon Spam] %N current firing duration: %i (MAX: %i)", client, current_firing_duration[client], round_max_firing_duration[client]);
        int  current_duration_seconds = current_firing_duration[client] / 10;

        char current_weapon[64];
        GetClientWeapon(client, current_weapon, sizeof(current_weapon));

        char d_message[512];
        Format(d_message, sizeof(d_message), "weapon_spam warned (duration: %i sec) (weapon_name: %s)", current_duration_seconds, current_weapon);
        send_to_discord(client, d_message);
    }

    return Plugin_Continue;
}
