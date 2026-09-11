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
 * Objective progress is appended too, on modes that have control points: "(2/5) [Cap 3/8]". The
 * numbers come from gg2_insurgency's objective resource natives, the same pair bm2_respawn already
 * uses - m_iNumControlPoints for the total and m_nActivePushPointIndex (0-based, so +1) for the one
 * being fought over. Modes without control points report 0 total and the suffix is omitted rather
 * than showing "[Cap 1/0]".
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

// GameRules_GetProp errors if the gamerules entity does not exist yet, which it does not during
// early map load. A round event having fired is proof that it does.
bool   g_bRulesReady = false;

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

    // A capture is the other moment the name is out of date, and it is what makes the cap number
    // worth showing at all - it is the difference between joining a round that has barely started
    // and one that is nearly over.
    HookEvent("controlpoint_captured", Event_Round, EventHookMode_PostNoCopy);
    HookEvent("object_destroyed", Event_Round, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
    // server.cfg re-execs on map change and may reset the hostname, so re-derive the base. The
    // gamerules entity is recreated too, so treat the counter as unavailable until a round event.
    g_bRulesReady = false;
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

public void Event_Round(Event event, const char[] name, bool dontBroadcast)
{
    g_bRulesReady = true;
    UpdateHostname();
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

// Removes the decorations this plugin appends, innermost last: " [Cap n/m]" then " (n/m)".
//
// Without this the suffix compounds - "TUG (1/5)" becomes "TUG (1/5) (2/5)" and so on, one per
// round, forever. The cap bracket has to be stripped FIRST: it is the outermost part, and while it
// is present the round suffix is no longer at the end of the string where the round strip looks.
void StripRoundSuffix(char[] buffer)
{
    StripBracketed(buffer, '[', ']', true);    // " [Cap n/m]"
    StripBracketed(buffer, '(', ')', false);   // " (n/m)"
}

// Strips one trailing " <open>...<close>" group, but only when its contents are digits, one
// optional "/", and - if requireCapPrefix - the literal "Cap ". The content check is what stops a
// name that legitimately ends in "(hardcore)" or "[EU]" being mangled.
static void StripBracketed(char[] buffer, char open, char close, bool requireCapPrefix)
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

    int cursor = start + 1;

    if (requireCapPrefix)
    {
        // Exactly "Cap " - anything else in brackets is somebody's own tag, not ours.
        if (len - 1 - cursor < 4) return;
        if (buffer[cursor] != 'C' || buffer[cursor + 1] != 'a' ||
            buffer[cursor + 2] != 'p' || buffer[cursor + 3] != ' ') return;
        cursor += 4;
    }

    bool seenDigit = false, seenSlash = false;
    for (int i = cursor; i < len - 1; i++)
    {
        if (buffer[i] >= '0' && buffer[i] <= '9') { seenDigit = true; continue; }
        if (buffer[i] == '/' && seenDigit && !seenSlash) { seenSlash = true; continue; }
        return;
    }
    if (!seenDigit) return;

    buffer[start - 1] = '\0';
}

// " [Cap 3/8]", or empty on a mode with no control points.
//
// The natives live in gg2_insurgency. If that plugin is not loaded they do not exist, and calling
// one is a runtime error rather than something that can be caught - so the feature is probed once
// and the suffix is simply dropped if it is unavailable.
void BuildCapSuffix(char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!g_cvShowCaps.BoolValue || !g_bRulesReady) return;
    if (GetFeatureStatus(FeatureType_Native, "Ins_ObjectiveResource_GetProp") != FeatureStatus_Available) return;

    int total = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
    if (total <= 0) return;    // survival, hunt and anything else without control points

    // m_nActivePushPointIndex is 0-based - bm2_respawn adds 1 to it for the same reason.
    int active = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex") + 1;

    // Between rounds, or on a map where the index has not settled, this can read outside the real
    // range. Clamping beats printing "[Cap 0/8]" or "[Cap 9/8]" into the server browser.
    if (active < 1) active = 1;
    if (active > total) active = total;

    Format(buffer, maxlen, " [Cap %d/%d]", active, total);
}

void UpdateHostname()
{
    if (!g_cvEnabled.BoolValue) return;
    if (g_sBaseHostname[0] == '\0') return;

    int maxRounds = (g_cvMaxRounds != null) ? g_cvMaxRounds.IntValue : 0;

    // m_iRoundPlayedCount counts rounds FINISHED, so the one being played is that plus one.
    int current = 1;
    if (g_bRulesReady)
    {
        current = GameRules_GetProp("m_iRoundPlayedCount") + 1;
    }

    // After the last round ends the counter keeps climbing until the map actually changes; showing
    // "6/5" in the browser looks broken.
    if (maxRounds > 0 && current > maxRounds) current = maxRounds;
    if (current < 1) current = 1;

    char caps[24];
    BuildCapSuffix(caps, sizeof(caps));

    char decorated[MAX_HOSTNAME];
    if (maxRounds > 0) Format(decorated, sizeof(decorated), "%s (%d/%d)%s", g_sBaseHostname, current, maxRounds, caps);
    else               Format(decorated, sizeof(decorated), "%s (%d)%s", g_sBaseHostname, current, caps);

    g_bSelfWrite = true;
    g_cvHostname.SetString(decorated);
    g_bSelfWrite = false;
}
