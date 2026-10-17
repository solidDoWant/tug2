// Suicide bomber bots.
//
// The theater already spawns a bomber class (template_coop_bomber - a civilian model with a knife and
// a Deagle, one slot in each insurgent squad) but nothing made it any different from a rifleman. This
// is the missing half: an armed bomber drops its gun, runs at the nearest Security player, and when
// one is in sight and in range it arms an IED - trigger click, a yell, a few beeps - and detonates.
// Shooting it can set it off early; a headshot or a melee kill never does.
//
// WHY THE BOT RUNS AT PLAYERS
//
// Nothing here steers it. CINSBotAttack::InitialContainedAction picks the attack behaviour from the
// active weapon's class (see the note in gamedata/tug2.games.txt), and a bot holding only a melee
// weapon gets CINSBotAttackMelee, which closes to contact. Stripping the Deagle is the whole trick.
//
// HOW IT DETONATES
//
// A real grenade_ied is spawned on the bomber and damaged. The theater sets ReactExplosions on it, so
// blast damage sets it off exactly as if its owner had pressed the clicker. Using the real entity
// rather than a synthetic explosion keeps everything downstream correct for free: the kill feed shows
// the IED, gg2_damage's distance falloff for grenade_ied applies, and bm2_respawn's fatal-wound check
// already lists grenade_ied. That falloff is steep (damage / 2.2 per 75 units), which is why the
// default trigger range is short.
//
// Mechanics after the DY/jballou "bsuicide_bomb_redux" plugin, whose voice lines these are.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <classtemplate>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name        = "[GG2 BOMBER] Suicide bombers",
    author      = "solidDoWant",
    description = "Bomber-class bots charge Security players and detonate an IED",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

#define TEAM_SEC                2
#define TEAM_INS                3

#define HITGROUP_GENERIC        0
#define HITGROUP_HEAD           1
#define HITGROUP_CHEST          2
#define HITGROUP_STOMACH        3
#define HITGROUP_LEFTARM        4
#define HITGROUP_RIGHTLEG       7

#define GAMESTATE_ROUND_RUNNING 4

#define LOOP_INTERVAL           0.1
// Long enough that a grenade_ied which was going to go off has done so.
#define DETONATION_CHECK_DELAY  2.0
// grenade_ied's theater "Health" is 50; one point of blast damage is enough once it is lowered to 1.
#define IED_TRIGGER_DAMAGE      10.0
// Where on the body a dead bomber's IED goes off, relative to its origin.
#define CORPSE_BOMB_HEIGHT      40.0

#define SOUND_TRIGGER           "weapons/ied/handling/ied_trigger_ins.wav"
#define SOUND_BEEP              "ui/sfx/beep.wav"

// Delivered to clients by fastdl (fastdl/src/sound/gg2_bomber/) and also shipped in the server image.
char g_detonateYells[][] = {
    "gg2_bomber/allahu_akbar01.ogg",
    "gg2_bomber/allahu_akbar02.ogg",
    "gg2_bomber/detonate01.ogg",
    "gg2_bomber/detonate02.ogg"
};

char g_roamYells[][] = {
    "gg2_bomber/roam01.ogg",
    "gg2_bomber/roam02.ogg",
    "gg2_bomber/roam03.ogg",
    "gg2_bomber/roam04.ogg",
    "gg2_bomber/roam05.ogg",
    "gg2_bomber/roam06.ogg",
    "gg2_bomber/roam07.ogg",
    "gg2_bomber/roam08.ogg",
    "gg2_bomber/roam09.ogg",
    "gg2_bomber/roam10.ogg",
    "gg2_bomber/roam11.ogg"
};

// Whatever a bomber may keep when its guns are stripped. If it holds none of these the strip is
// skipped, since a bot with no weapon at all has no attack behaviour to run.
char g_meleeWeapons[][] = {
    "weapon_kabar",
    "weapon_gurkha",
    "weapon_knife",
    "weapon_sandstorm_kabar"
};

