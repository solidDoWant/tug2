#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_LOG_PREFIX "INSLIB"

#include <sourcemod>
#include <insurgencydy>

int		g_iObjResEntity;
char	g_sObjResEntityNetClass[32];


public Plugin myinfo = {
	name = "[GG2 INSURGENCY] Insurgency Support Library",
	author = "Jared Ballou (jballou)",
	description = "Provides functions to support Insurgency. Includes logging, round statistics, weapon names, player class names, and more.",
	version = "1.4.5",
	url = "http://jballou.com/insurgency"
};

public APLRes Plugin_Setup_natives() {
	CreateNative("Ins_ObjectiveResource_GetProp", Native_ObjectiveResource_GetProp);
	CreateNative("Ins_ObjectiveResource_GetPropFloat", Native_ObjectiveResource_GetPropFloat);
	CreateNative("Ins_ObjectiveResource_GetPropEnt", Native_ObjectiveResource_GetPropEnt);
	CreateNative("Ins_ObjectiveResource_GetPropBool", Native_ObjectiveResource_GetPropBool);
	CreateNative("Ins_ObjectiveResource_GetPropVector", Native_ObjectiveResource_GetPropVector);
	CreateNative("Ins_ObjectiveResource_GetPropString", Native_ObjectiveResource_GetPropString);
	CreateNative("Ins_InCounterAttack", Native_InCounterAttack);
	CreateNative("Ins_GetPlayerScore", Native_GetPlayerScore);
	return APLRes_Success;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	RegPluginLibrary("insurgency");
	return Plugin_Setup_natives();
}

int GetEntity_ObjectiveResource(int always=0) {
	if ((g_iObjResEntity < 1 || !IsValidEntity(g_iObjResEntity)) || always) {
		g_iObjResEntity = FindEntityByClassname(0,"ins_objective_resource");
		GetEntityNetClass(g_iObjResEntity, g_sObjResEntityNetClass, sizeof(g_sObjResEntityNetClass));
		InsLog(DEBUG,"g_sObjResEntityNetClass %s",g_sObjResEntityNetClass);
	}
	if (g_iObjResEntity)
		return g_iObjResEntity;
	InsLog(WARN,"GetEntity_ObjectiveResource failed!");
	return -1;
}

public int Native_GetPlayerScore(Handle plugin, int numParams) {
	
	int retval = 0;
	int client = GetNativeCell(1);
	int iPlayerManager;
	char iPlayerManagerNetClass[32];
	iPlayerManager = FindEntityByClassname(0,"ins_player_manager");
	GetEntityNetClass(iPlayerManager, iPlayerManagerNetClass, sizeof(iPlayerManagerNetClass));
	if ((IsValidClient(client)) && (iPlayerManager > 0)) {
		retval = GetEntData(iPlayerManager, FindSendPropInfo(iPlayerManagerNetClass, "m_iPlayerScore") + (4 * client));
	}
	return retval;
}

int InCounterAttack() {
	return GameRules_GetProp("m_bCounterAttack");
}

public int Native_InCounterAttack(Handle plugin, int numParams) {
	return InCounterAttack();
}

public int Native_ObjectiveResource_GetProp(Handle plugin, int numParams) {
	int len;
	GetNativeStringLength(1, len);
	if (len <= 0) {
		return false;
	}
	char[] prop = new char[len+1];
	int retval = -1;
	GetNativeString(1, prop, len+1);
	int size = GetNativeCell(2);
	int element = GetNativeCell(3);
	GetEntity_ObjectiveResource();
	if (g_iObjResEntity > 0) {
		retval = GetEntData(g_iObjResEntity, FindSendPropInfo(g_sObjResEntityNetClass, prop) + (size * element));
	}
	return retval;
}

public int Native_ObjectiveResource_GetPropFloat(Handle plugin, int numParams) {
	int len;
	GetNativeStringLength(1, len);
	if (len <= 0) {
		return false;
	}
	char[] prop = new char[len+1];
	float retval = -1.0;
	GetNativeString(1, prop, len+1);
	int size = GetNativeCell(2);
	int element = GetNativeCell(3);
	GetEntity_ObjectiveResource();
	if (g_iObjResEntity > 0) {
		retval = GetEntDataFloat(g_iObjResEntity, FindSendPropInfo(g_sObjResEntityNetClass, prop) + (size * element));
	}
	return view_as<int>(retval);
}

public int Native_ObjectiveResource_GetPropEnt(Handle plugin, int numParams)
{
	int len;
	GetNativeStringLength(1, len);
	if (len <= 0) {
		return false;
	}
	char[] prop = new char[len+1];
	int retval = -1;
	GetNativeString(1, prop, len+1);
	int element = GetNativeCell(2);
	GetEntity_ObjectiveResource();
	if (g_iObjResEntity > 0) {
		retval = GetEntData(g_iObjResEntity, FindSendPropInfo(g_sObjResEntityNetClass, prop) + (4 * element));
	}
	return retval;
}

public int Native_ObjectiveResource_GetPropBool(Handle plugin, int numParams) {
	int len;
	GetNativeStringLength(1, len);
	if (len <= 0)
	{
	return false;
	}
	char[] prop = new char[len+1];
	int retval = -1;
	GetNativeString(1, prop, len+1);
	int element = GetNativeCell(2);
	GetEntity_ObjectiveResource();
	if (g_iObjResEntity > 0) {
		retval = GetEntData(g_iObjResEntity, FindSendPropInfo(g_sObjResEntityNetClass, prop) + (element));
	}
	return view_as<int>(retval);
}

public int Native_ObjectiveResource_GetPropVector(Handle plugin, int numParams) {
	int len;
	GetNativeStringLength(1, len);
	if (len <= 0) {
	return false;
	}
	char[] prop = new char[len+1];
	int size = 12; // Size of data slice - 3x4-byte floats
	GetNativeString(1, prop, len+1);
	int element = GetNativeCell(3);
	GetEntity_ObjectiveResource();
	float result[3];
	if (g_iObjResEntity > 0) {
		GetEntDataVector(g_iObjResEntity, FindSendPropInfo(g_sObjResEntityNetClass, prop) + (size * element), result);
		SetNativeArray(2, result, 3);
	}
	return 1;
}

public int Native_ObjectiveResource_GetPropString(Handle plugin, int numParams) {
	int len;
	GetNativeStringLength(1, len);
	if (len <= 0) {
		return false;
	}
	char[] prop = new char[len+1];
	int retval = -1;
	GetNativeString(1, prop, len+1);
	return retval;
}
