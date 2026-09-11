// Heavy .50 BMG ammunition for the M107.
//
// Adds two buyable ammo types to the Barrett: Mk 211 Mod 0 HEIAP, which bursts where it lands, and
// M8 API, which sets fire to it. Both damage, ignite and suppress everything around the point of
// impact rather than only what was hit - so a round into the crate a machine gunner is behind still
// gets the machine gunner.
//
// WHY THIS NEEDS A PLUGIN AT ALL
//
// It cannot be done in the theater. Ammo definitions carry a "damageType" key, but the accepted
// values (DMG_BLAST, DMG_BURN and friends) only relabel the damage - they change how armour and the
// medic system treat it, not where it lands. Bullets in this engine are hitscan traces; there is no
// projectile in flight to detonate. The theater supplies the round's ballistics, scarcity and
// per-bullet suppression, and everything spatial happens here.
//
// WHY IT IS CHEAP
//
// The obvious implementation - spawn a grenade entity per bullet - is the expensive one. Tracers
// show the cheaper shape the engine already uses: a one-shot effect plus, here, a direct damage
// loop. No explosive entity is created, so there is no edict per shot, no physics and no think.
// The M107 is 450rpm semi-automatic with an 11-round magazine, and sm_heavyammo_cooldown throttles
// the rest.
//
// Rounds are defined in configs/heavyammo.cfg, one block each, the same shape FireSupport uses.
// Adding a round to another weapon is a theater entry plus a config block - no code change.
//
// Each block names a theater upgrade, and gg2_theater_items resolves that name to its id on every
// map, so the ids cannot go stale when the theater is edited. Which weapons a round can be mounted
// on is already decided by the upgrade's own allowed_weapons in the theater; the optional "weapons"
// key here is a further filter, not the gate.
//
// See gg2_heavy_ammo.md for the round data.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <morecolors>
#include <theateritems>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name        = "[GG2 Heavy Ammo] Mk 211 / API",
    author      = "solidDoWant",
    description = "Explosive and incendiary .50 BMG rounds for the M107",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

#define TEAM_SPEC   1
#define TEAM_SEC    2
#define TEAM_INS    3

// CINSBotBody's arousal float. Same offset gg2_bot_smoke_suppress reads: CINSBotCombat::Update
// gates its whole suppression path on IsMinArousal(8), which is round(*(float*)(this+0x138)) >= arg.
#define AROUSAL_OFFSET  0x138

#define MAX_ROUNDS      16
#define MAX_NAME_LEN    64

enum struct HeavyRound
{
    char  name[MAX_NAME_LEN];        // config block name, used in logs
    char  upgrade[MAX_NAME_LEN];     // theater upgrade name, resolved to an id each map
    char  weapons[256];              // optional comma-separated classname filter; empty = any
    int   upgradeId;

    float radius;
    float damage;
    int   damageType;
    float burnTime;
    float burnRadius;
    float suppressRadius;
    float suppressArousal;
    float cooldown;
    bool  selfDamage;

    char  particle[MAX_NAME_LEN];
    char  sound[PLATFORM_MAX_PATH];
}

HeavyRound g_Rounds[MAX_ROUNDS];
int        g_NumRounds = 0;

Handle g_hMyNextBotPointer   = null;
Handle g_hGetBodyInterface   = null;
bool   g_bSuppressionReady   = false;

ConVar g_cvEnabled;
ConVar g_cvFriendlyFire;

float  g_LastShot[MAXPLAYERS + 1];

