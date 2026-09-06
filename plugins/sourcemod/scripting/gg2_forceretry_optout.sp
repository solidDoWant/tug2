#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

// TEST SERVER ONLY. This is gg2_forceretry with a player-facing opt-out, and it REPLACES that
// plugin rather than running alongside it - two copies would both try to force a reconnect.
//
// Background: the server force-reconnects a player the first time it sees them, so the client
// downloads and caches the custom smoke particles and their sounds. Without that the effects are
// missing or silent for that player. The reconnect is a few seconds of black screen and is
// startling if you do not know why it happened, hence the opt-out.
//
// Opting out is stored per SteamID in players_smoke_cache.auto_retry_opt_out, so it survives
// reconnects and map changes. A player who opts out keeps whatever cache state they already had;
// if they had never cached the particles, smoke will look wrong for them until they opt back in.

Database  g_Database = null;
// Any player in this list will have reconnected at least one point in the past so they should have smoke particles cached
StringMap playerList;
ConVar    gg2_always_retry;
bool      g_bIsRetrying[MAXPLAYERS + 1];
// Mirrors auto_retry_opt_out for connected players so the retry decision needs no extra query.
bool      g_bOptOut[MAXPLAYERS + 1];
// Whether the DB lookup for this client has come back yet; guards against acting on a stale value.
bool      g_bOptOutKnown[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "[GG2 ForceRetry] Force Retry (opt-out)",
    author      = "Bot Chris // zachm",
    description = "Precaches smoke/etc for players who lack the particles, with !autoreconnect opt-out. Includes !resetsmoke.",
    version     = "1.2.0",
    url         = ""
};

public void OnPluginStart()
{
    Database.Connect(OnDatabaseConnected, "insurgency-stats");

    playerList = new StringMap();

    HookEvent("player_disconnect", Event_PlayerDisconnect_Pre, EventHookMode_Pre);

    gg2_always_retry = CreateConVar("gg2_always_retry", "0", "should we always force reconnect");

    // sm_ prefixed commands are reachable as both !name and /name.
    RegConsoleCmd("sm_autoreconnect", Cmd_AutoReconnect, "Turn the automatic reconnect on or off for yourself. Usage: !autoreconnect [on|off]");
    RegConsoleCmd("sm_resetsmoke", Cmd_ResetSmoke, "Forget that you have the smoke particles cached, so the next connect re-caches them");

    AutoExecConfig(true, "gg2_forceretry_optout");
}

// Kept because !resetsmoke was a bare say-command in the previous version and players have the
// habit. sm_resetsmoke above is the real registration.
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (!StrEqual(sArgs, "!resetsmoke", false)) return Plugin_Continue;

    ResetSmokeStatus(client);
    return Plugin_Handled;
}

public Action Cmd_ResetSmoke(int client, int args)
{
    ResetSmokeStatus(client);
    return Plugin_Handled;
}

public Action Cmd_AutoReconnect(int client, int args)
{
    if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Handled;

    if (!g_bOptOutKnown[client])
    {
        PrintToChat(client, "[Auto-reconnect] Still loading your setting, try again in a moment.");
        return Plugin_Handled;
    }

    bool wantOptOut;
    if (args == 0)
    {
        // No argument: toggle.
        wantOptOut = !g_bOptOut[client];
    }
    else
    {
        char arg[8];
        GetCmdArg(1, arg, sizeof(arg));
        if (StrEqual(arg, "on", false) || StrEqual(arg, "1", false) || StrEqual(arg, "yes", false))
        {
            wantOptOut = false;
        }
        else if (StrEqual(arg, "off", false) || StrEqual(arg, "0", false) || StrEqual(arg, "no", false))
        {
            wantOptOut = true;
        }
        else
        {
            PrintToChat(client, "[Auto-reconnect] Usage: !autoreconnect [on|off]");
            return Plugin_Handled;
        }
    }

    if (wantOptOut == g_bOptOut[client])
    {
        PrintToChat(client, "[Auto-reconnect] Already %s for you.", wantOptOut ? "OFF" : "ON");
        return Plugin_Handled;
    }

    db_set_player_opt_out(client, wantOptOut);
    return Plugin_Handled;
}

void ResetSmokeStatus(int client)
{
    if (!IsValidPlayer(client)) return;
    if (IsFakeClient(client)) return;

    db_reset_player_has_smoke(client);
}

