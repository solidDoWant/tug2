#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public Plugin myinfo =
{
	name = "[GG2 Votekick Immunity] Kickvote Immunity",
	author = "Neko-",
	description = "player kick votes to obey SM immunity levels",
	version = "1.0.0"
};

public void OnPluginStart()
{
	AddCommandListener(callvoteListener, "callvote");
}

public Action callvoteListener(int client, char[] cmd, int argc)
{
	if (argc < 2)
		return Plugin_Continue;
	
	char votereason[16];
	GetCmdArg(1, votereason, sizeof(votereason));
	
	if ((StrEqual(votereason, "kick", false)) ||
	(StrEqual(votereason, "kickid", false)) ||
	(StrEqual(votereason, "ban", false)) ||
	(StrEqual(votereason, "banid", false)))
	{
		char strName[256];
		GetCmdArg(2, strName, sizeof(strName));
		
		Format(strName, sizeof(strName), "#%s", strName);
		int target = FindTarget(client, strName, true, false);
		if (target < 1)
		{
			return Plugin_Continue;
		}
		
		AdminId clientAdmin = GetUserAdmin(client);
		AdminId targetAdmin = GetUserAdmin(target);
		
		if(clientAdmin == INVALID_ADMIN_ID && targetAdmin == INVALID_ADMIN_ID)
		{
			return Plugin_Continue;
		}
		
		if(CanAdminTarget(clientAdmin, targetAdmin))
		{
			return Plugin_Continue;
		}
		
		PrintToChat(client, "You are not allowed to vote this player!");
		LogMessage("[GG2 VK IMMUNITY] %N attempted to votekick %N (and failed)", client, target);
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}