public void OnPluginStart()
{
    CreateConVar("sm_heavyammo_version", PLUGIN_VERSION, "Heavy ammo version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar("sm_heavyammo_enabled", "1", "Master switch.", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "plugin.heavyammo");

    RegAdminCmd("sm_heavyammo_scan", Command_Scan, ADMFLAG_CONFIG, "Print the upgrades installed on the weapon you are holding, by name");
    RegAdminCmd("sm_heavyammo_reload", Command_Reload, ADMFLAG_CONFIG, "Re-read configs/heavyammo.cfg");

    HookEvent("weapon_fire", Event_WeaponFire);

    g_cvFriendlyFire = FindConVar("mp_friendlyfire");

    SetupSuppression();
    LoadRounds();
}

// One block per round, same shape as configs/firesupport.cfg. Every key has a default, so a block
// only has to state what it changes - the minimum useful entry is a name and an "upgrade".
void LoadRounds()
{
    g_NumRounds = 0;

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/heavyammo.cfg");

    KeyValues kv = new KeyValues("HeavyAmmo");
    if (!kv.ImportFromFile(path))
    {
        LogError("Failed to load %s - no rounds will do anything", path);
        delete kv;
        return;
    }

    if (kv.GotoFirstSubKey())
    {
        do
        {
            if (g_NumRounds >= MAX_ROUNDS)
            {
                LogError("Maximum rounds (%d) reached, ignoring the rest of the config", MAX_ROUNDS);
                break;
            }

            HeavyRound round;
            kv.GetSectionName(round.name, sizeof(round.name));
            kv.GetString("upgrade", round.upgrade, sizeof(round.upgrade), "");

            if (round.upgrade[0] == '\0')
            {
                LogError("Round \"%s\" has no \"upgrade\" key - skipped", round.name);
                continue;
            }

            ReadWeaponFilter(kv, round.weapons, sizeof(round.weapons));
            round.radius          = kv.GetFloat("radius", 200.0);
            round.damage          = kv.GetFloat("damage", 60.0);
            round.burnTime        = kv.GetFloat("burn_time", 0.0);
            round.burnRadius      = kv.GetFloat("burn_radius", 0.0);
            round.suppressRadius  = kv.GetFloat("suppress_radius", 0.0);
            round.suppressArousal = kv.GetFloat("suppress_arousal", 12.0);
            round.cooldown        = kv.GetFloat("cooldown", 0.25);
            round.selfDamage      = view_as<bool>(kv.GetNum("self_damage", 1));
            kv.GetString("particle", round.particle, sizeof(round.particle), "");
            kv.GetString("sound", round.sound, sizeof(round.sound), "");

            char damageType[16];
            kv.GetString("damage_type", damageType, sizeof(damageType), "blast");
            round.damageType = ParseDamageType(damageType);

            round.upgradeId = 0;
            g_Rounds[g_NumRounds] = round;
            g_NumRounds++;

            LogMessage("Loaded round %s: upgrade=%s radius=%.0f damage=%.0f burn=%.1fs/%.0fu suppress=%.0fu cooldown=%.2f",
                       round.name, round.upgrade, round.radius, round.damage,
                       round.burnTime, round.burnRadius, round.suppressRadius, round.cooldown);
        }
        while (kv.GotoNextKey());
    }

    delete kv;

    // Ids come from the theater, which is already loaded by the time a reload is run by hand.
    if (TheaterItem_Ready()) ResolveRounds();
}

// The optional weapon filter, written the way the theater writes the same idea:
//
//     "weapons"
//     {
//         "weapon"  "weapon_m107"
//         "weapon"  "weapon_svd"
//     }
//
// which is exactly the shape of an upgrade's own allowed_weapons block, so the two read alike when
// you have both files open. A flat "weapons" "a,b" is still accepted - it costs four lines to take
// both, and silently ignoring a filter someone wrote the other way would be a nasty way to find out.
//
// Stored joined by commas because that is all WeaponMatches needs; the shape is a config question,
// not a runtime one.
void ReadWeaponFilter(KeyValues kv, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (kv.JumpToKey("weapons"))
    {
        // false = iterate values as well as sections, which is what repeated "weapon" keys are.
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char value[64];
                kv.GetString(NULL_STRING, value, sizeof(value));
                TrimString(value);
                if (value[0] == '\0') continue;

                if (buffer[0] != '\0') StrCat(buffer, maxlen, ",");
                StrCat(buffer, maxlen, value);
            }
            while (kv.GotoNextKey(false));

            kv.GoBack();
        }

        kv.GoBack();
    }

    // Flat form. Only reached when the section form produced nothing, so a section always wins.
    if (buffer[0] == '\0') kv.GetString("weapons", buffer, maxlen, "");
}

