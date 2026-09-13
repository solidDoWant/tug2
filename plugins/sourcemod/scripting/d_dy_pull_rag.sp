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

int  g_LastButtons[MAXPLAYERS + 1];
int  g_playerCurrentRag[MAXPLAYERS + 1];

// Toggle mode only. The latch is what replaces "is sprint held right now".
bool g_bDragging[MAXPLAYERS + 1];

ConVar g_cvToggle;

// Acquisition range, unchanged from the original hold behaviour.
#define DRAG_ACQUIRE_RANGE 80.0
// A latched drag gives up past this. The body is repositioned in front of the player every tick, so
// it only drifts while the drag is paused (crouch released, shooting) - and without a break range a
// player could walk off, re-crouch, and have the body snap across the room to them.
#define DRAG_BREAK_RANGE   300.0

public Plugin myinfo =
{
    name        = "[INS] Pull Rag",
    author      = "Daimyo",
    description = PLUGIN_DESCRIPTION,
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    // Off by default so main keeps the original hold-to-drag. The test server turns it on through
    // cfg/sourcemod/d_dy_pull_rag.cfg.
    g_cvToggle = CreateConVar("sm_pullrag_toggle", "0",
                              "Sprint key behaviour for dragging bodies. 0 = hold to drag (default), 1 = press once to grab and again to let go.",
                              _, true, 0.0, true, 1.0);
    AutoExecConfig(true, "d_dy_pull_rag");

    // 0 is not a null entity reference, and FindDragTarget reads every client's slot to see who has
    // already claimed a body. Start them all genuinely empty.
    for (int i = 1; i <= MAXPLAYERS; i++)
        ReleaseDrag(i);

    HookEvent("player_disconnect", Event_PlayerDisconnect_Post, EventHookMode_Post);
}

public void OnClientDisconnect(int client)
{
    ReleaseDrag(client);
    g_LastButtons[client] = 0;
}

public Action Event_PlayerDisconnect_Post(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client < 1) return Plugin_Continue;
    ReleaseDrag(client);
    g_LastButtons[client] = 0;
    return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (IsFakeClient(client)) return Plugin_Continue;

    if (g_cvToggle.BoolValue)
    {
        // Rising edge only. OnPlayerRunCmd runs every tick, so reacting to the bit being set would
        // flip the latch ~66 times a second and the drag would never appear to start.
        if ((buttons & IN_SPRINT) && !(g_LastButtons[client] & IN_SPRINT))
        {
            if (g_bDragging[client]) ReleaseDrag(client);
            else
            {
                int target = FindDragTarget(client);
                if (target != -1)
                {
                    g_bDragging[client]        = true;
                    g_playerCurrentRag[client] = EntIndexToEntRef(target);
                }
            }
        }

        if (g_bDragging[client]) DragTick(client, buttons);
    }
    else
    {
        for (int i = 0; i < MAX_BUTTONS; i++)
        {
            int button = (1 << i);
            if ((buttons & button))
                OnButtonPress(client, button, buttons);
        }
    }

    g_LastButtons[client] = buttons;
    return Plugin_Continue;
}

// The posture the drag needs. Identical to the original hold-mode test, minus the sprint bit: still
// crouched, not walking into the body, not shooting.
bool DragGatesOpen(int buttons)
{
    return (buttons & IN_DUCK) && !(buttons & IN_FORWARD) && !(buttons & IN_ATTACK2) && !(buttons & IN_ATTACK);
}

// Runs every tick for a latched drag. Failing a gate only PAUSES the drag - stand up or fire and the
// body stops following, crouch again and it resumes - because releasing the latch on a stray click
// would make the toggle feel broken. Only a genuine loss of the body ends it.
void DragTick(int client, int buttons)
{
    int ragdoll = EntRefToEntIndex(g_playerCurrentRag[client]);
    if (ragdoll == -1 || ragdoll == INVALID_ENT_REFERENCE || !IsValidEntity(ragdoll))
    {
        ReleaseDrag(client);
        return;
    }

    if (!IsPlayerAlive(client))
    {
        ReleaseDrag(client);
        return;
    }

    float vecPos[3], ragPos[3];
    GetClientAbsOrigin(client, vecPos);
    GetEntPropVector(ragdoll, Prop_Send, "m_vecOrigin", ragPos);
    if (GetVectorDistance(ragPos, vecPos) > DRAG_BREAK_RANGE)
    {
        ReleaseDrag(client);
        return;
    }

    if (!DragGatesOpen(buttons)) return;

    MoveRagdoll(client, ragdoll, ragPos);
}

