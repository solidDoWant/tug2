/* inspired by Nullifidian */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

public Plugin myinfo = {
	name = "[GG2 savelo] saveloadouts (T_SQL)",
	author = "Bot Chris (T_SQL full by zachm)",
	description = "Save Loadout Public M",
	version = "1.1",
	url = ""
};

#define INS_PL_BUYZONE (1 << 7)

bool g_bUsedSaveLoBefore[MAXPLAYERS+1];
bool g_bClassSaveLoBefore[MAXPLAYERS+1];

//cooldown for commands
int loload_cooldowntime[MAXPLAYERS+1] = {-1, ...};
int losave_cooldowntime[MAXPLAYERS+1] = {-1, ...};

//cooldown for ads
int ad_cooldowntime[MAXPLAYERS+1] = {-1, ...};

//strings
char g_sPlayerClassTemplate[MAXPLAYERS+1][64];
char g_sPlayerSaveloClass[MAXPLAYERS+1][64];
char g_sPlayerSteamID[MAXPLAYERS+1][32];
char g_sPlayerSteamID64[MAXPLAYERS+1][64];


char g_sGameMode[32];

ConVar g_server_id;
Database g_Database = null;

public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
    if (strlen(error) != 0) {
        // default player join always attempts to insert to players, safely ignored UNIQUE constraint //
        if (StrContains(error, "UNIQUE constraint failed", false) != 0) {
            char message[2048];
            Format(message, sizeof(message),"%s",error);
            LogMessage("[savelo M] SQL Error: %s", message);
        }
    }
    return;
}

public void T_Connect(Database db, const char[] error, any data) {
    if(db == null){
        LogError("[savelo M] T_Connect returned invalid Database Handle");
        SetFailState("FAILED TO CONNECT TO M DB, BAILING");
        return;
    }
    g_Database = db;
    SQL_SetCharset(g_Database, "utf8mb4");
    LogMessage("[savelo M] Connected to Database.");
    create_table();
    return;
} 

public void create_table() {
    char cmds[1][] = {
		"CREATE TABLE saveloadout (`id` bigint(255) NOT NULL AUTO_INCREMENT PRIMARY KEY, `server_id` int(255) NOT NULL, `steamid` bigint(255) NOT NULL, `classname` varchar(255) NOT NULL, `type` varchar(255) NOT NULL, `itemid` text NULL, INDEX (id, server_id, steamid))  ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    };
    for (int i = 0; i <= sizeof(cmds)-1; i++) {
        char message[32];
        Format(message, sizeof(message),"creating table %i if need be", i);
        //LogMessage("[savelo M] %s", message);
        SQL_TQuery(g_Database, do_nothing, cmds[i]);
    }
}

public void parse_check_used_savelo_before(Handle owner, Handle results, const char[] error, any client) {
    int rows = SQL_GetRowCount(results);
    if (rows != 0) {
		//LogMessage("[savelo M] %N has used savelo before", client);
		g_bUsedSaveLoBefore[client] = true;
    }// else {
	//	LogMessage("[savelo M] %N has NOT used savelo before", client);
	//}
}

public void check_used_savelo_before(int client) {
	char query[512];
	Format(query, sizeof(query), "SELECT steamid FROM saveloadout WHERE steamid = '%s' AND server_id = '%i'", g_sPlayerSteamID64[client], g_server_id.IntValue);
	SQL_TQuery(g_Database, parse_check_used_savelo_before, query, client);
}

public void parse_check_used_savelo_before_class(Handle owner, Handle results, const char[] error, any client) {
	int rows = SQL_GetRowCount(results);
	if (rows != 0) {
		//LogMessage("[savelo M] %N has used savelo before for this class", client);
		g_sPlayerSaveloClass[client] = g_sPlayerClassTemplate[client];
		g_bUsedSaveLoBefore[client] = true;
		g_bClassSaveLoBefore[client] = true;
		loload_cmd_m(client);
		loload_cooldowntime[client] = GetTime();
	}// else {
	//	LogMessage("[savelo M] %N has NOT used savelo before for this class", client);
	//}
}

public void check_used_savelo_before_class(int client, char[] steamid) {
	char query[512];
	Format(query, sizeof(query), "SELECT steamid, classname FROM saveloadout WHERE steamid = '%s' AND classname = '%s' AND server_id = '%i'", g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], g_server_id.IntValue);
	SQL_TQuery(g_Database, parse_check_used_savelo_before_class, query, client);
}

public void OnAllPluginsLoaded() {
	g_server_id = FindConVar("gg_stats_server_id");
}

