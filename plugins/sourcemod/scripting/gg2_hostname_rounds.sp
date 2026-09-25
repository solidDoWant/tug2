/**
 * [GG2 HOSTNAME ROUNDS] Show round progress in the server browser.
 *
 * Appends "(2/5)" to the hostname - the round being played, and mp_maxrounds, which is how many
 * are played before the game ends and the map changes.
 *
 * WHERE THE NUMBERS COME FROM
 * The round count is the engine's own: m_iRoundPlayedCount on CINSRulesProxy, read through
 * GameRules_GetProp. That is preferable to counting round_start events in the plugin, which drifts
 * if the plugin is reloaded mid-map and has to guess about warmup rounds. It counts rounds
 * COMPLETED, so the round in progress is that plus one.
 *
 * mp_maxrounds is looked up rather than hard-coded. gg2_discord had exactly that bug - a
 * "#define max_rounds 3" that reported "(4/3)" on a server running 5.
 *
 * Objective progress is appended too, in a shape that fits the mode (see objectivestatus.inc):
 *   checkpoint         "(2/5) [Cap 3/8]"            the point being fought over, of all of them
 *   hunt               "(2/5) [Caches 1/3]"         caches destroyed, of the ones in play
 *   conquer            "(2/5) [Caps 1/3, Caches 0/5]"  required points taken, and caches destroyed
 *   outpost, survival  "(2/5) [Level 6]"            the level shown on the players' HUD
 * The objective numbers come from gg2_insurgency's objective resource natives. Only checkpoint has
 * a meaningful m_nActivePushPointIndex - it is -1 or arbitrary everywhere else, which is why those
 * modes used to advertise "[Cap 1/N]" for the whole round.
 *
 * THE TRAP THIS AVOIDS
 * The hostname is rewritten in place, so the base name has to be recovered rather than re-read, or
 * every update appends another suffix and the name grows without bound. The base is captured once
 * before anything is written, re-captured on map change (server.cfg re-execs and may set it), and
 * any "(n/m)" this plugin previously appended is stripped defensively before use.
 */

#include <sourcemod>
#include <sdktools>
#include <insurgencydy>
#include <objectivestatus>

#pragma newdecls required
#pragma semicolon 1

#define MAX_HOSTNAME 256

ConVar g_cvEnabled;
ConVar g_cvShowCaps;
ConVar g_cvHostname;
ConVar g_cvMaxRounds;

char   g_sBaseHostname[MAX_HOSTNAME];

// Set while this plugin is writing the hostname, so the change hook can tell its own write from
// someone else's and not treat the suffixed name as a new base.
bool   g_bSelfWrite = false;

// GameRules_GetProp reads through the gamerules entity, and reading before it exists is a native
// error rather than something recoverable - hence the gate. A round event having fired proves it
// exists, but waiting for one is not enough on its own: a plugin loaded or reloaded mid-round then
// advertises round 1 until the round ends, which can be many minutes. RulesReady() probes for the
// entity directly instead, so a mid-round load corrects the name immediately.
bool   g_bRulesReady = false;

// Emptying the server does NOT reset the round counter - measured on test: the last human leaving
// ends the round (round_end, m_iRoundPlayedCount +1) and drops m_iGameState to GAMESTATE_PREGAME,
// "waiting for players", and both then sit unchanged for as long as the server is empty. The reset
// only comes when somebody joins: ~14s later game_start fires with the counter back at 0, then
// round_start. So the empty server would advertise "(3/5)" for a game that restarts at round 1 the
// moment anyone connects. UpdateHostname therefore shows round 1 whenever the game is in pregame.
// The state change lands just after the round_end hook runs, so re-check for a few seconds after
// the server empties. Safe on a timer because sv_hibernate_when_empty is 0 - an empty server ticks.
// m_iGameState values, read off the live server rather than an SDK header: 1 while waiting for
// players, 2 on game_start, 3 on round_start (preround), 4 once the round is running.
#define GAMESTATE_PREGAME 1

// GR_STATE_GAME_OVER, from CINSRules' state table in the binary. The game has been won (or its
// rounds run out) and players are on the map vote screen. Measured on test: game_end fires ~5s
// after the final round_end, and the state then stays 7 for as long as the vote screen is up - and
// it stays up indefinitely, including after every player has left, with no further events. The
// round counter is frozen at the finished game's value, so a round number here is meaningless.
#define GAMESTATE_GAME_OVER 7
#define MAP_END_SUFFIX      " (Map end)"

