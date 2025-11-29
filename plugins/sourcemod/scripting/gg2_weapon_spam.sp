#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <morecolors>
#include <discord>
#include <TheaterItemsAPI>

public Plugin myinfo =  {
    name = "[GG2 Weapon Spam]",
    author = "zachm",
    description = "Find weapon spammers",
    version = "0.0.1",
    url = ""
}

GlobalForward WeaponSpammerForward

bool was_firing[MAXPLAYERS+1] = {false, ...};
int current_firing_duration[MAXPLAYERS+1] = {0, ...};
int max_firing_duration[MAXPLAYERS+1] = {0, ...};
int last_message_time[MAXPLAYERS+1] = {0, ...};

char ouch_sounds[][] = {
    "player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated1.ogg",
    "player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated3.ogg",
    "player/voice/responses/security/subordinate/damage/molotov_incendiary_detonated5.ogg"
}

bool g_playerHasSpammableWeapon[MAXPLAYERS+1] = {false, ...};

// Add/Remove Spammable weapons to/from here
char g_spammable_weapons[][] = {
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
int g_spammable_weapons_int[16] = {-1, ... };

#define MAX_SPAM_TIME 50
#define MIN_SPAM_TIME_FIRE 100

public void OnPluginStart() {
    HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
    HookEvent("weapon_deploy", Event_WeaponDeploy);
    HookEvent("player_connect", Event_PlayerConnect);
    WeaponSpammerForward = new GlobalForward("Weapon_Spammer", ET_Event, Param_Cell, Param_String);

    LoadTranslations("tug.phrases.txt");
}

public Action SendForwardWeaponSpammer(int client, char[] weapon) {	// tug stats forward
	Action result;
	Call_StartForward(WeaponSpammerForward);
	Call_PushCell(client);
	Call_PushString(weapon);
	Call_Finish(result);
	return result;
}


public Action Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidPlayer(client)) {
        return Plugin_Continue;
    }
    if (!IsClientConnected(client)) {
        return Plugin_Continue;
    }
    if (!IsClientInGame(client)) {
        return Plugin_Continue;
    }
    if (IsFakeClient(client)) {
        return Plugin_Continue;
    }
    was_firing[client] = false;
    current_firing_duration[client] = 0;
    max_firing_duration[client] = 0;
    last_message_time[client] = 0;
    return Plugin_Continue
}

public bool IsValidPlayer(int client) {
    return (0 < client <= MaxClients) && IsClientInGame(client);
}