// DMG_BLAST and DMG_BURN are the two that matter - blast for a bursting round, burn for an
// incendiary - but the damage type also decides how armour, the medic system and gg2_burn treat
// the hit, so it is left configurable rather than inferred from whether burn_time is set.
int ParseDamageType(const char[] name)
{
    if (StrEqual(name, "burn", false))   return DMG_BURN;
    if (StrEqual(name, "bullet", false)) return DMG_BULLET;
    if (StrEqual(name, "slash", false))  return DMG_SLASH;
    if (StrEqual(name, "shock", false))  return DMG_SHOCK;
    return DMG_BLAST;
}

public Action Command_Reload(int client, int args)
{
    LoadRounds();
    ReplyToCommand(client, "[Heavy Ammo] Reloaded: %d round(s).", g_NumRounds);
    return Plugin_Handled;
}

// Reaching a bot's arousal needs two calls: the player's INextBot, then that bot's body. Both come
// from tug2.games, and both are already used in production by gg2_bot_smoke_suppress.
//
// Missing gamedata is not fatal. The blast and the fire are the feature; suppression is the part
// that degrades, and it says so once rather than on every shot.
void SetupSuppression()
{
    Handle conf = LoadGameConfigFile("tug2.games");
    if (conf == null)
    {
        LogError("Missing gamedata \"tug2.games\" - impacts will not suppress bots");
        return;
    }

    StartPrepSDKCall(SDKCall_Player);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "NextBotPlayer_CINSPlayer::MyNextBotPointer"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hMyNextBotPointer = EndPrepSDKCall();
    }

    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "INextBot::GetBodyInterface"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hGetBodyInterface = EndPrepSDKCall();
    }
    delete conf;

    g_bSuppressionReady = (g_hMyNextBotPointer != null && g_hGetBodyInterface != null);
    if (!g_bSuppressionReady)
        LogError("Could not prepare the nextbot calls - impacts will not suppress bots");
}

public void OnClientDisconnect(int client)
{
    g_LastShot[client] = 0.0;
}

public Action Command_Scan(int client, int args)
{
    if (client < 1)
    {
        ReplyToCommand(client, "[Heavy Ammo] Run this in game while holding the weapon.");
        return Plugin_Handled;
    }

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= 0 || !HasEntProp(weapon, Prop_Send, "m_upgradeSlots"))
    {
        ReplyToCommand(client, "[Heavy Ammo] You are not holding a weapon with upgrade slots.");
        return Plugin_Handled;
    }

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));
    ReplyToCommand(client, "[Heavy Ammo] %s: weapon def %d, ammo type %d",
                   classname,
                   GetEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle"),
                   HasEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType") ? GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType") : -1);

    int slots = GetEntPropArraySize(weapon, Prop_Send, "m_upgradeSlots");
    for (int i = 0; i < slots; i++)
    {
        int id = GetEntProp(weapon, Prop_Send, "m_upgradeSlots", 4, i);
        if (id <= 0) continue;

        char name[64];
        if (!TheaterItem_Name(TheaterCategory_Upgrade, id, name, sizeof(name))) strcopy(name, sizeof(name), "?");
        ReplyToCommand(client, "[Heavy Ammo]   upgrade slot %d = %d (%s)", i, id, name);
    }

    return Plugin_Handled;
}

// Theater item ids are assigned at parse time and move whenever the theater is edited, so they are
// looked up by name once per map rather than configured.
public void TheaterItems_OnReady()
{
    ResolveRounds();
}

void ResolveRounds()
{
    for (int i = 0; i < g_NumRounds; i++)
    {
        g_Rounds[i].upgradeId = TheaterItem_Find(TheaterCategory_Upgrade, g_Rounds[i].upgrade);

        if (g_Rounds[i].upgradeId == 0)
            LogError("Round \"%s\": upgrade \"%s\" is not in the loaded theater - it will behave as ordinary ammunition",
                     g_Rounds[i].name, g_Rounds[i].upgrade);
        else
            LogMessage("Round \"%s\": %s = %d", g_Rounds[i].name, g_Rounds[i].upgrade, g_Rounds[i].upgradeId);
    }
}