public void OnMapStart()
{
    if (playerList == null) return;

    playerList.Clear();
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidPlayer(client) || IsFakeClient(client)) return;

    g_bIsRetrying[client]   = false;
    g_bOptOut[client]       = false;
    g_bOptOutKnown[client]  = false;

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    bool hasSmoke;
    if (playerList.GetValue(steamId, hasSmoke))
    {
        if (hasSmoke)
        {
            // Already known-good this map, but the opt-out flag still has to be loaded so
            // !autoreconnect can report and change it.
            db_check_player_state(client);
            return;
        }

        // In this case, the player must have reconnected (otherwise, they wouldn't be in the map).
        // This means they now have smoke particles cached.
        db_update_player_has_smoke(client);
        return;
    }

    playerList.SetValue(steamId, false, true);
    db_check_player_state(client);
}

public Action Timer_ForceRetry(Handle timer, int client)
{
    if (!IsValidPlayer(client)) return Plugin_Continue;

    // Re-checked here as well as at the call site: the opt-out may have been answered by the
    // database in between scheduling this timer and it firing.
    if (g_bOptOut[client]) return Plugin_Continue;

    LogMessage("[INS GG] Force retry for %N", client);
    g_bIsRetrying[client] = true;
    ClientCommand(client, "retry");
    return Plugin_Continue;
}

public Action Event_PlayerDisconnect_Pre(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Continue;

    // Store retry state before resetting
    bool wasRetrying       = g_bIsRetrying[client];
    g_bIsRetrying[client]  = false;
    g_bOptOutKnown[client] = false;

    // If player was being forced to retry, keep them in playerList
    if (wasRetrying) return Plugin_Continue;

    // Normal disconnect - remove from tracking
    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return Plugin_Continue;

    playerList.Remove(steamId);

    return Plugin_Continue;
}

public void OnPluginEnd()
{
    if (playerList != null) delete playerList;
}

bool IsValidPlayer(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

// Helper function to handle database query errors
void HandleQueryError(DBResultSet results, const char[] error, const char[] operationName)
{
    if (results != null) return;

    // Check if the error is due to lost connection
    if (StrContains(error, "no connection to the server", false) != -1)
    {
        LogError("[INS GG ForceRetry] Lost connection to database: %s - attempting to reconnect", error);
        ReconnectDatabase();
        return;
    }

    LogError("[INS GG ForceRetry] Failed to %s: %s", operationName, error);
}

// actions to track whether player has smoke particles downloaded, reconnect them if they don't //
public void db_check_player_state(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return;

    if (g_Database == null)
    {
        LogError("[INS GG ForceRetry] Database unavailable for checking player smoke cache");
        return;
    }

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        LogError("[INS GG ForceRetry] Failed to get SteamID for %N", client);
        return;
    }

    char query[512];
    g_Database.Format(query, sizeof(query),
                      "SELECT has_smoke, auto_retry_opt_out FROM players_smoke_cache WHERE steam_id = %s LIMIT 1", steamId);
    g_Database.Query(OnPlayerStateChecked, query, GetClientUserId(client));
}

public void db_update_player_has_smoke(int client)
{
    ExecutePlayerSmokeQuery(OnPlayerSmokeCacheUpdated, "update player smoke cache", client, true);
}

public void db_reset_player_has_smoke(int client)
{
    ExecutePlayerSmokeQuery(OnPlayerSmokeCacheReset, "reset player smoke cache", client, false);
}

public void ExecutePlayerSmokeQuery(SQLQueryCallback callback, const char[] operationName, int client, bool hasSmoke)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return;

    if (g_Database == null)
    {
        LogError("[INS GG ForceRetry] Database unavailable for %s", operationName);
        return;
    }

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        LogError("[INS GG ForceRetry] Failed to get SteamID for %N", client);
        return;
    }

    char hasSmokeQueryValue[6];
    if (hasSmoke)
    {
        strcopy(hasSmokeQueryValue, sizeof(hasSmokeQueryValue), "TRUE");
    }
    else
    {
        strcopy(hasSmokeQueryValue, sizeof(hasSmokeQueryValue), "FALSE");
    }

    char query[512];
    g_Database.Format(query, sizeof(query),
                      "INSERT INTO players_smoke_cache (steam_id, has_smoke) VALUES (%s, %s) ON CONFLICT (steam_id) DO UPDATE SET has_smoke = %s, updated_at = CURRENT_TIMESTAMP",
                      steamId, hasSmokeQueryValue, hasSmokeQueryValue);
    g_Database.Query(callback, query, GetClientUserId(client));
}