public void OnMapStart() {
    
    CreateTimer(0.1, weaponDurationCounter, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    for (int i = 0; i < sizeof(ouch_sounds); i++) {
        PrecacheSound(ouch_sounds[i]);
    }
    
    for (int i = 0; i < sizeof(g_spammable_weapons); i++) {
        int spammable_weapon_id = GetTheaterItemIdByWeaponName(g_spammable_weapons[i]);
        if (spammable_weapon_id > -1) {
            LogMessage("[GG2 Weapon Spam] found spammable weapon: (%i) %s", spammable_weapon_id, g_spammable_weapons[i]);
            g_spammable_weapons_int[i] = spammable_weapon_id;
        }
    }

}

public void playOuchSound(int client) {
    int offset = GetRandomInt(0,2);
    EmitSoundToAll(ouch_sounds[offset], client, SNDCHAN_AUTO, _, _, 1.0);
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    for (int client = 1; client < MaxClients; client++) {
        if (!IsClientConnected(client)) {
            continue;
        }
        if (!IsClientInGame(client)) {
            continue;
        }
        if (IsFakeClient(client)) {
            continue;
        }

        int max_duration = max_firing_duration[client] / 10;
        if (max_duration == 0) {
            continue;
        }
        if (max_firing_duration[client] > MAX_SPAM_TIME) {
            CPrintToChat(client, "{common}Max Burst Length: {default}{red}%i Seconds", max_duration);
        } else {
            CPrintToChat(client, "{common}Max Burst Length: {default}{darkolivegreen}%i Seconds", max_duration);
        }
        max_firing_duration[client] = 0;
    }
    return Plugin_Continue;
}

public Action Event_WeaponDeploy(Event event, const char[] name, bool dontBroadcast) {
    int weapon_id = GetEventInt(event, "weaponid");
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    g_playerHasSpammableWeapon[client] = false;
    for (int i = 0; i < sizeof(g_spammable_weapons_int); i++) {
        if (weapon_id == g_spammable_weapons_int[i]) {
            // this is a spammable weapon
            g_playerHasSpammableWeapon[client] = true;
            break;
        }
    }
    return Plugin_Continue;
}

public bool is_spammable_weapon_id(int weapon_id) {
    for (int i = 0; i < sizeof(g_spammable_weapons_int); i++) {
        if (weapon_id == g_spammable_weapons_int[i]) {
            return true;
        }
    }
    return false;
}

public bool is_spammable(char[] weapon_name) {
    for (int i = 0; i < sizeof(g_spammable_weapons); i++) {
        if (StrEqual(weapon_name, g_spammable_weapons[i])) {
            return true;
        }
    }
    return false;
}

public Action weaponDurationCounter(Handle timer) {
    for (int client = 1; client < MaxClients; client++) {
        if (!IsClientConnected(client)) {
            continue;
            }
        if (!IsClientInGame(client)) {
            continue;
        }
        if (IsFakeClient(client)) {
            continue;
        }
        if (!g_playerHasSpammableWeapon[client]) {
            continue;
        }

        if (was_firing[client]) {
            if( GetClientButtons(client) & IN_ATTACK ) {
                current_firing_duration[client]++;
                if (max_firing_duration[client] < current_firing_duration[client]) {
                    max_firing_duration[client]++;
                }
                was_firing[client] = true;
            } else {
                was_firing[client] = false;
                current_firing_duration[client] = 0;
            }
        } else {
            if( GetClientButtons(client) & IN_ATTACK ) {
                current_firing_duration[client] = 1;
                was_firing[client] = true;
            }
        }
        if (current_firing_duration[client] > MAX_SPAM_TIME) {
            
            char current_weapon[64];
            GetClientWeapon(client, current_weapon, sizeof(current_weapon));
            int current_weapon_id = GetTheaterItemIdByWeaponName(current_weapon);
            if (current_firing_duration[client] > MIN_SPAM_TIME_FIRE) {
                
                if (!is_spammable_weapon_id(current_weapon_id)) {
                    return Plugin_Continue;
                }

                int weapon_ent_to_drop = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
                if (!IsValidEntity(weapon_ent_to_drop)) {
                    LogMessage("[GG2 Weapon Spam] weapon_spam triggered but weapon is not valid entity");
                    return Plugin_Continue;
                }
                IgniteEntity(weapon_ent_to_drop, 5.0, false, 0.0, false);
                SDKHooks_DropWeapon(client, weapon_ent_to_drop, NULL_VECTOR, NULL_VECTOR);
                //CPrintToChatAll("{common}MG SPAM ACTION: {fullred}%N MG Spammed and was forced to drop their weapon", client);
                char spammer_name[64];
                Format(spammer_name, sizeof(spammer_name), "%N", client);
                CPrintToChatAll("{common}MG SPAM ACTION: %t", "mg_spam_action_all", spammer_name);
                //PrintHintText(client, "Your weapon got too hot");
                PrintHintText(client, "%T", "weapon_too_hot", client);
                
                char d_message[512];
                Format(d_message, sizeof(d_message), "weapon_spam dropped %N weapon (%s)", client, current_weapon);
                send_to_discord(client, d_message);
                
                LogMessage("[GG2 Weapon Spam] over max, %N weapon drop triggered", client);
                playOuchSound(client);
                SendForwardWeaponSpammer(client, current_weapon);
                return Plugin_Continue;
            }

            if (GetTime() - last_message_time[client] > 1) {
                CPrintToChat(client, "{common}MG SPAM WARN: {fullred}3-5sec Bursts Plz");
                //PrintHintText(client, "MG SPAM WARN: 3-5sec Bursts Plz");
                PrintHintText(client, "%T", "mg_spam_warn", client);
                last_message_time[client] = GetTime();
                LogMessage("[GG2 Weapon Spam] %N current firing duration: %i (MAX: %i)", client, current_firing_duration[client], max_firing_duration[client]);
                int current_duration = current_firing_duration[client] /10; 

                if (current_firing_duration[client] + 2 >= MIN_SPAM_TIME_FIRE) {
                    char d_message[512];
                    Format(d_message, sizeof(d_message),"weapon_spam warned (duration: %i sec) (weapon_name: %s)", current_duration, current_weapon);
                    send_to_discord(client, d_message);
                }
            }

        }

    }
    return Plugin_Continue;
}
