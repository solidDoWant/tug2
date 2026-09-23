//(C) 2014 Jared Ballou <sourcemod@jballou.com>
// Released under GPLv3

#pragma semicolon 1

#include <sourcemod>
#undef REQUIRE_PLUGIN
#include <sdktools>
#include <morecolors>
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
ConVar g_cvAllowChoice;

// Per-player choice between hold and toggle (!dragmode), saved in player_drag_mode in the
// insurgency-stats database so it survives map changes and reconnects. PREF_DEFAULT means the player
// has never chosen - or the choice has not loaded yet - and they get sm_pullrag_toggle. Only a
// player who actually picks a mode gets a row, so changing the server default still moves everyone
// who never cared.
#define PREF_DEFAULT -1
#define PREF_HOLD    0
#define PREF_TOGGLE  1

int  g_iPref[MAXPLAYERS + 1] = { PREF_DEFAULT, ... };
// Chosen but not yet saved. A load must not overwrite it, and a reconnect writes it rather than
// re-reading - otherwise a database hiccup would silently flip the player back to their old mode.
bool g_bPrefDirty[MAXPLAYERS + 1];

Database g_hDb = null;
bool     g_bDbConnecting = false;
// Bumped on every successful connect. A query that fails with a connection error on an older handle
// is simply retried on the new one instead of starting yet another reconnect.
int      g_iDbGeneration = 0;

#define CHAT_PREFIX "{olivedrab}[Drag]{default} "

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
    // Off by default, so main keeps one server-wide mode and never touches the database. The test
    // server turns it on through cfg/sourcemod/d_dy_pull_rag.cfg.
    g_cvAllowChoice = CreateConVar("sm_pullrag_allow_choice", "0",
                                   "Let players pick hold or toggle dragging for themselves with !dragmode, saved in the insurgency-stats database. 0 = everyone uses sm_pullrag_toggle.",
                                   _, true, 0.0, true, 1.0);
    AutoExecConfig(true, "d_dy_pull_rag");

    // sm_ prefixed commands are reachable as both !name and /name.
    RegConsoleCmd("sm_dragmode", Cmd_DragMode, "Choose how the sprint key drags bodies. Usage: !dragmode [hold|toggle]");

    // 0 is not a null entity reference, and FindDragTarget reads every client's slot to see who has
    // already claimed a body. Start them all genuinely empty.
    for (int i = 1; i <= MAXPLAYERS; i++)
        ReleaseDrag(i);

    HookEvent("player_disconnect", Event_PlayerDisconnect_Post, EventHookMode_Post);
}

public void OnConfigsExecuted()
{
    if (!g_cvAllowChoice.BoolValue) return;

    // Connecting here rather than in OnPluginStart because the cvar is only known once the config
    // has run. Also picks up players who were already connected when the plugin was (re)loaded.
    if (g_hDb == null) ConnectDatabase();
    else LoadAllPrefs();
}

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client)) return;

    g_iPref[client]      = PREF_DEFAULT;
    g_bPrefDirty[client] = false;
    LoadPref(client);
}

public void OnClientDisconnect(int client)
{
    ReleaseDrag(client);
    g_LastButtons[client] = 0;
    g_iPref[client]       = PREF_DEFAULT;
    g_bPrefDirty[client]  = false;
}

// Which mode this player drags in right now.
bool UsesToggle(int client)
{
    if (g_cvAllowChoice.BoolValue && g_iPref[client] != PREF_DEFAULT)
        return g_iPref[client] == PREF_TOGGLE;

    return g_cvToggle.BoolValue;
}