// Writes the opt-out flag. Deliberately does NOT touch has_smoke, so toggling the setting never
// costs a player their cached state.
public void db_set_player_opt_out(int client, bool optOut)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return;

    if (g_Database == null)
    {
        PrintToChat(client, "[Auto-reconnect] Setting unavailable right now, try again shortly.");
        LogError("[INS GG ForceRetry] Database unavailable for set player opt out");
        return;
    }

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        LogError("[INS GG ForceRetry] Failed to get SteamID for %N", client);
        return;
    }

    char value[6];
    strcopy(value, sizeof(value), optOut ? "TRUE" : "FALSE");

    char query[512];
    g_Database.Format(query, sizeof(query),
                      "INSERT INTO players_smoke_cache (steam_id, has_smoke, auto_retry_opt_out) VALUES (%s, FALSE, %s) ON CONFLICT (steam_id) DO UPDATE SET auto_retry_opt_out = %s, updated_at = CURRENT_TIMESTAMP",
                      steamId, value, value);
    // The desired value rides along so the callback can update local state without re-reading.
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(optOut);
    g_Database.Query(OnPlayerOptOutSet, query, pack);
}

public void OnPlayerOptOutSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int  client = GetClientOfUserId(pack.ReadCell());
    bool optOut = view_as<bool>(pack.ReadCell());
    delete pack;

    HandleQueryError(results, error, "set player auto retry opt out");
    if (!IsValidPlayer(client)) return;

    if (results == null)
    {
        PrintToChat(client, "[Auto-reconnect] Could not save that, please try again.");
        return;
    }

    g_bOptOut[client]      = optOut;
    g_bOptOutKnown[client] = true;

    if (optOut)
    {
        PrintToChat(client, "[Auto-reconnect] OFF. You will not be reconnected automatically.");
        PrintToChat(client, "[Auto-reconnect] If smoke looks wrong or is silent, use !autoreconnect on.");
        return;
    }

    PrintToChat(client, "[Auto-reconnect] ON. You may be reconnected once to cache the smoke effects.");

    // If they have never cached the particles, opting back in should fix them now rather than
    // waiting for their next connect.
    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    bool hasSmoke;
    if (playerList.GetValue(steamId, hasSmoke) && !hasSmoke)
    {
        PrintToChat(client, "[Auto-reconnect] Reconnecting you now...");
        CreateTimer(1.5, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnPlayerSmokeCacheUpdated(Database db, DBResultSet results, const char[] error, any userid)
{
    HandleQueryError(results, error, "update player smoke cache");
    if (results == null) return;

    int client = GetClientOfUserId(userid);
    if (!IsValidPlayer(client)) return;

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    playerList.SetValue(steamId, true, true);
}

public void OnPlayerSmokeCacheReset(Database db, DBResultSet results, const char[] error, any userid)
{
    HandleQueryError(results, error, "reset player smoke cache");
    if (results == null) return;

    int client = GetClientOfUserId(userid);
    if (!IsValidPlayer(client)) return;

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) return;

    playerList.SetValue(steamId, false, true);

    PrintToChat(client, "Smoke status reset, reconnect to the server to force cache");
}

public void OnPlayerStateChecked(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);

    HandleQueryError(results, error, "check player smoke cache");
    if (results == null) return;
    if (!IsValidPlayer(client)) return;

    bool hasSmoke = false;

    // No row means the player has never been seen, so they are opted in by default and have
    // nothing cached.
    if (results.RowCount > 0 && results.FetchRow())
    {
        hasSmoke          = view_as<bool>(results.FetchInt(0));
        g_bOptOut[client] = view_as<bool>(results.FetchInt(1));
    }
    g_bOptOutKnown[client] = true;

    char steamId[32];
    if (GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        playerList.SetValue(steamId, hasSmoke, true);
    }

    if (g_bOptOut[client])
    {
        // Opting out wins over gg2_always_retry as well - otherwise the setting would silently
        // stop working whenever an admin turned that ConVar on.
        if (!hasSmoke)
        {
            PrintToChat(client, "[Auto-reconnect] Smoke effects are not cached for you and auto-reconnect is OFF.");
            PrintToChat(client, "[Auto-reconnect] Use !autoreconnect on to fix smoke, or !autoreconnect to toggle.");
        }
        return;
    }

    if (gg2_always_retry.IntValue == 1 || !hasSmoke)
    {
        CreateTimer(0.2, Timer_ForceRetry, client, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[INS GG ForceRetry] Failed to connect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("[INS GG ForceRetry] Connected to database");
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    LogMessage("[INS GG ForceRetry] Attempting to reconnect to database...");
    delete g_Database;
    Database.Connect(OnDatabaseReconnected, "insurgency-stats");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[INS GG ForceRetry] Failed to reconnect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("[INS GG ForceRetry] Successfully reconnected to database");
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database != null) return Plugin_Stop;

    ReconnectDatabase();

    return Plugin_Stop;
}
