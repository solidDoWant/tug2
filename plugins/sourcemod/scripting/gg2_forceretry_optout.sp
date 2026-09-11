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
// Whether the DB lookup for this client has RESOLVED - success or failure. Set either way: it used
// to be set only on success, so a failed lookup left it false for the rest of the session and
// !autoreconnect answered "Still loading your setting" forever. The stats database on test drops
// connections often enough that this was the normal case, not an edge one.
bool      g_bOptOutKnown[MAXPLAYERS + 1];
// Whether g_bOptOut actually came from the database, as opposed to being the default assumed after
// a failed lookup. Only used to warn the player that what they see may not be what is saved.
bool      g_bOptOutFromDb[MAXPLAYERS + 1];
// Retries left on the lookup, so a transient outage heals itself instead of stranding the player
// on a default for the whole session.
int       g_iOptOutRetries[MAXPLAYERS + 1];

// Set while a lookup is only meant to load the opt-out setting - a late load, where the players are
// already connected and must NOT be force-reconnected as a side effect of reloading the plugin.
bool      g_bSettingLookupOnly[MAXPLAYERS + 1];

#define OPT_OUT_MAX_RETRIES   3
#define OPT_OUT_RETRY_DELAY   5.0

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

    // Resolved, but from a failed lookup rather than the database. Say so: the value shown is the
    // default, not necessarily what this player saved previously.
    if (!g_bOptOutFromDb[client])
    {
        PrintToChat(client, "[Auto-reconnect] Note: your saved setting could not be loaded, showing the default.");
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

    g_bIsRetrying[client]    = false;
    g_bOptOut[client]        = false;
    g_bOptOutKnown[client]   = false;
    g_bOptOutFromDb[client]  = false;
    g_iOptOutRetries[client] = OPT_OUT_MAX_RETRIES;
    g_bSettingLookupOnly[client] = false;

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

        // ...and their opt-out still has to be loaded, exactly as in the branch above. Missing it
        // here is worse than it looks, because this is the branch a player lands in immediately
        // AFTER being force-reconnected:
        //   - g_bOptOutKnown stays false, so !autoreconnect answers "Still loading your setting"
        //     for the rest of the session, and
        //   - g_bOptOut stays false in memory, so every later force-retry check believes the player
        //     is opted in and can reconnect them again - even with auto_retry_opt_out TRUE in the
        //     database.
        //
        // Setting-only: the write above is the authoritative has_smoke update for this reconnect,
        // and re-running the retry decision against a read that may still say FALSE could bounce
        // the player a second time.
        g_bSettingLookupOnly[client] = true;
        db_check_player_state(client);
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
    g_bIsRetrying[client]    = false;
    g_bOptOutKnown[client]   = false;
    g_bOptOutFromDb[client]  = false;
    g_iOptOutRetries[client] = OPT_OUT_MAX_RETRIES;

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
                      // ::int on both. These are PostgreSQL BOOLEAN columns, and the pgsql driver
                      // hands FetchInt the value's TEXT form - "true"/"false" - which atoi parses
                      // as 0. Every read came back false regardless of what was stored, so
                      // has_smoke looked uncached on every join (hence the reconnect every time)
                      // and auto_retry_opt_out looked unset (hence the opt-out never applying).
                      // Casting in SQL is what makes FetchInt meaningful here.
                      "SELECT has_smoke::int, auto_retry_opt_out::int FROM players_smoke_cache WHERE steam_id = %s LIMIT 1", steamId);
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
    if (!IsValidPlayer(client)) return;

    if (results == null)
    {
        // The lookup failed. Resolve the setting to its default ANYWAY so !autoreconnect stays
        // usable - leaving it unresolved is what made the command answer "Still loading your
        // setting" for the rest of the session.
        //
        // Deliberately NOT touching playerList or forcing a reconnect: a failed lookup says nothing
        // about whether this player has the particles cached, and guessing "not cached" would
        // black-screen somebody every time the database hiccups.
        g_bOptOut[client]       = false;
        g_bOptOutKnown[client]  = true;
        g_bOptOutFromDb[client] = false;
        g_bSettingLookupOnly[client] = false;

        if (g_iOptOutRetries[client] > 0)
        {
            g_iOptOutRetries[client]--;
            CreateTimer(OPT_OUT_RETRY_DELAY, Timer_RetryStateCheck, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        }
        return;
    }

    bool hasSmoke = false;

    // No row means the player has never been seen, so they are opted in by default and have
    // nothing cached.
    if (results.RowCount > 0 && results.FetchRow())
    {
        hasSmoke          = view_as<bool>(results.FetchInt(0));
        g_bOptOut[client] = view_as<bool>(results.FetchInt(1));
    }
    g_bOptOutKnown[client]  = true;
    g_bOptOutFromDb[client] = true;

    // A late-load lookup wanted the setting and nothing else. Leaving playerList and the
    // force-retry decision alone is what stops a plugin reload reconnecting everyone in game.
    if (g_bSettingLookupOnly[client])
    {
        g_bSettingLookupOnly[client] = false;
        return;
    }

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

// Re-runs the lookup after a failure. If the database is still down, db_check_player_state logs and
// returns, and no further retry is scheduled - the player keeps the default, which is usable.
public Action Timer_RetryStateCheck(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidPlayer(client) || IsFakeClient(client)) return Plugin_Stop;
    if (g_bOptOutFromDb[client]) return Plugin_Stop;    // a write since then already settled it

    db_check_player_state(client);
    return Plugin_Stop;
}

// OnClientPostAdminCheck does not fire for players who are already connected, so a reload would
// leave every one of them with an unresolved setting - the exact symptom this plugin was just fixed
// for. Load the setting for them once the database is up.
//
// Only the SETTING: g_bSettingLookupOnly suppresses the has_smoke/force-retry half, because
// reloading a plugin must never black-screen everyone on the server.
void LoadSettingsForConnectedPlayers()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidPlayer(i) || IsFakeClient(i)) continue;
        if (g_bOptOutFromDb[i]) continue;

        g_iOptOutRetries[i]     = OPT_OUT_MAX_RETRIES;
        g_bSettingLookupOnly[i] = true;
        db_check_player_state(i);
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

    LoadSettingsForConnectedPlayers();
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
