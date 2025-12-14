#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public Plugin myinfo =
{
    name        = "[GG2 Votekick Immunity] Kickvote Immunity",
    author      = "Neko-",
    description = "player kick votes to obey SM immunity levels",
    version     = "1.0.0"
};

static const char g_VoteReasons[][] = {
    "kick",
    "kickid",
    "ban",
    "banid"
};

bool IsProtectedVoteReason(const char[] reason)
{
    for (int i = 0; i < sizeof(g_VoteReasons); i++)
    {
        if (StrEqual(reason, g_VoteReasons[i], false)) return true;
    }

    return false;
}

public void OnPluginStart()
{
    AddCommandListener(Event_CallVote, "callvote");
}

public Action Event_CallVote(int requesterClient, char[] cmd, int argc)
{
    if (argc < 2) return Plugin_Continue;

    char voteReason[16];
    GetCmdArg(1, voteReason, sizeof(voteReason));

    if (!IsProtectedVoteReason(voteReason)) return Plugin_Continue;

    char targetName[256];
    GetCmdArg(2, targetName, sizeof(targetName));

    Format(targetName, sizeof(targetName), "#%s", targetName);

    int targetClient = FindTarget(requesterClient, targetName, true, false);
    if (targetClient < 1) return Plugin_Continue;

    // Skip the check if a non-admin is being targeted
    AdminId targetAdmin = GetUserAdmin(targetClient);
    if (targetAdmin == INVALID_ADMIN_ID) return Plugin_Continue;

    AdminId requesterAdmin = GetUserAdmin(requesterClient);
    if (CanAdminTarget(requesterAdmin, targetAdmin)) return Plugin_Continue;

    PrintToChat(requesterClient, "You are not allowed to vote this player!");
    LogMessage("[GG2 VK IMMUNITY] %N attempted to votekick %N (and failed)", requesterClient, targetClient);

    return Plugin_Handled;
}