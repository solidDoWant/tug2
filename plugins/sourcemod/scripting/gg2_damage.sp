#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <insurgencydy>
#include <discord>


#pragma newdecls required

#define TEAM_1_SEC	2
#define TEAM_2_INS	3
#define HITGROUP_HEAD 1

public Plugin myinfo =
{
  name = "[GG2 DAMAGE] One Shot Kills and NERFS",
  author = "zachm",
  description = "Adjust damage for one-shot kill weapons",
  version = "0.2",
  url = "https://insurgency.lol"
};


char g_client_last_classstring[MAXPLAYERS+1][64];
int g_iLastHitgroup[MAXPLAYERS+1];
int g_playerGaveTeamDamageCooldown[MAXPLAYERS+1] = {0,}
float g_fLastHitTime[MAXPLAYERS+1];

char GRENADE_IED[12] = "grenade_ied";

ConVar gg_bomber_headshot_multiplier;
ConVar gg_bomber_nonheadshot_value;

GlobalForward TeamDamageForward;

//char bomber_class[] = "template_coop_bomber";

char g_one_shot_weapons[][] = {
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
}

public Action SendForwardTeamDamage(int client) {	// tug stats forward
	Action result;
	Call_StartForward(TeamDamageForward);
	Call_PushCell(client);
	Call_Finish(result);
	return result;
}

public bool IsValidPlayer(int client){
    return (0 < client <= MaxClients) && IsClientInGame(client);
}

public void OnPluginStart() {
    HookEvent("player_disconnect", Event_PlayerDisconnect);
    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    gg_bomber_headshot_multiplier = CreateConVar("gg_bomber_headshot_multiplier", "500.0", "Multiply headshot on bombers by this much");
    gg_bomber_nonheadshot_value = CreateConVar("gg_bomber_nonheadshot_value", "10.0", "Non-Headshots on bombers give this much damage");
    AutoExecConfig(true, "gg2_damage");

    TeamDamageForward = new GlobalForward("Team_Damage", ET_Event, Param_Cell);

    LoadTranslations("tug.phrases.txt");
}

public void OnMapStart() {
	CreateTimer(1.0, Timer_DecrementTeamDamageCooldown,_ , TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client) {
    
    if( IsFakeClient( client ) ){
        SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
        SDKHook(client, SDKHook_TraceAttack, SHook_TraceAttack);
    } else {
        SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);

    }
}


public Action Timer_DecrementTeamDamageCooldown(Handle Timer) {
    for(int client = 1; client <= MaxClients; client++) {
        if (--g_playerGaveTeamDamageCooldown[client] <= 0) {
            g_playerGaveTeamDamageCooldown[client] = 0;
        }
    }
    return Plugin_Continue;
}


public Action Event_PlayerPickSquad(Handle event, char[] name, bool dontBroadcast)
{
	//PrintToServer("[SUICIDE] Running Event_PlayerPickSquad");
	int client = GetClientOfUserId(GetEventInt(event, "userid"));

	char class_template[64];
	GetEventString(event, "class_template",class_template,sizeof(class_template));
	if( client) {
		g_client_last_classstring[client] = class_template;
		//LogMessage("[GG OSK] Bot picksquad: client: %i (%N) //  class %s", client, client, g_client_last_classstring[client]);
	}
	return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, char[] name, bool dontBroadcast) {
    int UserId = event.GetInt("userid");
    if (UserId != 0) {
        int client = GetClientOfUserId(UserId);
        if (client != 0) {
            SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
            SDKUnhook(client, SDKHook_TraceAttack, SHook_TraceAttack);
            g_client_last_classstring[client] = "";
        }
	}
    return Plugin_Continue;
}

public Action SHook_TraceAttack(int victim, int& attacker, int& inflictor, float& damage, int& damagetype, int& ammotype, int hitbox, int hitgroup)
{
    g_iLastHitgroup[victim] = hitgroup;
    if (GetClientTeam(victim) == TEAM_1_SEC) return Plugin_Continue;

    if (!(damagetype & DMG_BULLET)) {
        return Plugin_Continue;
    }

    //if (StrEqual(g_client_last_classstring[victim],bomber_class)) {
    if (StrContains(g_client_last_classstring[victim], "bomber") > -1) {
        if (hitgroup == HITGROUP_HEAD) {
            //damage *= (100.0*5.0);
            damage *= gg_bomber_headshot_multiplier.FloatValue;
            //LogMessage("[GG OSK] bomber HEADSHOT damage: %f", damage);
        }
        else { 
            if (g_fLastHitTime[victim] != GetGameTime()) {
                g_fLastHitTime[victim] = GetGameTime();
                if (gg_bomber_nonheadshot_value.IntValue < 10) {
                    //PrintToChat(attacker, "SUICIDE BOMBER is meth'd up, shoot 'em in the head");
                    PrintToChat(attacker, "%T", "bomber_shoot_in_the_head", attacker);
                }
            }
            //damage *= (1.0/25.0);
            //damage = 10.0;
            damage = gg_bomber_nonheadshot_value.FloatValue;
            //LogMessage("[GG OSK] bomber NON-HEADSHOT damage: %f", damage);
        }
        //LogMessage("[GG2 OSK] profile_clock SHook_TraceAttack %i (%N) (START: %i) (END: %i)", victim, victim, starttime, endtime);
        return Plugin_Changed;
    }

    //LogMessage("[GG2 OSK] profile_clock SHook_TraceAttack %i (%N) (START: %i) (END: %i)", victim, victim, starttime, endtime);
    return Plugin_Continue;
}


