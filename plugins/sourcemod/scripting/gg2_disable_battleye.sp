#include <sourcemod>
#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =  
{
	name = "No Battleye",
	author = "whatever",
	description = "Server will disable Battleye",
	version = "1.0",
	url = ""
}

ConVar sm_battleye;

public void OnPluginStart()
{
	sm_battleye = CreateConVar("sm_battleye", "0", "battleye enable/disable", FCVAR_PROTECTED);
}

public void OnConfigsExecuted()
{
	ConVar cvar = FindConVar("sv_battleye");
	if (sm_battleye.BoolValue)
	{
		SetConVarBounds(cvar, ConVarBound_Lower, true, 0.0);
		SetConVarBounds(cvar, ConVarBound_Upper, true, 1.0);
		SetConVarInt(cvar, 1, true);
	}
	else
	{
		SetConVarBounds(cvar, ConVarBound_Lower, true, 0.0);
		SetConVarBounds(cvar, ConVarBound_Upper, true, 0.0);
		SetConVarInt(cvar, 0, true);
	}
}
