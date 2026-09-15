// Names whoever just flashbanged their own team, in team chat.
//
// Originally a vendored copy of Apple3.14159's "[MAGA] Teamflash"
// (https://forums.alliedmods.net/showthread.php?p=2665681). Pulled into this repo and rewritten
// 2026-09-15 because it was crediting players with blindings caused by bots. See gg2_teamflash.md
// for the full diagnosis; the two things that were wrong, and what replaced them:
//
// 1. IT WAS NOT WATCHING FLASHBANGS. grenade_detonate's "id" is the explosive's THEATER definition
//    id, which is nothing more than its position in the merged explosives list - the theater parser
//    hands them out as a 1-based counter in parse order. The original hard-coded 2, which is right
//    on a stock server (default_weapon.theater really does list grenade_m84 second) and wrong on
//    both of ours. TUG inserts grenade_m18_impact ahead of it, so on main, which runs TUG's
//    theater_tug_39_medicbomber_12p_default unmodified, grenade_m84 is 3 and id 2 is
//    grenade_m18_impact - an impact smoke, which players throw constantly. On test our own
//    explosives block prepends seven more, so grenade_m84 is 10 and id 2 is grenade_m777_ins.
//    The id is now looked up by name on every map through gg2_theater_items, so it cannot go stale
//    when the theater is edited and it is correct per gamemode - each one loads its own theater.
//
// 2. THE VICTIM FLAGS WERE NEVER CLEARED. A blind was only ever consumed if the victim turned out
//    to be a live teammate of the thrower, so a blind caused by an ENEMY - which is every bot on a
//    coop server - was recorded and then left set forever, waiting for the next friendly grenade to
//    claim it. Same for a self-blind, a victim who died within the delay, and one who disconnected;
//    nothing reset between rounds or maps either. This version records the TICK a player was
//    blinded on and matches it against the tick the detonation was reported on, so a blind belongs
//    to exactly the grenade that caused it and to nothing else.
//
// WHY MATCHING ON THE TICK IS EXACT, AND NOT A HEURISTIC. Read out of server_srv.so:
//
//     CFlashBangGrenade::DoFlashEffect(def)
//         RadiusFlash(...)                      -> CINSPlayer::Blind per victim, each firing
//                                                  player_blind synchronously
//         EmitEvent(this, grenade_detonate, ...) -> the event this plugin keys on
//
// Both happen in one call, so every player_blind a flashbang causes is fired in the same tick as -
// and strictly before - its grenade_detonate. Nothing else can land in between, which is why this
// needs no timer and no tolerance window. (The deferred branch of DoFlashEffect emits no event at
// all; when the think runs it comes back through the same function and both fire together then.)

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <theateritems>

#define PLUGIN_VERSION "2.0.0"