// Index of the configured round loaded in this weapon, or -1.
//
// The upgrade id is the whole test. Which weapons may mount it is already settled by the upgrade's
// allowed_weapons in the theater, so no classname check is needed for correctness - "weapons" is an
// optional extra filter for when a round should only take effect on some of them.
int GetLoadedRound(int weapon)
{
    if (g_NumRounds < 1) return -1;
    if (!HasEntProp(weapon, Prop_Send, "m_upgradeSlots")) return -1;

    int slots = GetEntPropArraySize(weapon, Prop_Send, "m_upgradeSlots");

    for (int i = 0; i < g_NumRounds; i++)
    {
        if (g_Rounds[i].upgradeId <= 0) continue;

        bool installed = false;
        for (int slot = 0; slot < slots && !installed; slot++)
            if (GetEntProp(weapon, Prop_Send, "m_upgradeSlots", 4, slot) == g_Rounds[i].upgradeId) installed = true;

        if (!installed) continue;
        if (!WeaponMatches(weapon, g_Rounds[i].weapons)) continue;

        return i;
    }

    return -1;
}

bool WeaponMatches(int weapon, const char[] filter)
{
    if (filter[0] == '\0') return true;

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));

    char names[16][64];
    int  count = ExplodeString(filter, ",", names, sizeof(names), sizeof(names[]));
    for (int i = 0; i < count; i++)
    {
        TrimString(names[i]);
        if (names[i][0] != '\0' && StrEqual(names[i], classname, false)) return true;
    }

    return false;
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue) return;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client)) return;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon <= 0) return;

    int round = GetLoadedRound(weapon);
    if (round < 0) return;

    float now = GetGameTime();
    if (now - g_LastShot[client] < g_Rounds[round].cooldown) return;
    g_LastShot[client] = now;

    // Where the round landed.
    //
    // There is no bullet-impact event and no projectile to follow, so this traces the shot itself.
    // It is the shooter's aim rather than the bullet's exact path, so it ignores spread - but the
    // effect is a radius of hundreds of units and the M107's spread is 0.04, which at any range
    // that matters is a rounding error against that. The important part is that it hits the WORLD,
    // so a round into a wall or a crate produces an impact point exactly as a round into a body
    // does. That is what makes "hit the cover, kill the man behind it" work.
    float impact[3];
    if (!TraceShot(client, impact)) return;

    ApplyImpact(client, weapon, round, impact);
}

bool TraceShot(int client, float impact[3])
{
    float eye[3], angles[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, angles);

    Handle trace = TR_TraceRayFilterEx(eye, angles, MASK_SHOT, RayType_Infinite, TraceFilter_NotSelf, client);
    if (trace == null) return false;

    bool hit = TR_DidHit(trace);
    if (hit) TR_GetEndPosition(impact, trace);
    delete trace;

    return hit;
}

public bool TraceFilter_NotSelf(int entity, int mask, any data)
{
    return entity != data;
}

// Everything spatial. One effect, one damage loop, one suppression loop - no entities beyond the
// short-lived particle.
void ApplyImpact(int attacker, int weapon, int round, const float impact[3])
{
    float radius     = g_Rounds[round].radius;
    float maxDamage  = g_Rounds[round].damage;
    float burnTime   = g_Rounds[round].burnTime;
    float burnRadius = g_Rounds[round].burnRadius;
    int   damageType = g_Rounds[round].damageType;

    SpawnEffect(impact, round);

    bool allowFriendly = (g_cvFriendlyFire != null && g_cvFriendlyFire.BoolValue);
    bool allowSelf     = g_Rounds[round].selfDamage;
    int  attackerTeam  = GetClientTeam(attacker);

    for (int victim = 1; victim <= MaxClients; victim++)
    {
        if (!IsClientInGame(victim) || !IsPlayerAlive(victim)) continue;

        int team = GetClientTeam(victim);
        if (team == TEAM_SPEC) continue;

        bool isSelf = (victim == attacker);
        if (isSelf && !allowSelf) continue;
        if (!isSelf && team == attackerTeam && !allowFriendly) continue;

        float centre[3];
        GetClientCentre(victim, centre);

        float distance = GetVectorDistance(impact, centre);

        // Suppression first, and on a wider radius than the damage. A near miss that hurts nobody
        // should still ruin the aim of everyone around it.
        if (distance <= g_Rounds[round].suppressRadius && !isSelf && team != attackerTeam)
            SuppressBot(victim, g_Rounds[round].suppressArousal);

        if (distance > radius) continue;
        if (!HasLineOfEffect(impact, centre, victim)) continue;

        float falloff = 1.0 - (distance / radius);
        float damage  = maxDamage * falloff;

        if (damage >= 1.0)
        {
            float force[3];
            SubtractVectors(centre, impact, force);
            NormalizeVector(force, force);
            ScaleVector(force, damage * 10.0);

            SDKHooks_TakeDamage(victim, attacker, attacker, damage, damageType, weapon, force, impact);
        }

        if (burnTime > 0.0 && distance <= burnRadius && IsPlayerAlive(victim))
            IgniteEntity(victim, burnTime);
    }
}