public void OnPluginStart()
{
	Database.Connect(T_Connect, "insurgency_stats");

	HookEvent("round_freeze_end", Event_RoundFreezeEnd);
	HookEvent("player_pick_squad", Event_PlayerPickSquad_Post, EventHookMode_Post);

	RegConsoleCmd("inventory_reset", inventory_reset_cmd);		//loads saved loadout when player press reset button in inventory
	RegConsoleCmd("inventory_confirm", inventory_confirm_cmd);	//display ad(with cooldown) about save loadout
	RegConsoleCmd("inventory_resupply", inventory_confirm_cmd);	//display ad(with cooldown) about save loadout
	RegConsoleCmd("savelo", losave_cmd_m, "Save your loadout");
}

public void OnMapStart()
{
	PrecacheSound("ui/vote_success.wav", true);
	GetConVarString(FindConVar("mp_gamemode"), g_sGameMode, sizeof(g_sGameMode));
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client)) return;

	//LogMessage("[savelo M] OnClientPostAdminCheck for %N", client);
	g_bUsedSaveLoBefore[client] = false;
	g_bClassSaveLoBefore[client] = false;
	losave_cooldowntime[client] = 0;
	loload_cooldowntime[client] = 0;
	ad_cooldowntime[client] = 0;
	g_sPlayerSaveloClass[client] = "";
	GetClientAuthId(client, AuthId_Steam2, g_sPlayerSteamID[client], sizeof(g_sPlayerSteamID[]));
	GetClientAuthId(client, AuthId_SteamID64, g_sPlayerSteamID64[client], sizeof(g_sPlayerSteamID64[]));

	check_used_savelo_before(client);
}

public Action Event_PlayerPickSquad_Post(Event event, char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IsFakeClient(client)) return Plugin_Continue;

	GetEventString(event, "class_template", g_sPlayerClassTemplate[client], sizeof(g_sPlayerClassTemplate[]));
	int CurrentTime = GetTime();
	
	if (!StrEqual(g_sPlayerClassTemplate[client], g_sPlayerSaveloClass[client])) g_bClassSaveLoBefore[client] = false;
	if (!g_bClassSaveLoBefore[client])
	{
		check_used_savelo_before_class(client, g_sPlayerSteamID64[client]);
	}

	// probably this is worthless since that callback from above won't be done, yet //
	if (g_bClassSaveLoBefore[client])
	{
		loload_cmd_m(client);
		loload_cooldowntime[client] = CurrentTime;
	}
	return Plugin_Continue;
}

public void OnClientDisconnect(int client)
{
	g_bUsedSaveLoBefore[client] = false;
	g_bClassSaveLoBefore[client] = false;
}

public Action Event_RoundFreezeEnd(Event event, char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Continue;

	if (!g_bUsedSaveLoBefore[client]) PrintToChatAll("\x07FFD700[savelo]\x01 You can save your loadout with a \x0700FA9A!savelo\x01 chat command.");
	return Plugin_Continue;
}

void update_or_insert_gear(Handle owner, Handle results, const char[] error, any client) {
	int rows = SQL_GetRowCount(results);
	char sType[32] = "gear";
	char sBuffer[64];
	int gearoffset = GetEntSendPropOffs(client, "m_EquippedGear", true);
	sBuffer = "";
	if (gearoffset != -1) {
		int iGearID = GetEntData(client, gearoffset);
		Format(sBuffer, sizeof(sBuffer), "%d", iGearID);
		for (int i = 4; i <= 24; i+=4) {
			iGearID = GetEntData(client, gearoffset + i);
			if (iGearID != -1) Format(sBuffer, sizeof(sBuffer), "%s;%d", sBuffer, iGearID);
		}
	}
	if (rows == 0) {
		AddWeaponRecord(client, sType, sBuffer);
	} else {
		UpdateWeaponRecord(client, sType, sBuffer);
	}
}

void update_or_insert_primary(Handle owner, Handle results, const char[] error, any client) {
	int rows = SQL_GetRowCount(results);
	char sType[32] = "primary";
	char sBuffer[64];
	int primaryWeapon = GetPlayerWeaponSlot(client, 0);
	if (primaryWeapon != -1) {
		int iWeaponID = GetEntProp(primaryWeapon, Prop_Send, "m_hWeaponDefinitionHandle");
		Format(sBuffer, sizeof(sBuffer), "%d", iWeaponID);
		int upoffset = GetEntSendPropOffs(primaryWeapon, "m_upgradeSlots", true);
		for (int i = 0; i <= 32; i+=4) {
			int iAttachID = GetEntData(primaryWeapon, upoffset + i);
			if (iAttachID != -1) Format(sBuffer, sizeof(sBuffer), "%s;%d", sBuffer, iAttachID);
		}
	}
	if (rows == 0) {
		AddWeaponRecord(client, sType, sBuffer);
	} else {
		UpdateWeaponRecord(client, sType, sBuffer);
	}
}

