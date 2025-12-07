#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

// This should be _way_ more than enough for any reasonable server
int              g_iObjWeaponCache[64] = { 0, ... };

public Plugin myinfo =
{
    name        = "[GG2 Cache Protector]",
    author      = "zachm",
    description = "Protect Caches during counterattacks",
    version     = "0.0.1",
    url         = "http://sourcemod.net/"
};

public void OnPluginStart()
{
    HookEvent("round_start", Event_RoundStart);
    RegAdminCmd("get_cache_protect_count", get_current_caches_protected, ADMFLAG_BAN, "Show how many caches are currently being protected");
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    SetupCacheTracking();
    return Plugin_Continue;
}

public Action get_current_caches_protected(int caller_client, int args)
{
    int res_count = 0;
    for (int i = 0; i < sizeof(g_iObjWeaponCache); i++)
    {
        if (g_iObjWeaponCache[i] == 0) break;

        res_count++;
    }

    char message[64];
    Format(message, sizeof(message), "[GG2 Cache Protector] Found %i protected caches", res_count);

    ReplyToCommand(caller_client, message);

    return Plugin_Continue;
}

int InCounterAttack()
{
    return GameRules_GetProp("m_bCounterAttack");
}

Action CacheOnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype)
{
    if (!InCounterAttack()) return Plugin_Continue;

    LogMessage("[GG2 Cache Protector] Cache damage during counter (damage: %f)", damage);
    damage = 0.0;
    return Plugin_Changed;
}

public void SetupCacheTracking()
{
    // Unhook old caches and reset
    ResetCacheTracker();

    // Hook the new caches
    HookCaches();
}

void ResetCacheTracker()
{
    for (int i = 0; i < sizeof(g_iObjWeaponCache); i++)
    {
        int entRef = g_iObjWeaponCache[i];
        if (entRef == 0) break;

        int entity = EntRefToEntIndex(entRef);
        if (entity != INVALID_ENT_REFERENCE)
        {
            SDKUnhook(entity, SDKHook_OnTakeDamage, CacheOnTakeDamage);
        }

        g_iObjWeaponCache[i] = 0;
    }
}

// Call CacheOnTakeDamage for each cache found
void HookCaches()
{
    int cacheCount = 0;
    for (int i = 0; i < GetMaxEntities(); i++)
    {
        if (i <= MaxClients) continue;
        if (i == INVALID_ENT_REFERENCE) continue;
        if (!IsValidEntity(i)) continue;

        char sClassName[64];
        GetEntityClassname(i, sClassName, 64);

        if (!StrEqual(sClassName, "obj_weapon_cache", false)) continue;

        LogMessage("[GG2 Cache Protector] Found a cache // hooking damage now");

        int cacheEntity = EntIndexToEntRef(i);
        if (cacheEntity == -1) continue;

        // Bounds check before adding to array
        if (cacheCount >= sizeof(g_iObjWeaponCache))
        {
            LogError("[GG2 Cache Protector] Cache array overflow! Max capacity reached.");
            break;
        }

        g_iObjWeaponCache[cacheCount++] = cacheEntity;
        SDKHook(i, SDKHook_OnTakeDamage, CacheOnTakeDamage);
    }
}