public Action OnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype) {

    
    if (damagetype & DMG_BLAST) {
        bool is_changed = false;
        if (IsValidEntity(inflictor)) {
            if (GetClientTeam(victim) == TEAM_1_SEC) {
                char blast_weapon[32];
                GetEdictClassname(inflictor, blast_weapon, sizeof(blast_weapon));
                if (StrEqual(GRENADE_IED, blast_weapon)) {
                    float distance_away = (GetEntitiesDistance(inflictor, victim));
                    float original_distance_away = distance_away;
                    float original_damage = damage;
                    while (distance_away > 75.0) {
                        distance_away -= 75.0;
                        damage = damage / 2.2;
                        is_changed = true;
                    }
                    if (is_changed) {
                        LogMessage("[GG2 DAMAGE] NERFING damage DMG_BLAST: %N // WEAPON: %s // DAMAGE: %f -> %f // ORIGINAL DISTANCE: %f", victim, blast_weapon, original_damage, damage, original_distance_away);
                        return Plugin_Changed;
                    }
                }
            }
        }
    }
    

    if ((!(damagetype & DMG_BULLET)) && (!(damagetype & DMG_SLASH))) {
        return Plugin_Continue;
    }

    if (!IsValidPlayer(attacker)) {
        return Plugin_Continue;
    }
    if(IsFakeClient(attacker)) {
        return Plugin_Continue;
    }
    char weapon[32];
    GetClientWeapon(attacker, weapon, sizeof(weapon));
    
    if ((GetClientTeam(victim) == TEAM_1_SEC) && (StrEqual(weapon, "weapon_defib", false))) {
        return Plugin_Continue;
    }

    if ((GetClientTeam(victim) == TEAM_1_SEC) && (GetClientTeam(attacker) == TEAM_1_SEC)) {
        LogMessage("[GG2 DAMAGE] team_damage // attacker: %N (%s) %N",attacker, weapon, victim);
        
        PrintToChat(victim, "%N If you are in the way, fucking move", victim);
        
        PrintToChat(attacker, "%N Check your fire and watch out for fucking idiots in the way", attacker);
        float old_damage = damage;
        damage = damage / 2.2
        if (g_playerGaveTeamDamageCooldown[attacker] == 0) {
            PrintHintText(victim, "");
            PrintHintText(attacker, "");
            PrintHintText(victim, "If you are in the way, fucking move");
            PrintHintText(attacker, "Check your fire, you are shooting teammates");
            SendForwardTeamDamage(attacker);
            char d_message[512];
            Format(d_message, sizeof(d_message), "__***Attacked Teammate***__ %N (%s)", victim, weapon);
            send_to_discord(attacker, d_message);
            g_playerGaveTeamDamageCooldown[attacker] = 1;
            LogMessage("[GG2 DAMAGE] friendly_damage_reducer %f --> %f",old_damage, damage);
        }

        return Plugin_Changed;
        //PrintToChat("%N Team Damage Reflected. Be Moar Careful.", attacker);
        /*
        if(IsPlayerAlive(attacker)) {
            float ref_damage = damage;
            int attacker_health = GetClientHealth(attacker);
            int to_subtract = RoundFloat(ref_damage * 0.75);
            if ((attacker_health - to_subtract) > 0) {
                attacker_health -= to_subtract;
            } else {
                attacker_health = 1;
            }
            SetEntityHealth(attacker, attacker_health);
            LogMessage("[GG2 DAMAGE] reflect_damage // attacker: %N (%s) %N",attacker, weapon, victim);
            PrintToChatAll("%N Team Damage Reflected. Be Moar Careful.", attacker);
        }
        */
    }
    
    if (is_one_shot_kill(weapon)) {
        //LogMessage("[GG OSK] IS one-shot killed by %N (%s)", attacker, weapon);
        damage = 1024.0;
        //LogMessage("[GG2 OSK] profile_clock osk_ontakedamage %i (%N) (START: %i) (END: %i)", victim, victim, starttime, endtime);
        return Plugin_Changed;
    }

    //LogMessage("[GG2 OSK] profile_clock osk_ontakedamage %i (%N) (START: %i) (END: %i)", victim, victim, starttime, endtime);
    return Plugin_Continue;
} 

public bool is_one_shot_kill(char[] weapon) {
    int range = sizeof(g_one_shot_weapons) - 1;
    for (int i = 0; i <= range; i++) {
        if (StrEqual(weapon, g_one_shot_weapons[i], false)) {
            return true;
        }
    }
    return false;
}

stock float GetEntitiesDistance(int ent1, int ent2) {
    //new Float:orig1[3];
    float orig1[3];
    GetEntPropVector(ent1, Prop_Send, "m_vecOrigin", orig1);
    
    //new Float:orig2[3];
    float orig2[3];
    GetEntPropVector(ent2, Prop_Send, "m_vecOrigin", orig2);

    return GetVectorDistance(orig1, orig2);
} 