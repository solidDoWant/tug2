#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

int g_iObjWeaponCache[65535] = {0, ...};
int iCacheCount = 0;
char g_sMapName[128];

//native int Ins_ObjectiveResource_GetProp(const char[] prop, int size = 4, int element = 0);
// bool InCounterAttack() {
//     bool retval;
//     retval = view_as<bool>(GameRules_GetProp("m_bCounterAttack"));
//     return retval;
// }

public Plugin myinfo = {
	name = "[GG2 Cache Protector]",
	author = "zachm",
	description = "Protect Caches during counterattacks",
	version = "0.0.1",
	url = "http://sourcemod.net/"
};

public void OnPluginStart() {
    HookEvent("round_start", Event_RoundStart);
    RegAdminCmd("get_cache_protect_count", get_current_caches_protected, ADMFLAG_BAN, "Show how many caches are currently being protected");
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    run_cache_check();
    GetCurrentMap(g_sMapName, sizeof(g_sMapName));
    return Plugin_Continue;
}

public Action get_current_caches_protected(int caller_client, int args) {
    int res_count = 0;
    for (int i = 0; i <= sizeof(g_iObjWeaponCache); i++) {
        if (g_iObjWeaponCache[i] != 0) {
            res_count++;
        } else {
            break;
        }
    }
    char message[1024];
    Format(message, sizeof(message), "[GG2 Cache Protector] Found %i protected caches", res_count);
    ReplyToCommand(caller_client, message);
    return Plugin_Continue;
}

// public void OnMapStart() {
//     run_cache_check();
//     GetCurrentMap(g_sMapName, sizeof(g_sMapName));
// }

int InCounterAttack() {
	return GameRules_GetProp("m_bCounterAttack");
}

Action CacheOnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype) {
    //LogMessage("[GG2 Cache Protector]!!!!!!!!!!!! A CACHE TOOK SOME DAMAGE.........");
    if (InCounterAttack()) {
    //if (InCounterAttack()) {
        LogMessage("[GG2 Cache Protector] Cache damage during counter (%s) // damage: %f", g_sMapName, damage);
        damage = 0.0;
        return Plugin_Changed;
    } else {
        LogMessage("[GG2 Cache Protector] was not in counterattack, damage as normal");
    }
    return Plugin_Continue;
}

public void run_cache_check() {
    for (int i = 0;i < GetMaxEntities();i++) {
        if (i > MaxClients && i != INVALID_ENT_REFERENCE && IsValidEntity(i)) {
            char sClassName[64];
            GetEntityClassname(i, sClassName, 64);
            if (StrEqual(sClassName, "obj_weapon_cache", false)) {
                LogMessage("[GG2 Cache Protector] Found a cache // hooking damage now");
                g_iObjWeaponCache[iCacheCount++] = EntIndexToEntRef(i);
                SDKHook(i, SDKHook_OnTakeDamage, CacheOnTakeDamage);
            }
        }
    }

}