void update_or_insert_secondary(Handle owner, Handle results, const char[] error, any client) {
	int rows = SQL_GetRowCount(results);
	char sType[32] = "secondary";
	char sBuffer[64];
	int secondaryWeapon = GetPlayerWeaponSlot(client, 1);
	if (secondaryWeapon != -1)
	{
		int iWeaponID = GetEntProp(secondaryWeapon, Prop_Send, "m_hWeaponDefinitionHandle");
		Format(sBuffer, sizeof(sBuffer), "%d", iWeaponID);
		int upoffset = GetEntSendPropOffs(secondaryWeapon, "m_upgradeSlots", true);
		for (int i = 0; i <= 32; i+=4) {
			int iAttachID = GetEntData(secondaryWeapon, upoffset + i);
			if (iAttachID != -1) Format(sBuffer, sizeof(sBuffer), "%s;%d", sBuffer, iAttachID);
		}
	}
	if (rows == 0) {
		AddWeaponRecord(client, sType, sBuffer);
	} else {
		UpdateWeaponRecord(client, sType, sBuffer);
	}

}

void update_or_insert_explosive(Handle owner, Handle results, const char[] error, any client) {
	int rows = SQL_GetRowCount(results);
	char sType[32] = "explosive";
	char sBuffer[64];
	int playerGrenades = GetPlayerWeaponSlot(client, 3);
	if (playerGrenades != -1) {
		int iWeaponID = GetEntProp(playerGrenades, Prop_Send, "m_hWeaponDefinitionHandle");
		Format(sBuffer, sizeof(sBuffer), "%d", iWeaponID);
		int upoffset = GetEntSendPropOffs(playerGrenades, "m_upgradeSlots", true);
		for (int i = 0; i <= 32; i+=4) {
			int iAttachID = GetEntData(playerGrenades, upoffset + i);
			if (iAttachID != -1) Format(sBuffer, sizeof(sBuffer), "%s;%d", sBuffer, iAttachID);
		}
	}
	if (rows == 0) {
		AddWeaponRecord(client, sType, sBuffer);
	} else {
		UpdateWeaponRecord(client, sType, sBuffer);
	}
}


public Action losave_cmd_m(int client, int args) {
	if (IsFakeClient(client) || client <= 0) return Plugin_Handled;

	if(!IsPlayerAlive(client))
	{
		PrintToChat(client, "\x0700FA9A[MC]\x01 Can't save loadout while dead!");
		return Plugin_Handled;
	}
	if (StrEqual(g_sGameMode, "checkpoint"))
	{
		int iFlags = GetEntProp(client, Prop_Send, "m_iPlayerFlags");
		if (!(iFlags & INS_PL_BUYZONE))
		{
			PrintToChat(client,"\x0700FA9A[savelo]\x07F8F8FF You must be\x0700FA9A IN\x07FFD700 BUYING/RESUPPLY\x07F8F8FF ZONE");
			return Plugin_Handled;
		}
	}

	int CurrentTime = GetTime();
	if (CurrentTime-losave_cooldowntime[client] <= 3)
	{
		PrintToChat(client, "\x0700FA9A[savelo]\x01 You must wait before using savelo command again.");
		return Plugin_Handled;
	}
	losave_cooldowntime[client] = CurrentTime;

	FakeClientCommand(client, "inventory_confirm");

	char gear_query[256];
	Format(gear_query, sizeof(gear_query), "SELECT steamid, classname, type, itemid FROM saveloadout WHERE steamid = '%s' AND classname = '%s' AND type = 'gear' AND server_id = '%i'", g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], g_server_id.IntValue);
	SQL_TQuery(g_Database, update_or_insert_gear, gear_query, client);

	char primary_query[256];
	Format(primary_query, sizeof(primary_query), "SELECT steamid, classname, type, itemid FROM saveloadout WHERE steamid = '%s' AND classname = '%s' AND type = 'primary' AND server_id = '%i'", g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], g_server_id.IntValue);
	SQL_TQuery(g_Database, update_or_insert_primary, primary_query, client);

	char secondary_query[256];
	Format(secondary_query, sizeof(secondary_query), "SELECT steamid, classname, type, itemid FROM saveloadout WHERE steamid = '%s' AND classname = '%s' AND type = 'secondary' AND server_id = '%i'", g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], g_server_id.IntValue);
	SQL_TQuery(g_Database, update_or_insert_secondary, secondary_query, client);

	char explosive_query[256];
	Format(explosive_query, sizeof(explosive_query), "SELECT steamid, classname, type, itemid FROM saveloadout WHERE steamid = '%s' AND classname = '%s' AND type = 'explosive' AND server_id = '%i'", g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], g_server_id.IntValue);
	SQL_TQuery(g_Database, update_or_insert_explosive, explosive_query, client);

	g_bUsedSaveLoBefore[client] = true;
	g_bClassSaveLoBefore[client] = true;
	PrintToChat(client, "\x0700FA9A[savelo]\x07F8F8FF Loadout saved.");
	PrintToChat(client, "\x0700FA9A[savelo]\x07FFD700 Your loadout load when you choose your class or by pressing reset button.");
	ClientCommand(client, "play ui/vote_success.wav");

	return Plugin_Handled;
}


