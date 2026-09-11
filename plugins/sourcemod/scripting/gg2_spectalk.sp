/**
 * [GG2 SPECTALK] Let spectators be heard in text chat.
 *
 * WHY THIS EXISTS
 * A spectator's text chat reaches nobody on a playing team, and there is no cvar that changes it.
 * Voice already crosses teams - sv_alltalk, sv_alltalk_dead and sv_deadvoice are all on - but text
 * is a separate system:
 *
 *   sv_allchat 1        "Players can receive all other players' text chat, TEAM RESTRICTIONS APPLY"
 *   sv_deadtalk 1       covers DEAD players, i.e. someone on a playing team who is not alive
 *   sv_deadtalk_team 1  same
 *
 * A spectator is on neither playing team, so the deadtalk pair does not apply to them and allchat
 * keeps them boxed in. Checked against the live server: nothing under "find chat", "find spectator",
 * "find alltalk", "find deadtalk" or "find deadvoice" covers spectator-to-team text.
 *
 * WHAT IT DOES
 * Re-prints a spectator's open chat to everyone on a playing team, tagged so it is obvious where it
 * came from. It does NOT suppress the original message, which matters for two reasons: whatever
 * native routing exists between spectators keeps working, and gg2_discord's own "say" listener
 * still sees the message, so the Discord relay is unaffected. Suppressing would have made that
 * depend on plugin load order.
 */

#include <sourcemod>
#include <morecolors>

#pragma newdecls required
#pragma semicolon 1

#define TEAM_SPEC   1
#define TEAM_SEC    2
#define TEAM_INS    3

ConVar g_cvEnabled;
ConVar g_cvIncludeTeamChat;
ConVar g_cvEchoSpectators;

public Plugin myinfo =
{
    name        = "[GG2 SPECTALK] Spectator Chat Relay",
    author      = "TUG",
    description = "Relays spectator text chat to the playing teams",
    version     = "1.0.0",
    url         = "https://github.com/solidDoWant/tug2"
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_spectalk_enabled", "1",
        "Relay spectator text chat to the playing teams.", _, true, 0.0, true, 1.0);

    // Open chat is the natural way to address the server, so that is what relays by default. Team
    // chat among spectators is plausibly meant to stay among spectators, so it is opt-in.
    g_cvIncludeTeamChat = CreateConVar("sm_spectalk_include_team_chat", "0",
        "Also relay a spectator's TEAM chat. Off by default - spectators may be using it to talk among themselves.", _, true, 0.0, true, 1.0);

    // Whether other spectators already see the message natively is untested. If they do, echoing
    // would show it to them twice; if they do not, they miss each other entirely. Default assumes
    // native routing covers them - flip this if testing shows otherwise.
    g_cvEchoSpectators = CreateConVar("sm_spectalk_echo_spectators", "0",
        "Also print the relayed line to other spectators. Only needed if spectators cannot see each other's chat natively.", _, true, 0.0, true, 1.0);

    AddCommandListener(Listener_Say, "say");
    AddCommandListener(Listener_SayTeam, "say_team");
}

public Action Listener_Say(int client, const char[] command, int argc)
{
    Relay(client, false);
    return Plugin_Continue;
}

public Action Listener_SayTeam(int client, const char[] command, int argc)
{
    if (g_cvIncludeTeamChat.BoolValue) Relay(client, true);
    return Plugin_Continue;
}

void Relay(int client, bool teamChat)
{
    if (!g_cvEnabled.BoolValue) return;
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return;
    if (GetClientTeam(client) != TEAM_SPEC) return;

    char message[256];
    GetCmdArgString(message, sizeof(message));
    StripQuotes(message);
    TrimString(message);

    if (message[0] == '\0') return;

    // Chat triggers are commands, not conversation. SourceMod consumes "!help" and "/afk" itself,
    // and relaying them would both leak the command and spam the teams with it.
    if (message[0] == '!' || message[0] == '/') return;

    bool echoSpec = g_cvEchoSpectators.BoolValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;

        int team = GetClientTeam(i);
        if (team == TEAM_SPEC && !echoSpec) continue;

        // Never echo back to the speaker - they already see their own message.
        if (i == client) continue;

        CPrintToChat(i, "{lightgreen}(SPEC)%s {default}%N{default}: %s",
                     teamChat ? " (team)" : "", client, message);
    }
}
