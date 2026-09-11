#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

// This should be _way_ more than enough for any reasonable server
int              g_iObjWeaponCache[64] = { 0, ... };

// Counterattacks - cap a point, then hold it while the enemy pushes back - are a checkpoint
// mechanic, and freezing the caches for their duration is the whole point of this plugin.
// m_bCounterAttack is not checkpoint-only though: hunt raises it when a cache goes up, which is what
// mp_hunt_counterattack_distance steers the bots by. Hunt is won by clearing the map rather than by
// outlasting anything, so protecting its caches only stops players finishing the round.
//
// Refreshed on round_start, by which point mp_gamemode is always registered. Same idiom as
// bm2_respawn's g_bCheckpointManaged.
bool             g_bCheckpointMode     = true;

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
    UpdateCheckpointMode();
    SetupCacheTracking();
    return Plugin_Continue;
}

void UpdateCheckpointMode()
{
    bool wasCheckpoint = g_bCheckpointMode;

    ConVar cvGamemode = FindConVar("mp_gamemode");
    if (cvGamemode == null)
    {
        g_bCheckpointMode = true;
    }
    else
    {
        char sGamemode[32];
        cvGamemode.GetString(sGamemode, sizeof(sGamemode));
        g_bCheckpointMode = StrEqual(sGamemode, "checkpoint", false);
    }

    // Only on a change, so this stays one line per map rather than one per round.
    if (g_bCheckpointMode != wasCheckpoint)
    {
        LogMessage("[GG2 Cache Protector] cache protection %s", g_bCheckpointMode ? "enabled (checkpoint)" : "disabled (not checkpoint)");
    }
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
    if (!g_bCheckpointMode || !InCounterAttack()) return Plugin_Continue;

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