public void AddWeaponRecord(int client, const char[] sType, const char[] sBuffer)
{
	char sQuery[255];
	if (sBuffer[0] != '\0') {
		//Format(sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO saveloadout VALUES ('%s','%s','%s','%s')", g_sPlayerSteamID[client], g_sPlayerClassTemplate[client], sType, sBuffer);
		Format(sQuery, sizeof(sQuery), "INSERT INTO saveloadout (server_id, steamid, classname, type, itemid) VALUES ('%i','%s','%s','%s','%s')", g_server_id.IntValue, g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], sType, sBuffer);
	} else {
		//Format(sQuery, sizeof(sQuery), "INSERT OR IGNORE INTO saveloadout VALUES ('%s','%s','%s', NULL)", g_sPlayerSteamID[client], g_sPlayerClassTemplate[client], sType);
		Format(sQuery, sizeof(sQuery), "INSERT INTO saveloadout (server_id, steamid, classname, type) VALUES ('%i','%s','%s','%s')", g_server_id.IntValue, g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], sType);
	}
	SQL_TQuery(g_Database, SQL_ErrorCheckCallBack, sQuery);
}

public void UpdateWeaponRecord(int client, const char[] sType, const char[] sBuffer)
{
	char sQuery[255];
	if (sBuffer[0] != '\0') {
		//Format(sQuery, sizeof(sQuery), "UPDATE OR IGNORE saveloadout SET itemid = '%s' WHERE steamid = '%s' AND classname = '%s' AND type = '%s'", sBuffer, g_sPlayerSteamID[client], g_sPlayerClassTemplate[client], sType);
		Format(sQuery, sizeof(sQuery), "UPDATE saveloadout SET itemid = '%s' WHERE steamid = '%s' AND classname = '%s' AND type = '%s' AND server_id = '%i'", sBuffer, g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], sType, g_server_id.IntValue);
	} else {
		//Format(sQuery, sizeof(sQuery), "UPDATE OR IGNORE saveloadout SET itemid = NULL WHERE steamid = '%s' AND classname = '%s' AND type = '%s'", g_sPlayerSteamID[client], g_sPlayerClassTemplate[client], sType);
		Format(sQuery, sizeof(sQuery), "UPDATE saveloadout SET itemid = NULL WHERE steamid = '%s' AND classname = '%s' AND type = '%s' AND server_id = '%i'", g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], sType, g_server_id.IntValue);
	}
	SQL_TQuery(g_Database, SQL_ErrorCheckCallBack, sQuery);
}

public void SQL_ErrorCheckCallBack(Handle owner, Handle hndl, const char[] error, any data)
{
	if(hndl == INVALID_HANDLE)
	{
		LogMessage("Query failed! %s", error);
		//SetFailState("Query failed! %s", error);
	}
}