// Damage from any of these never sets a bomb off - not as a panic hit, and not through the dead
// man's switch. Matched as substrings so they hold whether an event names the weapon "weapon_kabar"
// or "kabar". The defib is a melee-class weapon in the theater too.
char g_meleeDamage[][] = {
    "kabar",
    "gurkha",
    "knife",
    "defib"
};

enum BomberState
{
    Bomber_None,         // not a bomber, or an unarmed one
    Bomber_Armed,        // hunting
    Bomber_Lit,          // fuse burning
    Bomber_Detonated     // IED spawned; the bomber's own death is expected next
};

ConVar      g_cvEnabled;
ConVar      g_cvArmedChance;
ConVar      g_cvStripWeapons;
ConVar      g_cvSpeed;
ConVar      g_cvTriggerRange;
ConVar      g_cvFuse;
ConVar      g_cvBeepInterval;
ConVar      g_cvSpawnGrace;
ConVar      g_cvRoamInterval;
ConVar      g_cvPanicChest;
ConVar      g_cvPanicLimb;
ConVar      g_cvPanicExplosive;
ConVar      g_cvPanicFire;

bool        g_isBomberClass[MAXPLAYERS + 1];
BomberState g_state[MAXPLAYERS + 1];
float       g_spawnTime[MAXPLAYERS + 1];
float       g_fuseEnd[MAXPLAYERS + 1];
float       g_nextBeep[MAXPLAYERS + 1];
float       g_nextRoam[MAXPLAYERS + 1];
// When the last IED was spawned, by any bomber. A failed detonation logs the gap, to show whether
// it happened inside another bomber's blast.
float       g_lastIEDTime = -1000.0;
int         g_lastHitgroup[MAXPLAYERS + 1];
bool        g_speedChanged[MAXPLAYERS + 1];
// The IED of a living bomber, kept on its body until it goes off.
int         g_bombRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
// Every IED this plugin spawned, by entity index: its reference (so a reused index does not match)
// and the bomber's userid. OnTakeDamage credits the blast to that bomber - see SpawnIED.
int         g_iedRef[2048] = { INVALID_ENT_REFERENCE, ... };
int         g_iedOwner[2048];
// Loaded mid-map (a reload or hot patch) - see RestoreLateLoadState
bool        g_bLateLoad = false;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_bLateLoad = late;
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvEnabled        = CreateConVar("gg_bomber_enabled", "1", "Enable suicide bombers", _, true, 0.0, true, 1.0);
    g_cvArmedChance    = CreateConVar("gg_bomber_armed_chance", "1.0", "Chance a bomber-class bot spawns armed. Unarmed ones behave like any other bot.", _, true, 0.0, true, 1.0);
    g_cvStripWeapons   = CreateConVar("gg_bomber_strip_weapons", "1", "Leave armed bombers only their knife, which is what makes them charge", _, true, 0.0, true, 1.0);
    g_cvSpeed          = CreateConVar("gg_bomber_speed", "1.0", "Movement speed multiplier for armed bombers", _, true, 0.1, true, 3.0);
    g_cvTriggerRange   = CreateConVar("gg_bomber_trigger_range", "250.0", "Distance to a visible Security player at which the fuse is lit. gg2_damage's IED falloff makes the blast weak much beyond ~200.", _, true, 0.0);
    g_cvFuse           = CreateConVar("gg_bomber_fuse", "1.0", "Seconds between lighting the fuse and the explosion. The bomber keeps running meanwhile.", _, true, 0.0);
    g_cvBeepInterval   = CreateConVar("gg_bomber_beep_interval", "0.3", "Seconds between beeps while the fuse burns", _, true, 0.1);
    g_cvSpawnGrace     = CreateConVar("gg_bomber_spawn_grace", "3.0", "Seconds after spawning before a bomber can light its fuse", _, true, 0.0);
    g_cvRoamInterval   = CreateConVar("gg_bomber_roam_interval", "15.0", "Average seconds between an armed bomber's yells while hunting. 0 disables.", _, true, 0.0);
    g_cvPanicChest     = CreateConVar("gg_bomber_panic_chest_chance", "0.5", "Chance a chest or stomach hit sets the bomb off", _, true, 0.0, true, 1.0);
    g_cvPanicLimb      = CreateConVar("gg_bomber_panic_limb_chance", "0.25", "Chance an arm or leg hit sets the bomb off", _, true, 0.0, true, 1.0);
    g_cvPanicExplosive = CreateConVar("gg_bomber_panic_explosive_chance", "0.75", "Chance explosive damage sets the bomb off (including another bomber's)", _, true, 0.0, true, 1.0);
    g_cvPanicFire      = CreateConVar("gg_bomber_panic_fire_chance", "0.15", "Chance fire damage sets the bomb off", _, true, 0.0, true, 1.0);
    AutoExecConfig(true, "gg2_bomber");

    ClassTemplate_Init();

    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_hurt", Event_PlayerHurt);
    HookEvent("player_death", Event_PlayerDeath);

    RegAdminCmd("sm_bomber_status", Command_Status, ADMFLAG_GENERIC,
                "List every bomber-class bot: state, active weapon, weapons held, nearest Security player and line of sight");
}