#define EMPTY_RECHECK_INTERVAL 1.0
#define EMPTY_RECHECK_TICKS    6

Handle g_hEmptyCheck = null;
int    g_iEmptyTicks = 0;

public Plugin myinfo =
{
    name        = "[GG2 HOSTNAME ROUNDS] Round Count In Hostname",
    author      = "TUG",
    description = "Shows the current round and round limit in the server browser name",
    version     = "1.0.0",
    url         = "https://github.com/solidDoWant/tug2"
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_hostname_rounds_enabled", "1",
        "Append the round count to the server browser name.", _, true, 0.0, true, 1.0);
    g_cvShowCaps = CreateConVar("sm_hostname_rounds_show_caps", "1",
        "Also append objective progress on modes that have control points.", _, true, 0.0, true, 1.0);

    g_cvHostname  = FindConVar("hostname");
    g_cvMaxRounds = FindConVar("mp_maxrounds");

    if (g_cvHostname == null)
    {
        SetFailState("hostname cvar not found - nothing to decorate");
        return;
    }
    if (g_cvMaxRounds == null)
        LogError("[HOSTNAME] mp_maxrounds not found - the round limit will be omitted");

    CaptureBaseHostname();

    // Someone else changing the hostname (an admin, a config exec) becomes the new base.
    g_cvHostname.AddChangeHook(OnHostnameChanged);
    g_cvEnabled.AddChangeHook(OnEnabledChanged);
    g_cvShowCaps.AddChangeHook(OnEnabledChanged);

    HookEvent("round_start", Event_Round, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_Round, EventHookMode_PostNoCopy);
    // round_start fires in preround (state 3); the round only counts as running (state 4), and the
    // non-checkpoint objective suffixes only switch on, when the freeze ends.
    HookEvent("round_freeze_end", Event_Round, EventHookMode_PostNoCopy);
    HookEvent("game_start", Event_Round, EventHookMode_PostNoCopy);
    HookEvent("game_end", Event_Round, EventHookMode_PostNoCopy);

    // A capture is the other moment the name is out of date, and it is what makes the cap number
    // worth showing at all - it is the difference between joining a round that has barely started
    // and one that is nearly over.
    HookEvent("controlpoint_captured", Event_Objective, EventHookMode_PostNoCopy);
    HookEvent("object_destroyed", Event_Objective, EventHookMode_PostNoCopy);

    // Outpost's next wave and survival's next safehouse. Both raise the level shown on the HUD.
    HookEvent("round_level_advanced", Event_Round, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
    // server.cfg re-execs on map change and may reset the hostname, so re-derive the base. The
    // gamerules entity is recreated too, so treat the counter as unavailable until a round event.
    g_bRulesReady = false;

    // TIMER_FLAG_NO_MAPCHANGE already killed the timer; drop the handle so StopEmptyRecheck does not
    // try to kill it again.
    g_hEmptyCheck = null;

    CaptureBaseHostname();
    UpdateHostname();
}

public void OnPluginEnd()
{
    // Leave the browser showing a clean name rather than a stale round count.
    RestoreBaseHostname();
}

public void OnHostnameChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    if (g_bSelfWrite) return;

    strcopy(g_sBaseHostname, sizeof(g_sBaseHostname), newValue);
    StripRoundSuffix(g_sBaseHostname);
    UpdateHostname();
}

public void OnEnabledChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    if (cvar.BoolValue) UpdateHostname();
    else                RestoreBaseHostname();
}

// The objective resource is updated AFTER these events fire - read in the handler, a destroyed
// cache still has its old owner (verified live: "[Caches 0/5]" after a kill), and it has flipped by
// the next frame. Checkpoint only looks at the push index, which happened to be current already.
public void Event_Objective(Event event, const char[] name, bool dontBroadcast)
{
    g_bRulesReady = true;
    RequestFrame(Frame_UpdateHostname);
}

public void Frame_UpdateHostname(any unused)
{
    UpdateHostname();
}

public void Event_Round(Event event, const char[] name, bool dontBroadcast)
{
    g_bRulesReady = true;
    UpdateHostname();
}