// Walls stop the blast. Without this a round into one side of a building would kill everyone on the
// other side of it, which is both wrong and impossible to play around.
bool HasLineOfEffect(const float impact[3], const float target[3], int victim)
{
    Handle trace = TR_TraceRayFilterEx(impact, target, MASK_SOLID, RayType_EndPoint, TraceFilter_NotSelf, victim);
    if (trace == null) return true;

    bool blocked = TR_DidHit(trace);
    delete trace;

    return !blocked;
}

void GetClientCentre(int client, float centre[3])
{
    float mins[3], maxs[3];
    GetClientAbsOrigin(client, centre);
    GetClientMins(client, mins);
    GetClientMaxs(client, maxs);
    centre[2] += (mins[2] + maxs[2]) / 2.0;
}

// The visual and the sound, as a one-shot particle rather than an explosive entity. The effect
// names are the ones the theater already uses for the 40mm and the molotov, so they are precached
// by the theater and cost this plugin nothing to reference.
void SpawnEffect(const float impact[3], int round)
{
    if (g_Rounds[round].sound[0] != '\0')
        EmitAmbientSound(g_Rounds[round].sound, impact, SOUND_FROM_WORLD, SNDLEVEL_RAIDSIREN);

    if (g_Rounds[round].particle[0] == '\0') return;

    int particle = CreateEntityByName("info_particle_system");
    if (particle <= 0) return;

    DispatchKeyValue(particle, "effect_name", g_Rounds[round].particle);
    DispatchSpawn(particle);
    ActivateEntity(particle);
    TeleportEntity(particle, impact, NULL_VECTOR, NULL_VECTOR);
    AcceptEntityInput(particle, "Start");

    CreateTimer(2.0, Timer_KillParticle, EntIndexToEntRef(particle), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_KillParticle(Handle timer, int ref)
{
    int particle = EntRefToEntIndex(ref);
    if (particle != INVALID_ENT_REFERENCE && IsValidEntity(particle))
        AcceptEntityInput(particle, "Kill");

    return Plugin_Stop;
}

// Raises a bot's arousal to the suppression ceiling.
//
// Arousal is what the game's own suppression feeds - ins_bot_arousal_suppression_max is its cap -
// and the ins_bot_arousal_frac_* cvars are what turn it into behaviour: at the top of the range a
// bot's aim tolerance and aim tracking both get worse. It also reacts faster, which is why this
// raises arousal to a configured level rather than pinning it: a bot that is rattled should be
// worse at shooting, not simply more alert.
void SuppressBot(int client, float target)
{
    if (!g_bSuppressionReady || !IsFakeClient(client)) return;

    int nextbot = SDKCall(g_hMyNextBotPointer, client);
    if (nextbot == 0) return;

    int body = SDKCall(g_hGetBodyInterface, nextbot);
    if (body == 0) return;

    Address at      = view_as<Address>(body + AROUSAL_OFFSET);
    float   current = view_as<float>(LoadFromAddress(at, NumberType_Int32));

    if (target <= 0.0 || current >= target) return;

    StoreToAddress(at, view_as<int>(target), NumberType_Int32);
}