// Diagnostic: a bomber that "just stands there" looks the same from outside whatever the cause, so
// this prints the things that tell the causes apart - whether it is armed at all, what it is holding
// (no active weapon leaves the engine nothing to pick an attack behaviour from; a pistol means the
// strip did not happen), and whether a Security player is near and visible to it.
public Action Command_Status(int caller, int args)
{
    float now = GetGameTime();
    int shown = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || !g_isBomberClass[client]) continue;

        static const char stateNames[][] = { "none", "armed", "lit", "detonated" };
        int  state = view_as<int>(g_state[client]);
        bool alive = IsPlayerAlive(client);

        char active[64] = "<none>";
        char held[256];
        if (alive)
        {
            int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
            if (weapon > 0 && IsValidEntity(weapon)) GetEntityClassname(weapon, active, sizeof(active));

            int slots = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
            for (int i = 0; i < slots; i++)
            {
                int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
                if (w <= 0 || !IsValidEntity(w)) continue;
                char cls[64];
                GetEntityClassname(w, cls, sizeof(cls));
                Format(held, sizeof(held), "%s%s%s", held, held[0] == '\0' ? "" : ",", cls);
            }
        }

        // Nearest living Security player, and whether the bomber has an unobstructed line to them.
        float bomberEye[3], targetEye[3];
        int   nearest = 0;
        float best    = 0.0;
        bool  visible = false;
        if (alive)
        {
            GetClientEyePosition(client, bomberEye);
            for (int target = 1; target <= MaxClients; target++)
            {
                if (!IsClientInGame(target) || !IsPlayerAlive(target) || GetClientTeam(target) != TEAM_SEC) continue;
                GetClientEyePosition(target, targetEye);
                float d = GetVectorDistance(bomberEye, targetEye);
                if (nearest == 0 || d < best)
                {
                    nearest = target;
                    best    = d;
                    TR_TraceRayFilter(bomberEye, targetEye, MASK_SOLID, RayType_EndPoint, TraceFilter_IgnorePlayers);
                    visible = !TR_DidHit();
                }
            }
        }

        float vel[3];
        if (alive) GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);

        ReplyToCommand(caller, "[Bomber] %N: %s, state=%s, alive %.0fs, speed=%.0f u/s, active=%s, held=[%s], nearest Security=%s %.0fu (%.0f ft) %s",
                       client, alive ? "alive" : "dead",
                       (state >= 0 && state < sizeof(stateNames)) ? stateNames[state] : "?",
                       alive ? now - g_spawnTime[client] : 0.0,
                       alive ? SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]) : 0.0,
                       active, held,
                       nearest ? "" : "none", best, best / 16.0,
                       nearest ? (visible ? "visible" : "not visible") : "");
        shown++;
    }

    if (shown == 0) ReplyToCommand(caller, "[Bomber] No bomber-class bots in game.");
    return Plugin_Handled;
}