public void OnClientDisconnect_Post(int client)
{
    // Only the transition to empty matters. _Post, so the leaver is already out of the count.
    if (CountHumans() > 0) return;

    StopEmptyRecheck();
    g_iEmptyTicks = 0;
    g_hEmptyCheck = CreateTimer(EMPTY_RECHECK_INTERVAL, Timer_EmptyRecheck, _,
                                TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client)
{
    // Somebody is back, so round events will keep the name current from here.
    if (!IsFakeClient(client)) StopEmptyRecheck();
}

public Action Timer_EmptyRecheck(Handle timer)
{
    UpdateHostname();

    if (++g_iEmptyTicks >= EMPTY_RECHECK_TICKS || CountHumans() > 0)
    {
        g_hEmptyCheck = null;
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

void StopEmptyRecheck()
{
    if (g_hEmptyCheck == null) return;

    KillTimer(g_hEmptyCheck);
    g_hEmptyCheck = null;
}

int CountHumans()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i)) n++;
    return n;
}

// A client actually IN the game is proof the map finished loading, and with it the gamerules entity
// that GameRules_GetProp reads through. That is the whole test.
//
// Looking the entity up directly would be more precise and was tried first - ins_gamerules_data is
// the only gamerules classname in server.so, and it is what the engine's "game rules entity (%s) not
// created" message names - but FindEntityByClassname does not resolve it on this build, verified
// live: the gate stayed shut and the hostname kept reporting round 1 with the cap suffix missing.
//
// Once true this stays true for the map, which is what makes the empty-server case work: by the time
// the last player leaves, a round event or their own presence has already opened the gate, so the
// re-check below can still read the counter with nobody connected. A fresh map with nobody on it
// reports round 1, which is correct anyway.
bool RulesReady()
{
    if (g_bRulesReady) return true;

    g_bRulesReady = (GetClientCount(true) > 0);
    return g_bRulesReady;
}

void CaptureBaseHostname()
{
    g_cvHostname.GetString(g_sBaseHostname, sizeof(g_sBaseHostname));
    StripRoundSuffix(g_sBaseHostname);
}

void RestoreBaseHostname()
{
    if (g_sBaseHostname[0] == '\0') return;

    g_bSelfWrite = true;
    g_cvHostname.SetString(g_sBaseHostname);
    g_bSelfWrite = false;
}

// Removes the decorations this plugin appends, innermost last: " [Cap n/m]" then " (n/m)". The
// vote-screen " (Map end)" replaces both rather than adding to them, so it is removed on its own.
//
// Without this the suffix compounds - "TUG (1/5)" becomes "TUG (1/5) (2/5)" and so on, one per
// round, forever. The cap bracket has to be stripped FIRST: it is the outermost part, and while it
// is present the round suffix is no longer at the end of the string where the round strip looks.
void StripRoundSuffix(char[] buffer)
{
    int len = strlen(buffer), suffixLen = strlen(MAP_END_SUFFIX);
    if (len > suffixLen && StrEqual(buffer[len - suffixLen], MAP_END_SUFFIX))
    {
        buffer[len - suffixLen] = '\0';
        return;
    }

    StripBracketed(buffer, '[', ']', true);    // " [Cap n/m]", " [Level n]", ...
    StripBracketed(buffer, '(', ')', false);   // " (n/m)"
}

// Strips one trailing " <open>...<close>" group, but only when its contents are exactly what this
// plugin writes - a count, or with objectiveTags one of the BuildObjectiveSuffix shapes. The content
// check is what stops a name that legitimately ends in "(hardcore)" or "[EU]" being mangled.
static void StripBracketed(char[] buffer, char open, char close, bool objectiveTags)
{
    int len = strlen(buffer);
    if (len < 4 || buffer[len - 1] != close) return;

    int start = -1;
    for (int i = len - 2; i > 0; i--)
    {
        if (buffer[i] == close) return;    // nested or unrelated - leave it alone
        if (buffer[i] == open && buffer[i - 1] == ' ') { start = i; break; }
    }
    if (start < 1) return;

    char content[MAX_HOSTNAME];
    strcopy(content, sizeof(content), buffer[start + 1]);
    content[strlen(content) - 1] = '\0';    // drop the closing bracket

    if (objectiveTags ? !IsObjectiveTag(content) : !IsCount(content)) return;

    buffer[start - 1] = '\0';
}