void parse_init_loload_cmd_m(Handle owner, Handle results, const char[] error, any client) {
	int rows = SQL_GetRowCount(results);
	if (rows == 0) {
		//LogMessage("[savelo M] Found no saved items for this class on this server for this user, bailing");
		return;
	}

	char sBuffer[64];
	char sType[32];
	char
		GearArray[9][64],
		PrimaryArray[9][64],
		SecondaryArray[9][64],
		ExplosivesArray[9][64];
	
	int iWeaponCount = 0;
	
	sType = "explosive";
	
	while (SQL_FetchRow(results)) {
		SQL_FetchString(results, 2, sType, sizeof(sType));
		//LogMessage("[savelo M] found type: %s", sType);
		if (StrEqual(sType, "gear")) {
			SQL_FetchString(results, 3, sBuffer, sizeof(sBuffer));
			ExplodeString(sBuffer, ";", GearArray, sizeof(GearArray), sizeof(GearArray[]));
		} else if (StrEqual(sType, "primary")) {
			SQL_FetchString(results,3, sBuffer, sizeof(sBuffer));
			ExplodeString(sBuffer, ";", PrimaryArray, sizeof(PrimaryArray), sizeof(PrimaryArray[]));
		} else if (StrEqual(sType, "secondary")) {
			SQL_FetchString(results,3, sBuffer, sizeof(sBuffer));
			ExplodeString(sBuffer, ";", SecondaryArray, sizeof(SecondaryArray), sizeof(SecondaryArray[]));
		} else if (StrEqual(sType, "explosive")) {
			SQL_FetchString(results,3, sBuffer, sizeof(sBuffer));
			ExplodeString(sBuffer, ";", ExplosivesArray, sizeof(ExplosivesArray), sizeof(ExplosivesArray[]));
		}
	}	

	FakeClientCommand(client, "inventory_sell_all");

	if (GearArray[0][0] != '\0')
	{
		FakeClientCommand(client, "inventory_buy_gear %s", GearArray[0]);
		for (int i = 1; i < sizeof(GearArray); i++)
		{
			if (GearArray[i][0] != '\0') FakeClientCommand(client, "inventory_buy_gear %s", GearArray[i]);
			else break;
		}
	}

	iWeaponCount = 0;
	if (PrimaryArray[0][0] != '\0')
	{
		FakeClientCommand(client, "inventory_buy_weapon %s", PrimaryArray[0]);
		iWeaponCount++;
		for (int i = 1; i < sizeof(PrimaryArray); i++)
		{
			if (PrimaryArray[i][0] != '\0') FakeClientCommand(client, "inventory_buy_upgrade %d %s", iWeaponCount, PrimaryArray[i]);
			else break;
		}
	}

	if (SecondaryArray[0][0] != '\0')
	{
		FakeClientCommand(client, "inventory_buy_weapon %s", SecondaryArray[0]);
		iWeaponCount++;
		for (int i = 1; i < sizeof(SecondaryArray); i++)
		{
			if (SecondaryArray[i][0] != '\0') FakeClientCommand(client, "inventory_buy_upgrade %d %s", iWeaponCount, SecondaryArray[i]);
			else break;
		}
	}

	if (ExplosivesArray[0][0] != '\0')
	{
		FakeClientCommand(client, "inventory_buy_weapon %s", ExplosivesArray[0]);
		iWeaponCount++;
		for (int i = 1; i < sizeof(ExplosivesArray); i++)
		{
			if (ExplosivesArray[i][0] != '\0') FakeClientCommand(client, "inventory_buy_upgrade %d %s", iWeaponCount, ExplosivesArray[i]);
			else break;
		}
	}
	
}

void loload_cmd_m(int client) {
	char query[256];
	Format(query, sizeof(query), "SELECT steamid, classname, type, itemid FROM saveloadout WHERE steamid = '%s' AND classname = '%s' AND server_id = '%i'", g_sPlayerSteamID64[client], g_sPlayerClassTemplate[client], g_server_id.IntValue);
	SQL_TQuery(g_Database, parse_init_loload_cmd_m, query, client);
}


public Action inventory_reset_cmd(int client, int args)
{
	if (!g_bClassSaveLoBefore[client] || IsFakeClient(client)) return Plugin_Continue;
	int CurrentTime = GetTime();

	if (CurrentTime-loload_cooldowntime[client] > 3)
	{
		if (g_bClassSaveLoBefore[client])
		{
			loload_cmd_m(client);
			loload_cooldowntime[client] = CurrentTime;
			return Plugin_Handled;
		}
	}
	return Plugin_Continue;
}

public Action inventory_confirm_cmd(int client, int args)
{
	if (!IsFakeClient(client) && !g_bUsedSaveLoBefore[client])
	{
		int CurrentTime = GetTime();
		if (CurrentTime-ad_cooldowntime[client] > 180)
		{
			PrintToChat(client, "\x0700FA9A[savelo]\x01 You can save your loadout with a \x0700FA9A!savelo\x01 command.");
			ad_cooldowntime[client] = CurrentTime;
		}
	}
	return Plugin_Continue;
}

bool IsValidPlayer(int client) {
	return (0 < client <= MaxClients) && IsClientInGame(client);
}