public void OnMapStart()
{
    PrecacheSound(SOUND_TRIGGER);
    PrecacheSound(SOUND_BEEP);
    for (int i = 0; i < sizeof(g_detonateYells); i++) PrecacheSound(g_detonateYells[i]);
    for (int i = 0; i < sizeof(g_roamYells); i++) PrecacheSound(g_roamYells[i]);

    for (int client = 1; client <= MaxClients; client++) ResetClient(client);
    g_lastIEDTime = -1000.0;    // game time restarts with the map

    CreateTimer(LOOP_INTERVAL, Timer_BomberLoop, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// A late load's restore waits for this: OnMapStart, which a late load also runs, resets every client.
public void OnConfigsExecuted()
{
    if (!g_bLateLoad) return;
    g_bLateLoad = false;
    RestoreLateLoadState();
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

// Credit this plugin's IEDs to their bomber - see SpawnIED.
public Action OnTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype)
{
    if (inflictor <= MaxClients || inflictor >= sizeof(g_iedRef)) return Plugin_Continue;
    if (g_iedRef[inflictor] == INVALID_ENT_REFERENCE || EntRefToEntIndex(g_iedRef[inflictor]) != inflictor)
        return Plugin_Continue;

    int bomber = GetClientOfUserId(g_iedOwner[inflictor]);
    if (bomber == 0 || attacker == bomber) return Plugin_Continue;

    attacker = bomber;
    return Plugin_Changed;
}

// A reload or hot patch misses every player_pick_squad and player_spawn already made, so every
// bomber would carry on as an ordinary bot until it next died. Rebuild from the game instead.
void RestoreLateLoadState()
{
    int armed = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)) continue;

        OnClientPutInServer(client);
        if (!IsFakeClient(client)) continue;

        char classTemplate[64];
        if (!ClassTemplate_Get(client, classTemplate, sizeof(classTemplate))) continue;
        g_isBomberClass[client] = StrContains(classTemplate, "bomber") != -1;

        if (IsPlayerAlive(client))
        {
            ArmBomber(client);
            if (g_state[client] == Bomber_Armed) armed++;
        }
    }
    LogMessage("late load: re-armed %d living bomber(s)", armed);
}

public void OnClientDisconnect(int client)
{
    ResetClient(client);
    g_isBomberClass[client] = false;
}

void ResetClient(int client)
{
    g_state[client]        = Bomber_None;
    g_lastHitgroup[client] = HITGROUP_GENERIC;
    g_bombRef[client]      = INVALID_ENT_REFERENCE;
}

// ---------------------------------------------------------------------------------------- events

public void Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client == 0 || !IsFakeClient(client)) return;

    char classTemplate[64];
    event.GetString("class_template", classTemplate, sizeof(classTemplate));
    g_isBomberClass[client] = StrContains(classTemplate, "bomber") != -1;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client == 0) return;

    ResetClient(client);
    // m_flLaggedMovementValue lives on the player entity and survives death.
    RestoreSpeed(client);

    ArmBomber(client);
}

// Turn a freshly spawned (or, on a late load, already living) bomber-class bot into a bomber.
void ArmBomber(int client)
{
    if (!g_cvEnabled.BoolValue || !g_isBomberClass[client] || !IsFakeClient(client)) return;
    if (GetClientTeam(client) != TEAM_INS) return;
    if (GetURandomFloat() >= g_cvArmedChance.FloatValue) return;

    float now             = GetGameTime();
    g_state[client]     = Bomber_Armed;
    g_spawnTime[client] = now;
    // Desynchronised, so a squad of bombers spawning together does not yell in unison.
    g_nextRoam[client]  = now + GetRandomFloat(0.0, g_cvRoamInterval.FloatValue);

    // The spawn loadout is handed out after player_spawn; bm2_respawn waits the same 0.5s to edit it.
    CreateTimer(0.5, Timer_PrepareBomber, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim == 0) return;

    int hitgroup           = event.GetInt("hitgroup");
    g_lastHitgroup[victim] = hitgroup;

    if (g_state[victim] != Bomber_Armed && g_state[victim] != Bomber_Lit) return;

    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));
    if (IsMeleeDamage(weapon)) return;

    float chance = PanicChance(hitgroup, weapon);
    if (chance <= 0.0 || GetURandomFloat() >= chance) return;

    // The killing blow fires player_hurt too, with the victim already at 0 health.
    if (event.GetInt("health") > 0)
    {
        YellDetonate(victim);
        DetonateOnBody(victim, "panic");
    }
    else
    {
        DetonateOnCorpse(victim, "panic-kill");
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim == 0) return;

    // Dead man's switch: killed with the fuse already burning, the bomb goes off anyway - unless the
    // kill was a headshot, which gg2_damage's hint message tells players to go for, or melee.
    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));
    if (g_state[victim] == Bomber_Lit && g_lastHitgroup[victim] != HITGROUP_HEAD && !IsMeleeDamage(weapon))
        DetonateOnCorpse(victim, "deadman");

    g_state[victim] = Bomber_None;
    RestoreSpeed(victim);
}