// "n" or "n/m".
static bool IsCount(const char[] s)
{
    bool seenDigit = false, seenSlash = false;
    for (int i = 0; s[i] != '\0'; i++)
    {
        if (s[i] >= '0' && s[i] <= '9') { seenDigit = true; continue; }
        if (s[i] == '/' && seenDigit && !seenSlash) { seenSlash = true; seenDigit = false; continue; }
        return false;
    }
    return seenDigit;
}

// One or more ", "-separated "<Label> <count>" parts, with Label one this plugin writes. Anything
// else in brackets is somebody's own tag, not ours.
static bool IsObjectiveTag(const char[] s)
{
    static const char labels[][] = { "Cap", "Caps", "Caches", "Level" };

    char parts[4][32];
    int  n = ExplodeString(s, ", ", parts, sizeof(parts), sizeof(parts[]));
    if (n < 1 || n > sizeof(parts)) return false;

    for (int p = 0; p < n; p++)
    {
        int space = FindCharInString(parts[p], ' ');
        if (space < 1) return false;
        if (!IsCount(parts[p][space + 1])) return false;

        parts[p][space] = '\0';
        bool known = false;
        for (int l = 0; l < sizeof(labels); l++)
            if (StrEqual(parts[p], labels[l])) { known = true; break; }
        if (!known) return false;
    }
    return true;
}

// The objective part of the name, " [<phrase>]" - see the table at the top. The phrase is built by
// objectivestatus.inc, shared with gg2_discord's round end message, and is empty when there is
// nothing meaningful to show.
void BuildObjectiveSuffix(char[] buffer, int maxlen, int state)
{
    buffer[0] = '\0';

    if (!g_cvShowCaps.BoolValue || !RulesReady()) return;

    char phrase[64];
    if (ObjectiveStatus_Build(phrase, sizeof(phrase), state)) Format(buffer, maxlen, " [%s]", phrase);
}

void UpdateHostname()
{
    if (!g_cvEnabled.BoolValue) return;
    if (g_sBaseHostname[0] == '\0') return;

    int maxRounds = (g_cvMaxRounds != null) ? g_cvMaxRounds.IntValue : 0;

    // m_iRoundPlayedCount counts rounds FINISHED, so the one being played is that plus one.
    // Pregame means the next player to join starts a fresh game (see g_hEmptyCheck), so the
    // counter still holds the abandoned game's rounds and the honest answer is round 1.
    int current = 1;
    int state   = GAMESTATE_PREGAME;
    if (RulesReady())
    {
        state = GameRules_GetProp("m_iGameState");
        if (state > GAMESTATE_PREGAME) current = GameRules_GetProp("m_iRoundPlayedCount") + 1;
    }
    bool gameOver = (state == GAMESTATE_GAME_OVER);

    // After the last round ends the counter keeps climbing until the map actually changes; showing
    // "6/5" in the browser looks broken.
    if (maxRounds > 0 && current > maxRounds) current = maxRounds;
    if (current < 1) current = 1;

    char caps[48];
    BuildObjectiveSuffix(caps, sizeof(caps), state);

    // No round or cap on the vote screen: the game they describe is over, and the state holds
    // unchanged (events included) until the map changes, even with the server empty. The state
    // is checked on every update, so no separate event is needed to keep this current.
    char decorated[MAX_HOSTNAME];
    if (gameOver)           Format(decorated, sizeof(decorated), "%s%s", g_sBaseHostname, MAP_END_SUFFIX);
    else if (maxRounds > 0) Format(decorated, sizeof(decorated), "%s (%d/%d)%s", g_sBaseHostname, current, maxRounds, caps);
    else                    Format(decorated, sizeof(decorated), "%s (%d)%s", g_sBaseHostname, current, caps);

    // Skip the write when nothing changed. The empty-server re-check calls this repeatedly, and
    // rewriting an identical hostname is pointless churn on a replicated convar.
    char currentName[MAX_HOSTNAME];
    g_cvHostname.GetString(currentName, sizeof(currentName));
    if (StrEqual(currentName, decorated)) return;

    g_bSelfWrite = true;
    g_cvHostname.SetString(decorated);
    g_bSelfWrite = false;
}
