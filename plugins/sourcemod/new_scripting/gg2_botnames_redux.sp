#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.1"
#define PLUGIN_DESCRIPTION "Rename bawts according to their client id"
#define BOT_NAME_PATH "configs/botnames"

Handle cvarNameList = INVALID_HANDLE; // list to use
char g_bot_names[MAXPLAYERS+1][64];

public Plugin myinfo =
{
	name = "[GG2] Bot Names REDUX",
	author = "wtf.mkv",
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = ""
}

public void OnPluginStart() {
	
	cvarNameList = CreateConVar("sm_botnames_list_redux", "default", "Set list to use for bots", FCVAR_NOTIFY | 0);	
	RegServerCmd("sm_botnames_reload", Command_Reload);
	AutoExecConfig(true, "botnames_redux");
	reload_names();
}

public void OnMapStart() {
	reload_names();
}

public Action Command_Reload(int args) {
	reload_names();
	return Plugin_Continue;
}

public void OnClientPutInServer(int client) {
	//LogToGame("[GG2 botnames] OnClientPutInServer:: %N", client);
	if (IsFakeClient(client)) {
		CreateTimer(0.1, botname_Timer, client, TIMER_FLAG_NO_MAPCHANGE);
	}
	
}

public Action botname_Timer(Handle timer, int client) {
	RenameBot(client);
	return Plugin_Continue;
}

public bool RenameBot(int client) {
	if (IsFakeClient(client)) {
		char oldname[MAX_NAME_LENGTH];
		GetClientName(client, oldname, sizeof(oldname));
		char newname[MAX_NAME_LENGTH];
		newname = g_bot_names[client];

		SetClientInfo(client, "name", newname);
		SetEntPropString(client, Prop_Data, "m_szNetname", newname);

		// create an event to capture it, i guess maybe...
		Handle nameChangeEvent = CreateEvent("player_changename");
		SetEventInt(nameChangeEvent, "userid", GetClientUserId(client));
		SetEventString(nameChangeEvent, "oldname", oldname);
		SetEventString(nameChangeEvent, "newname", newname);
		FireEvent(nameChangeEvent);
		return true;
	}
	return false;
}

public Action reload_names() {
	char path[PLATFORM_MAX_PATH];
	char basepath[PLATFORM_MAX_PATH];
	char filename[32];
	GetConVarString(cvarNameList,filename,sizeof(filename));
	BuildPath(Path_SM, basepath, sizeof(basepath), BOT_NAME_PATH);
	Format(path, sizeof(path), "%s/%s.txt", basepath, filename);
	if (!FileExists(path)) {
		PrintToServer("[BOTNAMES REDUX]: Cannot find %s, using default!",path);
		Format(path, sizeof(path), "%s/%s.txt", basepath, "default");
	}
	
	Handle file = OpenFile(path, "r");
	if (file == INVALID_HANDLE)
	{
		LogError("[BOTNAMES REDUX] Cannot open %s",path);
		return Plugin_Stop;
	}

	char new_bot_name[64];
	int client_offset = 1;
	while (IsEndOfFile(file) == false)
	{
		if (client_offset == MAXPLAYERS) {
			PrintToServer("[BOTNAMES REDUX] reached max player capacity (%i), skipping the rest", client_offset);
			break;
		}
		if (ReadFileLine(file, new_bot_name, sizeof(new_bot_name)) == false)
		{
			break;
		}
		int comment_check = -1;
		comment_check = StrContains(new_bot_name, "//");
		if (comment_check == 0) {
			continue;
		}
		comment_check = StrContains(new_bot_name, "#");
		if (comment_check == 0) {
			continue;
		}
		// looks like we got a name
		TrimString(new_bot_name);
		g_bot_names[client_offset] = new_bot_name;
		client_offset++;
	}
	PrintToServer("[BOTNAMES REDUX] loaded up %i BOTNAMES // %s --> %s", client_offset-1, g_bot_names[1], g_bot_names[client_offset-1]);
	CloseHandle(file);
	return Plugin_Continue;
}