public Plugin myinfo =
{
    name        = "[GG2] Teamflash",
    author      = "solidDoWant, originally Apple3.14159",
    description = "Prints the name of any teamflasher to team chat",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

// The theater's own name for the M84 stun grenade. Every theater this server runs inherits it from
// the stock explosives list, under this name, whatever position it ends up in.
#define FLASHBANG_NAME "grenade_m84"

int  g_iFlashbangId;                    // 0 = not resolved for the loaded theater yet
bool g_bWarnedUnresolved;               // so a theater without a flashbang logs once, not per grenade

// The tick each player was last blinded on, or 0. Tick 0 is unreachable in practice - nothing has
// detonated by the first tick of a map - so it doubles as "never".
int  g_iBlindTick[MAXPLAYERS + 1];

public void OnPluginStart()
{
    HookEvent("player_blind",     Event_PlayerBlind);
    HookEvent("grenade_detonate", Event_GrenadeDetonate);
}

// Cleared at map END rather than map start, deliberately. gg2_theater_items fires
// TheaterItems_OnReady from its own OnMapStart, and the order two plugins' OnMapStart run in is not
// defined - clearing there could wipe an id the forward had already handed us. Nothing detonates
// between one map ending and the next starting, so this is the safe edge.
public void OnMapEnd()
{
    g_iFlashbangId    = 0;
    g_bWarnedUnresolved = false;

    for (int i = 0; i <= MaxClients; i++)
        g_iBlindTick[i] = 0;
}

// Not needed for correctness - a tick that has already passed can never match a future one, so a
// leftover entry is inert rather than dangerous. It is here so that a slot reused by a new player
// starts clean regardless.
public void OnClientDisconnect(int client)
{
    g_iBlindTick[client] = 0;
}

public void TheaterItems_OnReady()
{
    ResolveFlashbang();
}

// Ids are assigned when the theater is parsed and move whenever it is edited, so this is a lookup
// by name, once per map. Returns 0 if the tables are not readable yet or the theater has no
// flashbang, in which case the plugin simply reports nothing.
int ResolveFlashbang()
{
    g_iFlashbangId = TheaterItem_Find(TheaterCategory_Explosive, FLASHBANG_NAME);

    if (g_iFlashbangId == 0)
    {
        if (!g_bWarnedUnresolved && TheaterItem_Ready())
        {
            LogError("The loaded theater has no \"%s\" explosive - team flashes will not be reported",
                     FLASHBANG_NAME);
            g_bWarnedUnresolved = true;
        }
    }
    else
    {
        LogMessage("%s = explosive id %d", FLASHBANG_NAME, g_iFlashbangId);
    }

    return g_iFlashbangId;
}

public void Event_PlayerBlind(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1) return;

    g_iBlindTick[client] = GetGameTickCount();
}

public void Event_GrenadeDetonate(Event event, const char[] name, bool dontBroadcast)
{
    // The lazy re-resolve covers the case where the tables were not ready when the forward would
    // have fired - gg2_theater_items retries, and this picks the id up on the first grenade after.
    int flashbangId = (g_iFlashbangId != 0) ? g_iFlashbangId : ResolveFlashbang();
    if (flashbangId == 0 || event.GetInt("id") != flashbangId) return;

    int tick = GetGameTickCount();

    // Carried as a userid, not a client index: the index could in principle be recycled, the userid
    // cannot. A thrower who has already left is still a reason to consume the blinds below - they
    // belong to this grenade either way - it just leaves nobody to name.
    int  thrower     = GetClientOfUserId(event.GetInt("userid"));
    bool haveThrower = (thrower >= 1 && thrower <= MaxClients && IsClientInGame(thrower));
    int  throwerTeam = haveThrower ? GetClientTeam(thrower) : 0;

    int numFlashed = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_iBlindTick[i] != tick) continue;

        // Consumed whoever it hit and whichever team they are on. This is the line the original was
        // missing: it cleared only the victims it went on to count, which is what let a bot's
        // flashbang leave flags lying around for a player's grenade to be blamed for. Consuming
        // also settles the one genuinely ambiguous case - two flashbangs detonating on the same
        // tick - in favour of the first, rather than crediting both with the same victims.
        g_iBlindTick[i] = 0;

        if (!haveThrower || i == thrower) continue;
        if (!IsClientInGame(i) || GetClientTeam(i) != throwerTeam) continue;

        // Deliberately no IsPlayerAlive check. player_blind only fires for a living player, so the
        // only thing it would exclude is a teammate who was blinded and then killed inside the same
        // tick - which is the most deserving case there is.
        numFlashed++;
    }

    if (numFlashed == 0) return;

    char flasherName[MAX_NAME_LENGTH];
    if (!GetClientName(thrower, flasherName, sizeof(flasherName))) return;

    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && GetClientTeam(i) == throwerTeam)
            PrintToChat(i, "%s flashed %d teammate(s)", flasherName, numFlashed);

    LogToGame("%s flashed %d teammate(s)", flasherName, numFlashed);
}
