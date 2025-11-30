#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_LOG_PREFIX "INSLIB"

#include <sourcemod>
#include <insurgencydy>

// Cache for ins_objective_resource entity and its netclass
// Updated by GetEntity_ObjectiveResource() on first call or when entity becomes invalid
int  g_iObjResEntity;
char g_sObjResEntityNetClass[32];

public Plugin myinfo =
{
    name        = "[GG2 INSURGENCY] Insurgency Support Library",
    author      = "Jared Ballou (jballou)",
    description = "Provides functions to support Insurgency. Includes logging, round statistics, weapon names, player class names, and more.",
    version     = "1.4.6",
    url         = "http://jballou.com/insurgency"
};

public APLRes Plugin_Setup_natives()
{
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

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("insurgency");
    return Plugin_Setup_natives();
}

// Updates the objective resource entity cache if needed
// Returns true if the entity is valid, false otherwise
bool GetEntity_ObjectiveResource()
{
    if (g_iObjResEntity < 1 || !IsValidEntity(g_iObjResEntity))
    {
        g_iObjResEntity = FindEntityByClassname(0, "ins_objective_resource");
        GetEntityNetClass(g_iObjResEntity, g_sObjResEntityNetClass, sizeof(g_sObjResEntityNetClass));
        InsLog(DEBUG, "g_sObjResEntityNetClass %s", g_sObjResEntityNetClass);
    }

    if (g_iObjResEntity)
        return true;

    InsLog(WARN, "GetEntity_ObjectiveResource failed!");
    return false;
}

public int Native_GetPlayerScore(Handle plugin, int numParams)
{
    int iPlayerManager = FindEntityByClassname(0, "ins_player_manager");
    if (iPlayerManager <= 0) return 0;

    char iPlayerManagerNetClass[32];
    if (!GetEntityNetClass(iPlayerManager, iPlayerManagerNetClass, sizeof(iPlayerManagerNetClass))) return 0;

    int client = GetNativeCell(1);
    if (!IsValidClient(client) || iPlayerManager <= 0) return 0;

    int offset = FindSendPropInfo(iPlayerManagerNetClass, "m_iPlayerScore");
    if (offset == -1) return 0;
    offset += (4 * client);

    return GetEntData(iPlayerManager, offset);
}

public int Native_InCounterAttack(Handle plugin, int numParams)
{
    return GameRules_GetProp("m_bCounterAttack");
}

public int Native_ObjectiveResource_GetProp(Handle plugin, int numParams)
{
    int len;
    if (GetNativeStringLength(1, len) != SP_ERROR_NONE || len <= 0) return -1;

    char[] prop = new char[len + 1];
    if (GetNativeString(1, prop, len + 1) != SP_ERROR_NONE) return -1;

    if (!GetEntity_ObjectiveResource()) return -1;

    int offset = FindSendPropInfo(g_sObjResEntityNetClass, prop);
    if (offset == -1) return -1;

    int size    = GetNativeCell(2);
    int element = GetNativeCell(3);
    offset += (size * element);

    return GetEntData(g_iObjResEntity, offset);
}

public int Native_ObjectiveResource_GetPropFloat(Handle plugin, int numParams)
{
    int len;
    if (GetNativeStringLength(1, len) != SP_ERROR_NONE || len <= 0) return -1;

    char[] prop = new char[len + 1];
    if (GetNativeString(1, prop, len + 1) != SP_ERROR_NONE) return -1;

    if (!GetEntity_ObjectiveResource()) return -1;

    int offset = FindSendPropInfo(g_sObjResEntityNetClass, prop);
    if (offset == -1) return -1;

    int size    = GetNativeCell(2);
    int element = GetNativeCell(3);
    offset += (size * element);

    return view_as<int>(GetEntDataFloat(g_iObjResEntity, offset));
}

public int Native_ObjectiveResource_GetPropEnt(Handle plugin, int numParams)
{
    int len;
    if (GetNativeStringLength(1, len) != SP_ERROR_NONE || len <= 0) return -1;

    char[] prop = new char[len + 1];
    if (GetNativeString(1, prop, len + 1) != SP_ERROR_NONE) return -1;

    if (GetEntity_ObjectiveResource()) return -1;

    int offset = FindSendPropInfo(g_sObjResEntityNetClass, prop);
    if (offset == -1) return -1;

    int element = GetNativeCell(2);
    offset += (4 * element);

    return GetEntData(g_iObjResEntity, offset);
}

public int Native_ObjectiveResource_GetPropBool(Handle plugin, int numParams)
{
    int len;
    if (GetNativeStringLength(1, len) != SP_ERROR_NONE || len <= 0) return -1;

    char[] prop = new char[len + 1];
    if (GetNativeString(1, prop, len + 1) != SP_ERROR_NONE) return -1;

    if (!GetEntity_ObjectiveResource()) return -1;

    int offset = FindSendPropInfo(g_sObjResEntityNetClass, prop);
    if (offset == -1) return -1;

    int element = GetNativeCell(2);
    offset += (1 * element);

    return GetEntData(g_iObjResEntity, offset);
}

public int Native_ObjectiveResource_GetPropVector(Handle plugin, int numParams)
{
    int len;
    if (GetNativeStringLength(1, len) != SP_ERROR_NONE || len <= 0) return -1;

    char[] prop = new char[len + 1];
    if (GetNativeString(1, prop, len + 1) != SP_ERROR_NONE) return -1;

    if (!GetEntity_ObjectiveResource()) return -1;

    int offset = FindSendPropInfo(g_sObjResEntityNetClass, prop);
    if (offset == -1) return -1;

    int size    = 12;    // Size of data slice - 3x4-byte floats
    int element = GetNativeCell(3);
    offset += (size * element);

    float result[3];
    GetEntDataVector(g_iObjResEntity, offset, result);
    SetNativeArray(2, result, 3);

    return 1;
}

public int Native_ObjectiveResource_GetPropString(Handle plugin, int numParams)
{
    // The previous implementation did nothing at all except eat CPU cycles. If this is needed at some point, it should
    // be actually implemented.
    // There are currently no callers of this function.
    return -1;
}