float PanicChance(int hitgroup, const char[] weapon)
{
    switch (hitgroup)
    {
        case HITGROUP_HEAD: return 0.0;
        case HITGROUP_CHEST, HITGROUP_STOMACH: return g_cvPanicChest.FloatValue;
        case HITGROUP_GENERIC:
        {
            // Blast and fire damage arrive with no hitgroup. Classified by name rather than listed,
            // so the theater's many grenade and rocket variants are all covered.
            if (StrContains(weapon, "molotov") != -1 || StrContains(weapon, "anm14") != -1
                || StrContains(weapon, "incen") != -1 || StrContains(weapon, "incid") != -1)
                return g_cvPanicFire.FloatValue;
            if (StrContains(weapon, "grenade_") == 0 || StrContains(weapon, "rocket_") == 0)
                return g_cvPanicExplosive.FloatValue;
            return 0.0;
        }
    }

    if (hitgroup >= HITGROUP_LEFTARM && hitgroup <= HITGROUP_RIGHTLEG) return g_cvPanicLimb.FloatValue;
    return 0.0;
}

// ---------------------------------------------------------------------------------------- arming

public Action Timer_PrepareBomber(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsPlayerAlive(client) || g_state[client] != Bomber_Armed) return Plugin_Stop;

    if (g_cvStripWeapons.BoolValue) StripToMelee(client);

    float speed = g_cvSpeed.FloatValue;
    if (speed != 1.0)
    {
        SetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue", speed);
        g_speedChanged[client] = true;
    }

    return Plugin_Stop;
}

void StripToMelee(int client)
{
    int  slots = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    int  melee = -1;
    char classname[64];

    for (int i = 0; i < slots && melee == -1; i++)
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon <= 0 || !IsValidEntity(weapon)) continue;
        GetEntityClassname(weapon, classname, sizeof(classname));
        if (IsMeleeWeapon(classname)) melee = weapon;
    }

    if (melee == -1) return;

    for (int i = 0; i < slots; i++)
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon <= 0 || weapon == melee || !IsValidEntity(weapon)) continue;
        GetEntityClassname(weapon, classname, sizeof(classname));
        if (IsMeleeWeapon(classname)) continue;

        RemovePlayerItem(client, weapon);
        AcceptEntityInput(weapon, "Kill");
    }

    GetEntityClassname(melee, classname, sizeof(classname));
    FakeClientCommandEx(client, "use %s", classname);
}

bool IsMeleeDamage(const char[] weapon)
{
    for (int i = 0; i < sizeof(g_meleeDamage); i++)
    {
        if (StrContains(weapon, g_meleeDamage[i], false) != -1) return true;
    }
    return false;
}

bool IsMeleeWeapon(const char[] classname)
{
    for (int i = 0; i < sizeof(g_meleeWeapons); i++)
    {
        if (StrEqual(classname, g_meleeWeapons[i])) return true;
    }
    return false;
}

void RestoreSpeed(int client)
{
    if (!g_speedChanged[client]) return;
    g_speedChanged[client] = false;
    if (IsClientInGame(client)) SetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue", 1.0);
}

// ---------------------------------------------------------------------------------------- hunting

