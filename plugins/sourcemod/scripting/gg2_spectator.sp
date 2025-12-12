#include <sourcemod>
#include <sdktools>
#pragma semicolon 1
#pragma newdecls required
#define PLUGIN_VERSION "1.2.1"
#define TEAM_SPEC      1

#undef REQUIRE_PLUGIN

Handle SpecMoveEnabled;

public Plugin myinfo =
{
    name        = "[GG2 SPEC] Spectator Switch",
    author      = "HSFighter",
    description = "Allows player to move himself to spectator",
    version     = PLUGIN_VERSION,
    url         = "http://www.hsfighter.net"
};

public void OnPluginStart()
{
    // Register Cvars
    CreateConVar("sm_spec_version", PLUGIN_VERSION, "Spectator Switch Version", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
    SpecMoveEnabled = CreateConVar("sm_spec_enable", "1", "Enable/Disable Spectator Switch", 0, true, 0.0, true, 1.0);

    // Register Admin Commands
    RegAdminCmd("sm_spec", Command_Move, ADMFLAG_KICK, "sm_spec <#userid|name>");

    // Register Console Commands
    RegConsoleCmd("sm_afk", Move, "Move yourself to spectator", 0);
    LoadTranslations("common.phrases");
}

public Action Command_Move(int client, int args)
{
    // Check if plugin is disabled
    if (!GetConVarBool(SpecMoveEnabled)) return Plugin_Handled;

    if (!CheckClient(client)) return Plugin_Handled;

    // Return usage if no arguments
    if (args < 1)
    {
        ReplyToCommand(client, "sm_spec <#userid|name>");
        return Plugin_Handled;
    }

    // Validate the target
    char arg1[65];
    GetCmdArg(1, arg1, sizeof(arg1));

    int target = FindTarget(client, arg1);
    if (target == -1) return Plugin_Handled;

    if (GetClientTeam(target) == TEAM_SPEC) return Plugin_Handled;

    PrintToChatAll("\x01[Spectator Switch] \x03%N\x04 was moved to spectator by: \x03%N", target, client);
    Move(target, 0);

    return Plugin_Handled;
}

public Action Move(int target, int args)
{
    if (!CheckClient(target)) return Plugin_Handled;

    if (GetClientTeam(target) == TEAM_SPEC) return Plugin_Handled;

    // move the player to the spectator
    ChangeClientTeam(target, TEAM_SPEC);
    ForcePlayerSuicide(target);

    return Plugin_Handled;
}

public bool CheckClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}