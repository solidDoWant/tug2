#if defined _gg2_hint_included
    #endinput
#endif
#define _gg2_hint_included

// One hint-text box per player, shared fairly (gg2_hint.sp).
//
// Every plugin used to call PrintHintText directly, so the box showed whoever wrote last: the health
// display, the enemy count, medic progress and warnings overwrote each other and flickered. Plugins now
// hand their message to gg2_hint with a key, a priority and how long it stays relevant, and gg2_hint
// shows each player the highest-priority message that is still current. A plugin re-sends its message
// (same key) to keep it current or change it; when it lapses, the next one down shows again.
//
// Use HintShow / HintShowAll / HintClear below rather than the natives: they format in the calling
// plugin (so its translations work) and fall back to plain PrintHintText when gg2_hint isn't loaded.

// Priorities. Higher wins; on a tie, the message set most recently wins.
#define HINT_PRI_AMBIENT  0     // always-on displays (health)
#define HINT_PRI_INFO     10    // periodic information (enemies remaining)
#define HINT_PRI_STATUS   20    // status of what the player is holding (fire support readiness)
#define HINT_PRI_ACTIVITY 30    // something the player is doing right now (healing, reviving)
#define HINT_PRI_NOTICE   40    // one-off events (revived, killed, reinforcements, command replies)
#define HINT_PRI_WARNING  50    // warnings that need attention now (team damage, overheating)

#define HINT_MAX_TEXT 254       // the HintText user message carries at most 255 bytes

// Sets (or replaces) the message under key for client, current for duration seconds.
native void Hint_Set(int client, const char[] key, int priority, float duration, const char[] text);

// Withdraws the message under key for client, if any.
native void Hint_Clear(int client, const char[] key);

stock void HintShow(int client, const char[] key, int priority, float duration, const char[] format, any...)
{
    char text[HINT_MAX_TEXT + 1];
    SetGlobalTransTarget(client);
    VFormat(text, sizeof(text), format, 6);

    if (GetFeatureStatus(FeatureType_Native, "Hint_Set") == FeatureStatus_Available)
        Hint_Set(client, key, priority, duration, text);
    else
        PrintHintText(client, "%s", text);
}

// HintShow for every human player in game; %t translates for each of them.
stock void HintShowAll(const char[] key, int priority, float duration, const char[] format, any...)
{
    char text[HINT_MAX_TEXT + 1];
    bool native_ok = GetFeatureStatus(FeatureType_Native, "Hint_Set") == FeatureStatus_Available;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client)) continue;

        SetGlobalTransTarget(client);
        VFormat(text, sizeof(text), format, 5);
        if (native_ok)
            Hint_Set(client, key, priority, duration, text);
        else
            PrintHintText(client, "%s", text);
    }
}

stock void HintClear(int client, const char[] key)
{
    if (GetFeatureStatus(FeatureType_Native, "Hint_Clear") == FeatureStatus_Available)
        Hint_Clear(client, key);
}

public SharedPlugin __pl_gg2_hint =
{
    name = "gg2_hint",
    file = "gg2_hint.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_gg2_hint_SetNTVOptional()
{
    MarkNativeAsOptional("Hint_Set");
    MarkNativeAsOptional("Hint_Clear");
}
#endif