public Action Timer_BomberLoop(Handle timer)
{
    if (!g_cvEnabled.BoolValue) return Plugin_Continue;

    bool  running = GameRules_GetProp("m_iGameState") == GAMESTATE_ROUND_RUNNING;
    float now     = GetGameTime();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_state[client] != Bomber_Armed && g_state[client] != Bomber_Lit) continue;
        if (!IsClientInGame(client) || !IsPlayerAlive(client)) continue;

        if (g_state[client] == Bomber_Lit)
        {
            if (now >= g_fuseEnd[client])
            {
                DetonateOnBody(client, "fuse");
            }
            else if (now >= g_nextBeep[client])
            {
                EmitSoundToAll(SOUND_BEEP, client, SNDCHAN_AUTO, SNDLEVEL_MINIBIKE);
                g_nextBeep[client] = now + g_cvBeepInterval.FloatValue;
            }
            continue;
        }

        if (!running) continue;

        float roamInterval = g_cvRoamInterval.FloatValue;
        if (roamInterval > 0.0 && now >= g_nextRoam[client])
        {
            EmitSoundToAll(g_roamYells[GetRandomInt(0, sizeof(g_roamYells) - 1)], client, SNDCHAN_VOICE, SNDLEVEL_MINIBIKE);
            g_nextRoam[client] = now + roamInterval * GetRandomFloat(0.75, 1.25);
        }

        if (now - g_spawnTime[client] >= g_cvSpawnGrace.FloatValue && HasTargetInRange(client)) LightFuse(client);
    }

    return Plugin_Continue;
}

bool HasTargetInRange(int bomber)
{
    float range = g_cvTriggerRange.FloatValue;
    float bomberEye[3], targetEye[3];
    GetClientEyePosition(bomber, bomberEye);

    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || !IsPlayerAlive(target) || GetClientTeam(target) != TEAM_SEC) continue;

        GetClientEyePosition(target, targetEye);
        if (GetVectorDistance(bomberEye, targetEye) > range) continue;

        TR_TraceRayFilter(bomberEye, targetEye, MASK_SOLID, RayType_EndPoint, TraceFilter_IgnorePlayers);
        if (!TR_DidHit()) return true;
    }

    return false;
}

public bool TraceFilter_IgnorePlayers(int entity, int contentsMask)
{
    return entity < 1 || entity > MaxClients;
}

void LightFuse(int client)
{
    float now = GetGameTime();
    g_state[client]    = Bomber_Lit;
    g_fuseEnd[client]  = now + g_cvFuse.FloatValue;
    g_nextBeep[client] = now;

    EmitSoundToAll(SOUND_TRIGGER, client, SNDCHAN_ITEM, SNDLEVEL_MINIBIKE);
    YellDetonate(client);
}

void YellDetonate(int client)
{
    EmitSoundToAll(g_detonateYells[GetRandomInt(0, sizeof(g_detonateYells) - 1)], client, SNDCHAN_VOICE, SNDLEVEL_SCREAMING);
}

// ---------------------------------------------------------------------------------------- detonation

void DetonateOnBody(int client, const char[] why)
{
    float pos[3];
    GetClientEyePosition(client, pos);
    int ied = SpawnIED(client, pos, why);
    // The IED's own fuse is 0.5s. Keep it on the bomber meanwhile, or a running bomber leaves it behind.
    if (ied != -1) g_bombRef[client] = EntIndexToEntRef(ied);
}

void DetonateOnCorpse(int client, const char[] why)
{
    float pos[3];
    GetClientAbsOrigin(client, pos);
    pos[2] += CORPSE_BOMB_HEIGHT;
    SpawnIED(client, pos, why);
}