public Action Cmd_DragMode(int client, int args)
{
    if (client < 1 || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Handled;

    bool current = UsesToggle(client);

    if (!g_cvAllowChoice.BoolValue)
    {
        CPrintToChat(client, CHAT_PREFIX ... "Body dragging is fixed to {green}%s{default} on this server.", current ? "toggle" : "hold");
        return Plugin_Handled;
    }

    bool wantToggle;
    if (args == 0)
    {
        // No argument: switch to the other one.
        wantToggle = !current;
    }
    else
    {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        if (StrEqual(arg, "toggle", false) || StrEqual(arg, "1", false))
            wantToggle = true;
        else if (StrEqual(arg, "hold", false) || StrEqual(arg, "0", false))
            wantToggle = false;
        else
        {
            CPrintToChat(client, CHAT_PREFIX ... "You're on {green}%s{default}. Type {green}!dragmode hold{default} or {green}!dragmode toggle{default}, or just {green}!dragmode{default} to switch.", current ? "toggle" : "hold");
            return Plugin_Handled;
        }
    }

    if (wantToggle == current)
    {
        CPrintToChat(client, CHAT_PREFIX ... "You're already on {green}%s{default}. Type {green}!dragmode{default} to switch to %s.", current ? "toggle" : "hold", current ? "hold" : "toggle");
        return Plugin_Handled;
    }

    // Applied straight away, before the save lands. Any body being held in the old mode is let go:
    // a hold-mode grab left behind in toggle mode would otherwise stay latched with no press to end it.
    ReleaseDrag(client);
    g_iPref[client]      = wantToggle ? PREF_TOGGLE : PREF_HOLD;
    g_bPrefDirty[client] = true;
    SavePref(client);

    // No "saved" confirmation - saving is expected. Only a failed save is reported (OnPrefSaved).
    if (wantToggle)
        CPrintToChat(client, CHAT_PREFIX ... "Switched to {green}toggle{default}: crouch, aim at a body and tap sprint to grab it. Tap again to let go.");
    else
        CPrintToChat(client, CHAT_PREFIX ... "Switched to {green}hold{default}: crouch, aim at a body and hold sprint to drag it. Let go to drop it.");

    return Plugin_Handled;
}

// ---------------------------------------------------------------------------------------------
// Database. The pooled connection to the stats database is dropped when idle, so every query
// treats a connection error as "reconnect and try again" rather than as a real failure.
// ---------------------------------------------------------------------------------------------

void ConnectDatabase()
{
    if (g_bDbConnecting) return;

    g_bDbConnecting = true;
    delete g_hDb;
    Database.Connect(OnDatabaseConnected, "insurgency-stats");
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    g_bDbConnecting = false;

    if (db == null)
    {
        LogError("[Pull Rag] Could not connect to insurgency-stats: %s - players get the server default until it is back", error);
        CreateTimer(30.0, Timer_RetryConnect, _, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    g_hDb = db;
    g_iDbGeneration++;
    LoadAllPrefs();
}

public Action Timer_RetryConnect(Handle timer)
{
    if (g_hDb == null && g_cvAllowChoice.BoolValue) ConnectDatabase();
    return Plugin_Stop;
}

bool IsConnectionError(const char[] error)
{
    static const char markers[][] = {
        "server closed the connection",
        "no connection to the server",
        "connection not open",
        "could not send data to server",
        "could not receive data from server",
        "terminating connection",
        "SSL SYSCALL error",
    };

    for (int i = 0; i < sizeof(markers); i++)
        if (StrContains(error, markers[i], false) != -1) return true;

    return false;
}

// A query failed with a connection error. If the handle it ran on has already been replaced, run it
// again on the new one; otherwise this is the first to notice, so reconnect - the connect callback
// re-runs everything that is outstanding.
bool RetryOnNewConnection(int generation)
{
    if (generation != g_iDbGeneration && g_hDb != null) return true;

    ConnectDatabase();
    return false;
}

// Everyone in game: write what is unsaved, read the rest.
void LoadAllPrefs()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !IsClientAuthorized(i)) continue;

        if (g_bPrefDirty[i]) SavePref(i);
        else LoadPref(i);
    }
}

void LoadPref(int client)
{
    if (!g_cvAllowChoice.BoolValue) return;
    if (g_hDb == null)
    {
        ConnectDatabase();    // the connect callback loads everyone
        return;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    char query[256];
    // ::int because the pgsql driver hands FetchInt a BOOLEAN's text form, which reads as 0.
    g_hDb.Format(query, sizeof(query), "SELECT toggle_drag::int FROM player_drag_mode WHERE steam_id = %s", steamId);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iDbGeneration);
    g_hDb.Query(OnPrefLoaded, query, pack);
}

public void OnPrefLoaded(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int client     = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    delete pack;

    if (client == 0) return;

    if (results == null)
    {
        if (IsConnectionError(error))
        {
            if (RetryOnNewConnection(generation)) LoadPref(client);
            return;
        }

        LogError("[Pull Rag] Could not load drag mode for %N: %s", client, error);
        return;
    }

    // Chosen while this was in flight - the choice wins over what was stored before it.
    if (g_bPrefDirty[client]) return;

    if (results.FetchRow())
        g_iPref[client] = results.FetchInt(0) ? PREF_TOGGLE : PREF_HOLD;
    else
        g_iPref[client] = PREF_DEFAULT;
}

void SavePref(int client)
{
    if (g_hDb == null)
    {
        ConnectDatabase();    // stays dirty; the connect callback writes it
        return;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    int  pref  = g_iPref[client];
    char value[8];
    strcopy(value, sizeof(value), pref == PREF_TOGGLE ? "TRUE" : "FALSE");

    char query[384];
    g_hDb.Format(query, sizeof(query),
                 "INSERT INTO player_drag_mode (steam_id, toggle_drag) VALUES (%s, %s) ON CONFLICT (steam_id) DO UPDATE SET toggle_drag = EXCLUDED.toggle_drag, updated_at = CURRENT_TIMESTAMP",
                 steamId, value);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_iDbGeneration);
    pack.WriteCell(pref);
    g_hDb.Query(OnPrefSaved, query, pack);
}

public void OnPrefSaved(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int client     = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    int pref       = pack.ReadCell();
    delete pack;

    if (client == 0) return;

    if (results == null)
    {
        if (IsConnectionError(error))
        {
            if (RetryOnNewConnection(generation)) SavePref(client);
            return;
        }

        LogError("[Pull Rag] Could not save drag mode for %N: %s", client, error);
        CPrintToChat(client, CHAT_PREFIX ... "Couldn't save that, so it only lasts until the map changes.");
        g_bPrefDirty[client] = false;
        return;
    }

    // Only clean if nothing newer was chosen while this write was in flight.
    if (g_iPref[client] == pref) g_bPrefDirty[client] = false;
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

    if (UsesToggle(client))
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

// Original hold-to-drag path, for players in hold mode.
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