void ReleaseDrag(int client)
{
    g_bDragging[client]        = false;
    g_playerCurrentRag[client] = INVALID_ENT_REFERENCE;
}

// Everything the original did to decide whether a body may be picked up: it has to be the thing the
// player is looking at, a prop_ragdoll, within arm's reach, and not already claimed by somebody else.
int FindDragTarget(int client)
{
    int clientTargetRagdoll = GetClientAimTarget(client, false);
    if (clientTargetRagdoll == -1) return -1;

    char entClassname[128];
    GetEntityClassname(clientTargetRagdoll, entClassname, sizeof(entClassname));
    if (!IsValidEdict(clientTargetRagdoll) || !IsValidEntity(clientTargetRagdoll)
        || !StrEqual(entClassname, "prop_ragdoll", false)) return -1;

    // Verify other players are not dragging body
    for (int tclient = 1; tclient <= MaxClients; tclient++)
    {
        if (client == tclient || tclient < 0 || !IsClientInGame(tclient) || IsFakeClient(tclient)) continue;
        int verifyRagdoll = EntRefToEntIndex(g_playerCurrentRag[tclient]);
        if (verifyRagdoll == -1 || verifyRagdoll == INVALID_ENT_REFERENCE) continue;
        if (verifyRagdoll != EntRefToEntIndex(clientTargetRagdoll)) continue;

        return -1;
    }

    float vecPos[3], ragPos[3];
    GetClientAbsOrigin(client, vecPos);
    GetEntPropVector(clientTargetRagdoll, Prop_Send, "m_vecOrigin", ragPos);
    if (GetVectorDistance(ragPos, vecPos) > DRAG_ACQUIRE_RANGE) return -1;

    return clientTargetRagdoll;
}

// The original placement maths, lifted verbatim so hold and toggle drag identically.
void MoveRagdoll(int client, int clientTargetRagdoll, const float ragPos[3])
{
    float vecPos[3];
    GetClientAbsOrigin(client, vecPos);

    // create location based variables
    float origin[3];
    float angles[3];
    float radians[2];
    float destination[3];

    // get client position and the direction they are facing
    GetClientEyePosition(client, origin);    // Position of client's eyes.
    GetClientAbsAngles(client, angles);      // Direction client is looking.

    // convert degrees to radians
    radians[0]     = DegToRad(angles[0]);
    radians[1]     = DegToRad(angles[1]);

    // calculate entity destination after creation (raw number is an offset distance)
    destination[0] = origin[0] + 32 * Cosine(radians[0]) * Cosine(radians[1]);
    destination[1] = origin[1] + 32 * Cosine(radians[0]) * Sine(radians[1]);
    destination[2] = ragPos[2];    // origin[2] - 35;// * Sine(radians[0]);

    if (destination[2] < vecPos[2])
        destination[2] = (destination[2] + (vecPos[2] - destination[2]));

    float _fForce[3];
    _fForce[0] = 1.0;
    _fForce[1] = 1.0;
    _fForce[2] = 1.0;
    // SetEntProp(clientTargetRagdoll, Prop_Data, "m_CollisionGroup", 17);
    TeleportEntity(clientTargetRagdoll, destination, NULL_VECTOR, _fForce);
}

// Original hold-to-drag path, kept for sm_pullrag_toggle 0 (main).
Action OnButtonPress(int client, int button, int buttons)
{
    if (button != IN_SPRINT || !DragGatesOpen(buttons)) return Plugin_Continue;

    int clientTargetRagdoll = FindDragTarget(client);
    if (clientTargetRagdoll == -1) return Plugin_Continue;

    float ragPos[3];
    GetEntPropVector(clientTargetRagdoll, Prop_Send, "m_vecOrigin", ragPos);

    g_playerCurrentRag[client] = EntIndexToEntRef(clientTargetRagdoll);
    MoveRagdoll(client, clientTargetRagdoll, ragPos);

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