int SpawnIED(int owner, const float pos[3], const char[] why)
{
    g_state[owner] = Bomber_Detonated;

    int ied = CreateEntityByName("grenade_ied");
    if (ied == -1)
    {
        LogError("Could not create grenade_ied - is it still defined by the theater?");
        return -1;
    }

    // Property order follows the original plugin, which is known to detonate on this game.
    TeleportEntity(ied, pos, NULL_VECTOR, NULL_VECTOR);
    SetEntPropEnt(ied, Prop_Data, "m_hOwnerEntity", owner);
    SetEntProp(ied, Prop_Data, "m_takedamage", 2);    // DAMAGE_YES
    SetEntProp(ied, Prop_Data, "m_iHealth", 1);
    // Nice-to-haves (think promptly, collide with nothing). A missing property would throw and abort
    // the detonation, and the solidity ones live on the embedded collision property, so check first.
    SetEntPropIfPresent(ied, "m_nNextThinkTick", 1);
    SetEntPropIfPresent(ied, "m_usSolidFlags", 0);
    SetEntPropIfPresent(ied, "m_nSolidType", 0);
    if (!DispatchSpawn(ied))
    {
        LogError("grenade_ied failed to spawn");
        AcceptEntityInput(ied, "Kill");
        return -1;
    }
    SetEntityRenderMode(ied, RENDER_NONE);

    // Recorded before the trigger damage so a failed detonation can say which path and state it came
    // from - see Timer_CheckDetonation.
    bool  ownerAlive = IsPlayerAlive(owner);
    float now        = GetGameTime();
    float sinceLast  = now - g_lastIEDTime;
    g_lastIEDTime    = now;

    // The blast does not credit its owner: grenade_ied has no thrower field (CBaseDetonator networks
    // only m_hOwnerEntity, already set above), so IED kills came out with no attacker. Remember
    // whose it is and rewrite the attacker in OnTakeDamage instead.
    g_iedRef[ied]   = EntIndexToEntRef(ied);
    g_iedOwner[ied] = GetClientUserId(owner);

    SDKHooks_TakeDamage(ied, owner, owner, IED_TRIGGER_DAMAGE, DMG_BLAST);

    DataPack pack;
    CreateDataTimer(DETONATION_CHECK_DELAY, Timer_CheckDetonation, pack, TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteCell(GetClientUserId(owner));
    pack.WriteCell(EntIndexToEntRef(ied));
    pack.WriteString(why);
    pack.WriteCell(ownerAlive);
    pack.WriteFloat(sinceLast);
    pack.WriteCell(GetEntProp(ied, Prop_Data, "m_iHealth"));
    pack.WriteCell(GetEntProp(ied, Prop_Data, "m_takedamage"));

    return ied;
}

void SetEntPropIfPresent(int entity, const char[] prop, int value)
{
    if (HasEntProp(entity, Prop_Data, prop)) SetEntProp(entity, Prop_Data, prop, value);
}

public Action Timer_CheckDetonation(Handle timer, DataPack pack)
{
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int ied    = EntRefToEntIndex(pack.ReadCell());

    char why[16];
    pack.ReadString(why, sizeof(why));
    bool  ownerAlive = pack.ReadCell();
    float sinceLast  = pack.ReadFloat();
    int   health     = pack.ReadCell();
    int   takeDamage = pack.ReadCell();

    // A detonated grenade removes itself, so one still here means the damage did not set it off.
    if (ied != INVALID_ENT_REFERENCE)
    {
        LogError("grenade_ied did not detonate; removing it (path %s, bomber %s, %.2fs after the previous IED, after trigger damage health %d takedamage %d, now health %d)",
                 why, ownerAlive ? "alive" : "dead", sinceLast, health, takeDamage, GetEntProp(ied, Prop_Data, "m_iHealth"));
        AcceptEntityInput(ied, "Kill");
    }

    // Normally its own blast kills it. If not, it must not wander on as a bomber that has already
    // exploded.
    if (client != 0 && IsPlayerAlive(client) && g_state[client] == Bomber_Detonated) ForcePlayerSuicide(client);

    return Plugin_Stop;
}

public void OnGameFrame()
{
    float pos[3];
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_bombRef[client] == INVALID_ENT_REFERENCE) continue;

        int ied = EntRefToEntIndex(g_bombRef[client]);
        if (ied == INVALID_ENT_REFERENCE || !IsClientInGame(client) || !IsPlayerAlive(client))
        {
            g_bombRef[client] = INVALID_ENT_REFERENCE;
            continue;
        }

        GetClientEyePosition(client, pos);
        TeleportEntity(ied, pos, NULL_VECTOR, view_as<float>({ 0.0, 0.0, 0.0 }));
    }
}
