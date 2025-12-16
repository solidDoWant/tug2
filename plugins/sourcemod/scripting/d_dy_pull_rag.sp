//(C) 2014 Jared Ballou <sourcemod@jballou.com>
// Released under GPLv3

#pragma semicolon 1

#include <sourcemod>
#undef REQUIRE_PLUGIN
#include <sdktools>
#define PLUGIN_VERSION     "0.0.1"
#define PLUGIN_DESCRIPTION "Plugin for Pulling prop_ragdoll bodies"

#define IN_SPRINT          IN_ALT2    // sprint key in insurgency
#define MAX_BUTTONS        25

//(button == IN_MOVELEFT || button == IN_MOVERIGHT || button == IN_JUMP) Ones jump
//(button == IN_BACK || button == IN_LEFT || button == IN_RIGHT) one is Z
// if(button == IN_SPEED || button == IN_USE || button == IN_RUN) v, s and x or reverse s and x
// if(button == IN_DUCK || button == IN_CANCEL || button == IN_BACK) // ctrl, w and f

int g_LastButtons[MAXPLAYERS + 1];
int g_playerCurrentRag[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "[INS] Pull Rag",
    author      = "Daimyo",
    description = PLUGIN_DESCRIPTION,
    version     = PLUGIN_VERSION,
    url         = ""
};

public OnPluginStart()
{
    HookEvent("player_disconnect", Event_PlayerDisconnect_Post, EventHookMode_Post);
}

public Action Event_PlayerDisconnect_Post(Handle event, const char[] name, bool dontBroadcast)
{
    int client            = GetClientOfUserId(GetEventInt(event, "userid"));
    g_LastButtons[client] = 0;
    return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (IsFakeClient(client)) return Plugin_Continue;
    for (int i = 0; i < MAX_BUTTONS; i++)
    {
        int button = (1 << i);
        if ((buttons & button))
            OnButtonPress(client, button, buttons);
    }

    g_LastButtons[client] = buttons;
    return Plugin_Continue;
}

Action OnButtonPress(int client, int button, int buttons)
{
    float eyepos[3];
    GetClientEyePosition(client, eyepos);    // Position of client's eyes.

    // PrintToServer("Client Eye Height %f",eyepos[2]);

    if (button != IN_SPRINT || !(buttons & IN_DUCK) || (buttons & IN_FORWARD) || (buttons & IN_ATTACK2) || (buttons & IN_ATTACK)) return Plugin_Continue;
    // PrintToServer("DEBUG 50000000000000");

    int clientTargetRagdoll = GetClientAimTarget(client, false);
    if (clientTargetRagdoll == -1) return Plugin_Continue;
    char entClassname[128];
    GetEntityClassname(clientTargetRagdoll, entClassname, sizeof(entClassname));
    if (!IsValidEdict(clientTargetRagdoll) || !IsValidEntity(clientTargetRagdoll) || !StrEqual(entClassname, "prop_ragdoll", false)) return Plugin_Continue;

    // Verify other players are not dragging body
    for (int tclient = 1; tclient <= MaxClients; tclient++)
    {
        if (client == tclient || tclient < 0 || !IsClientInGame(tclient) || IsFakeClient(tclient)) continue;
        int verifyRagdoll = EntRefToEntIndex(g_playerCurrentRag[tclient]);
        if (verifyRagdoll == -1 || verifyRagdoll == INVALID_ENT_REFERENCE) continue;
        if (verifyRagdoll != EntRefToEntIndex(clientTargetRagdoll)) continue;

        return Plugin_Continue;
    }

    float fReviveDistance = 80.0;
    float vecPos[3];
    float ragPos[3];
    float tDistance;
    GetClientAbsOrigin(client, vecPos);
    GetEntPropVector(clientTargetRagdoll, Prop_Send, "m_vecOrigin", ragPos);
    tDistance = GetVectorDistance(ragPos, vecPos);
    // PrintToServer("[PULL_RAG_DEBUG] Distance from ragdoll is %f",tDistance);

    if (tDistance > fReviveDistance) return Plugin_Continue;

    // create location based variables
    float origin[3];
    float angles[3];
    float radians[2];
    float destination[3];

    // get client position and the direction they are facing
    GetClientEyePosition(client, origin);    // Position of client's eyes.
    GetClientAbsAngles(client, angles);      // Direction client is looking.

    // convert degrees to radians
    radians[0]                 = DegToRad(angles[0]);
    radians[1]                 = DegToRad(angles[1]);

    // calculate entity destination after creation (raw number is an offset distance)
    destination[0]             = origin[0] + 32 * Cosine(radians[0]) * Cosine(radians[1]);
    destination[1]             = origin[1] + 32 * Cosine(radians[0]) * Sine(radians[1]);
    destination[2]             = ragPos[2];    // origin[2] - 35;// * Sine(radians[0]);

    g_playerCurrentRag[client] = EntIndexToEntRef(clientTargetRagdoll);

    if (destination[2] < vecPos[2])
        destination[2] = (destination[2] + (vecPos[2] - destination[2]));

    float _fForce[3];
    _fForce[0] = 1.0;
    _fForce[1] = 1.0;
    _fForce[2] = 1.0;
    // SetEntProp(clientTargetRagdoll, Prop_Data, "m_CollisionGroup", 17);
    TeleportEntity(clientTargetRagdoll, destination, NULL_VECTOR, _fForce);

    return Plugin_Continue;
}

stock bool CheckIfBodyIsStuck(ent)
{
    float flOrigin[3];
    float flMins[3];
    float flMaxs[3];
    GetEntPropVector(ent, Prop_Send, "m_vecOrigin", flOrigin);
    GetEntPropVector(ent, Prop_Send, "m_vecMins", flMins);
    GetEntPropVector(ent, Prop_Send, "m_vecMaxs", flMaxs);

    TR_TraceHullFilter(flOrigin, flOrigin, flMins, flMaxs, MASK_SOLID_BRUSHONLY, TraceEntityFilterSolid, ent);
    return TR_DidHit();
}

public bool TraceEntityFilterSolid(int entity, int contentsMask)
{
    return entity > 1;
}

stock float GetPropDistanceToGround(int prop)
{
    float fOrigin[3], fGround[3];
    GetEntPropVector(prop, Prop_Send, "m_vecOrigin", fOrigin);

    fOrigin[2] += 10.0;

    TR_TraceRayFilter(fOrigin, view_as<float>({ 90.0, 0.0, 0.0 }), MASK_SOLID, RayType_Infinite, TraceFilterNoPlayers, prop);
    if (!TR_DidHit()) return 0.0;

    TR_GetEndPosition(fGround);
    fOrigin[2] -= 10.0;
    return GetVectorDistance(fOrigin, fGround);
}

public bool TraceFilterNoPlayers(int iEnt, int iMask, any Other)
{
    return iEnt != Other && iEnt > MaxClients;
}
