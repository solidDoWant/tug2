// Shares each player's hint-text box between plugins. See include/gg2_hint.inc for the API.
//
// Each player has a few messages, one per key. The box shows the highest-priority one that is still
// current (ties go to the most recently set); when it lapses or is withdrawn, the next one shows at
// once, so a warning doesn't leave the box empty or stale until the health display's next refresh.
//
// Sending rules, which are what stop the flicker:
// - A message that isn't the winner is never sent.
// - The winner is sent when it changes (key or text), including when a higher one lapses.
// - An unchanged winner is re-sent only when its owner sends it again, and then at most every
//   sm_hint_resend_interval seconds. So each message goes out no more often than its owner asks
//   (health every 10s), and producers that refresh every half second no longer redraw the box
//   every half second. The 0.2s tick only notices lapses; it never re-sends by itself.
// - When nothing is current, the box is cleared once.

#include <sourcemod>

#pragma newdecls required
#pragma semicolon 1

#define MAX_HINTS   8
#define KEY_LEN     32
#define TEXT_LEN    255
#define TICK        0.2

public Plugin myinfo =
{
    name        = "[GG2] Hint text arbiter",
    author      = "tug2",
    description = "Shares the hint-text box between plugins by priority",
    version     = "1.0",
    url         = "https://tug.gg"
};

enum struct Hint
{
    char  key[KEY_LEN];
    char  text[TEXT_LEN];
    int   priority;
    float expires;
    int   seq;    // when it was set, to break priority ties
}

Hint   g_hints[MAXPLAYERS + 1][MAX_HINTS];
int    g_count[MAXPLAYERS + 1];
int    g_seq;

// What the box last showed: the winner's key and text ("" key = cleared), and when it was sent.
char   g_shownKey[MAXPLAYERS + 1][KEY_LEN];
char   g_shownText[MAXPLAYERS + 1][TEXT_LEN];
float  g_shownAt[MAXPLAYERS + 1];

ConVar g_cvResend;
ConVar g_cvDebug;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("Hint_Set", Native_Set);
    CreateNative("Hint_Clear", Native_Clear);
    RegPluginLibrary("gg2_hint");
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvResend = CreateConVar("sm_hint_resend_interval", "1.0", "Minimum seconds between re-sends of an unchanged hint when its owner sends it again.", _, true, 0.2, true, 30.0);
    g_cvDebug  = CreateConVar("sm_hint_debug", "0", "Log every hint sent and why.", _, true, 0.0, true, 1.0);
    AutoExecConfig(true, "gg2_hint");

    CreateTimer(TICK, Timer_Tick, _, TIMER_REPEAT);
}

public void OnClientDisconnect(int client)
{
    g_count[client]        = 0;
    g_shownKey[client][0]  = '\0';
    g_shownText[client][0] = '\0';
    g_shownAt[client]      = 0.0;
}

public any Native_Set(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return 0;

    char key[KEY_LEN];
    GetNativeString(2, key, sizeof(key));
    int   priority = GetNativeCell(3);
    float duration = GetNativeCell(4);
    char  text[TEXT_LEN];
    GetNativeString(5, text, sizeof(text));

    int i = Find(client, key);
    if (i == -1)
    {
        if (g_count[client] < MAX_HINTS)
            i = g_count[client]++;
        else
            i = Weakest(client);    // full: replace the lowest-priority, oldest message
    }

    strcopy(g_hints[client][i].key, KEY_LEN, key);
    strcopy(g_hints[client][i].text, TEXT_LEN, text);
    g_hints[client][i].priority = priority;
    g_hints[client][i].expires  = GetGameTime() + (duration > 0.0 ? duration : 0.1);
    g_hints[client][i].seq      = ++g_seq;

    Update(client, GetGameTime(), key);
    return 0;
}

public any Native_Clear(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients) return 0;

    char key[KEY_LEN];
    GetNativeString(2, key, sizeof(key));
    int i = Find(client, key);
    if (i == -1) return 0;

    Remove(client, i);
    if (IsClientInGame(client)) Update(client, GetGameTime());
    return 0;
}

Action Timer_Tick(Handle timer)
{
    float now = GetGameTime();
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_count[client] == 0 && g_shownKey[client][0] == '\0') continue;
        if (!IsClientInGame(client)) continue;
        Update(client, now);
    }
    return Plugin_Continue;
}

// Drops lapsed messages and sends the winner if the box should change. resubmitted is the key its
// owner just sent again, if any: only that may re-send an unchanged winner.
void Update(int client, float now, const char[] resubmitted = "")
{
    for (int i = g_count[client] - 1; i >= 0; i--)
    {
        if (g_hints[client][i].expires <= now) Remove(client, i);
    }

    int best = -1;
    for (int i = 0; i < g_count[client]; i++)
    {
        if (best == -1
            || g_hints[client][i].priority > g_hints[client][best].priority
            || (g_hints[client][i].priority == g_hints[client][best].priority && g_hints[client][i].seq > g_hints[client][best].seq))
            best = i;
    }

    if (best == -1)
    {
        if (g_shownKey[client][0] == '\0') return;
        // Nothing current: clear what's left on screen, once.
        g_shownKey[client][0]  = '\0';
        g_shownText[client][0] = '\0';
        PrintHintText(client, "");
        if (g_cvDebug.BoolValue) LogMessage("[GG2 HINT] %N: cleared", client);
        return;
    }

    bool changed = !StrEqual(g_shownKey[client], g_hints[client][best].key) || !StrEqual(g_shownText[client], g_hints[client][best].text);
    if (!changed && (!StrEqual(resubmitted, g_hints[client][best].key) || now - g_shownAt[client] < g_cvResend.FloatValue)) return;

    strcopy(g_shownKey[client], KEY_LEN, g_hints[client][best].key);
    strcopy(g_shownText[client], TEXT_LEN, g_hints[client][best].text);
    g_shownAt[client] = now;
    PrintHintText(client, "%s", g_hints[client][best].text);
    if (g_cvDebug.BoolValue)
        LogMessage("[GG2 HINT] %N: %s [%s pri %d]: %s", client, changed ? "show" : "refresh", g_hints[client][best].key, g_hints[client][best].priority, g_hints[client][best].text);
}

int Find(int client, const char[] key)
{
    for (int i = 0; i < g_count[client]; i++)
    {
        if (StrEqual(g_hints[client][i].key, key)) return i;
    }
    return -1;
}

int Weakest(int client)
{
    int w = 0;
    for (int i = 1; i < g_count[client]; i++)
    {
        if (g_hints[client][i].priority < g_hints[client][w].priority
            || (g_hints[client][i].priority == g_hints[client][w].priority && g_hints[client][i].seq < g_hints[client][w].seq))
            w = i;
    }
    return w;
}

void Remove(int client, int i)
{
    int last = --g_count[client];
    if (i != last) g_hints[client][i] = g_hints[client][last];
}
