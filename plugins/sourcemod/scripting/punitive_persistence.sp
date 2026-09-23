#include <sourcemod>
#include <adminmenu>
#include <steamids>

// Optional: without basecomm this plugin still persists and enforces bans; only gag/mute
// persistence is lost.
#undef REQUIRE_PLUGIN
#include <basecomm>
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION    "1.0.0"
// Byte buffer for a reason. The column is varchar(255) - characters, not bytes - and basebans
// passes up to 255 bytes, so a 255-byte buffer (254 usable) could cut the last character in half,
// and Postgres rejects the whole INSERT on an invalid UTF-8 sequence.
#define MAX_REASON_BYTES  512

// Database handle
Database g_Database = null;

// Writes that could not be sent because the connection was down, replayed once it is back. See
// RunWrite. Bounded so a database that never comes back cannot grow this without limit.
#define MAX_QUERY_LENGTH      2048
#define MAX_PENDING_WRITES    64
ArrayList g_PendingWrites     = null;
bool      g_bReconnecting     = false;

// Gag/mute bookkeeping - see "COMMUNICATION RESTRICTIONS" below.
bool g_bApplyingFromDb = false;              // true while re-applying stored state, so the
                                             // basecomm forwards it triggers are not re-stored
int  g_iCommIssuer     = -1;                 // client running a comm command right now (0 = console)
bool g_bPendingGag[MAXPLAYERS + 1];          // stored state waiting for the client to be in game
bool g_bPendingMute[MAXPLAYERS + 1];

// Plugin info
public Plugin myinfo =
{
    name        = "Persistent Punishments",
    author      = "sdw",
    description = "Persistent ban and communication punishment system with PostgreSQL",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

public void OnPluginStart()
{
    // Create plugin version cvar
    CreateConVar("sm_punishments_version", PLUGIN_VERSION, "Persistent Punishments version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    // Ban commands (sm_ban, sm_addban, sm_banip, sm_unban) are deliberately NOT registered here.
    // basebans owns them, and every ban and unban it issues reaches the database through the
    // OnBanClient/OnBanIdentity/OnRemoveBan forwards below. This plugin used to register its own
    // sm_addban/sm_banip/sm_unban as well; SourceMod ran BOTH handlers for each, with opposite
    // argument formats (SteamID64 + "8h" here, STEAM_X + bare minutes in basebans), so one of the
    // two always rejected the command and the other half-applied it. Seen on main 2026-09-23:
    // "sm_addban 8h STEAM_1:..." cut an 8-hour engine ban to 8 minutes and wrote nothing here.

    g_PendingWrites = new ArrayList(ByteCountToCells(MAX_QUERY_LENGTH));

    // Same for the comm commands: basecomm owns sm_gag/sm_mute/sm_silence and their un- forms, and
    // changes reach the database through its BaseComm_OnClientGag/OnClientMute forwards. This plugin
    // used to register all six too. basecomm (loaded first) applied the gag, then this plugin's
    // BaseComm_SetClientGag call returned false because the player was already gagged, so it
    // replied "Failed to apply punishment" and never wrote the row - gags and mutes were never
    // persisted. The listeners below only note who issued the command, for admin_steam_id.
    static const char commCommands[][] = { "sm_gag", "sm_mute", "sm_silence", "sm_ungag", "sm_unmute", "sm_unsilence" };
    for (int i = 0; i < sizeof(commCommands); i++)
        AddCommandListener(Listener_CommCommand, commCommands[i]);

    // Connect to database
    Database.Connect(OnDatabaseConnected, "punitive-persistence");
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Failed to connect to database: %s", error);
        SetFailState("Database connection failed");
        return;
    }

    g_Database = db;
    LogMessage("Successfully connected to database");
    FlushPendingWrites();
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    // Several failing queries can arrive together; one reconnect is enough, and a second would
    // leak whichever handle lost the race.
    if (g_bReconnecting) return;
    g_bReconnecting = true;

    LogMessage("Attempting to reconnect to database...");
    delete g_Database;
    Database.Connect(OnDatabaseReconnected, "punitive-persistence");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Failed to reconnect to database: %s", error);
        // Try again after a delay
        g_bReconnecting = false;
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database      = db;
    g_bReconnecting = false;
    LogMessage("Successfully reconnected to database");
    FlushPendingWrites();
}

public Action Timer_RetryReconnect(Handle timer)
{
    if (g_Database == null)
        ReconnectDatabase();
    return Plugin_Stop;
}

public Action Timer_RetryPunishmentCheck(Handle timer, DataPack pack)
{
    // Check if database is back online
    if (g_Database == null)
    {
        LogMessage("Database still offline, retrying punishment check in 2 seconds...");
        CreateTimer(2.0, Timer_RetryPunishmentCheck, pack, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    // Extract data from pack
    pack.Reset();
    int  userid = pack.ReadCell();

    char steamid[32], ip[64];
    pack.ReadString(steamid, sizeof(steamid));
    pack.ReadString(ip, sizeof(ip));

    int client = GetClientOfUserId(userid);
    if (client == 0)
    {
        // Player disconnected, no need to check
        delete pack;
        return Plugin_Stop;
    }

    // Retry the punishment check
    LogMessage("Retrying punishment check for %s after database reconnection", steamid);
    CheckActivePunishments(client, steamid, ip);

    delete pack;
    return Plugin_Stop;
}

// ============================================================
// CLIENT CONNECTION - Reapply Active Punishments
// ============================================================
public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client)) return;

    // Get client IP
    char ip[64];
    GetClientIP(client, ip, sizeof(ip));

    // Get Steam ID 64 format
    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64)))
    {
        LogError("Failed to get SteamID64 for client %d", client);
        return;
    }

    // Mid-reconnect there is no handle. Returning here used to let a banned player straight in;
    // instead wait for the connection and check then, the same way a failed check is retried.
    if (g_Database == null)
    {
        DataPack pack = new DataPack();
        pack.WriteCell(GetClientUserId(client));
        pack.WriteString(steamid64);
        pack.WriteString(ip);
        CreateTimer(2.0, Timer_RetryPunishmentCheck, pack, TIMER_FLAG_NO_MAPCHANGE);
        ReconnectDatabase();
        return;
    }

    // Check for active punishments
    CheckActivePunishments(client, steamid64, ip);
}

void CheckActivePunishments(int client, const char[] steamid, const char[] ip)
{
    char query[512];
    g_Database.Format(query, sizeof(query),
                      "SELECT punishment_type, expires_at FROM punishments WHERE is_active = TRUE AND (target_steam_id = %s OR target_ip = '%s') AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)",
                      steamid, ip);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamid);
    pack.WriteString(ip);

    g_Database.Query(OnActivePunishmentsChecked, query, pack);
}

public void OnActivePunishmentsChecked(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int  userid = pack.ReadCell();

    char steamid[32], ip[64];
    pack.ReadString(steamid, sizeof(steamid));
    pack.ReadString(ip, sizeof(ip));

    if (results == null)
    {
        // Check if the error is due to lost connection
        if (IsConnectionError(error))
        {
            LogError("Lost connection to database: %s - attempting to reconnect", error);

            // Don't delete the pack yet, we'll retry after reconnection
            CreateTimer(1.0, Timer_RetryPunishmentCheck, pack, TIMER_FLAG_NO_MAPCHANGE);

            // Trigger reconnection
            ReconnectDatabase();
            return;
        }

        LogError("Failed to check active punishments: %s", error);
        delete pack;
        return;
    }

    int client = GetClientOfUserId(userid);
    if (client == 0)
    {
        delete pack;
        return;
    }

    // Apply all active punishments
    bool gagged = false;
    bool muted  = false;

    while (results.FetchRow())
    {
        char punishmentType[32];
        results.FetchString(0, punishmentType, sizeof(punishmentType));

        if (StrEqual(punishmentType, "ban_steamid") || StrEqual(punishmentType, "ban_ip"))
        {
            // Get expiration time if exists
            char expiresAt[64];
            if (!results.IsFieldNull(1))
                results.FetchString(1, expiresAt, sizeof(expiresAt));

            // Kick the player
            KickClient(client, "You are banned from this server");
        }
        else if (StrEqual(punishmentType, "gag"))
        {
            gagged = true;
        }
        else if (StrEqual(punishmentType, "mute"))
        {
            muted = true;
        }
        else if (StrEqual(punishmentType, "silence"))
        {
            // Legacy rows from before gag and mute were stored separately.
            gagged = true;
            muted  = true;
        }
    }

    if (gagged || muted)
        ApplyStoredComm(client, gagged, muted);

    // Log reapplied punishments
    if (gagged || muted)
    {
        if (gagged && muted)
            LogMessage("Reapplied silence to %N (%s)", client, steamid);
        else if (gagged)
            LogMessage("Reapplied gag to %N (%s)", client, steamid);
        else if (muted)
            LogMessage("Reapplied mute to %N (%s)", client, steamid);
    }

    delete pack;
}

// ============================================================
// BANS FROM OTHER PLUGINS - basebans' !ban / sm_ban / sm_addban / sm_banip, and anything that
// calls BanClient() or BanIdentity() with a command string (e.g. gg2_teamkill's auto-bans, which
// go through sm_ban).
// ============================================================
//
// WHY THIS EXISTS. The engine keeps timed bans in memory only - basebans never writes them to
// banned_user.cfg - so before this, every !ban was lost on the next restart or redeploy and only
// this plugin's own sm_addban/sm_banip ever reached the database. Found on main on 2026-09-23: an
// 8-hour !ban was live in `listid` but the punishments table had nothing newer than 2025-12-27.
//
// These forwards fire before core applies the ban. They return Plugin_Continue so the engine ban
// still happens as normal - it takes effect immediately and handles the kick - and the database
// row is what makes it survive a restart (OnClientAuthorized re-kicks from it).
//
// No double-insert with this plugin's own commands: those kick and insert directly and never call
// BanClient/BanIdentity, so they never reach these forwards.

public Action OnBanClient(int client, int time, int flags, const char[] rawReason, const char[] kick_message, const char[] command, any source)
{
    if (IsFakeClient(client)) return Plugin_Continue;

    int admin = ResolveBanSource(source);

    char reason[MAX_REASON_BYTES];
    CleanBanReason(rawReason, reason, sizeof(reason));

    if (flags & BANFLAG_IP)
    {
        char ip[64], steamid64[32];
        GetClientIP(client, ip, sizeof(ip));
        if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64)))
            steamid64[0] = '\0';
        AddBanToDatabase(admin, steamid64, ip, reason, time * 60, "ban_ip");
        return Plugin_Continue;
    }

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64)))
    {
        LogError("Not persisting %s ban of %N: no SteamID available", command, client);
        return Plugin_Continue;
    }

    AddBanToDatabase(admin, steamid64, "", reason, time * 60, "ban_steamid");
    return Plugin_Continue;
}

public Action OnBanIdentity(const char[] identity, int time, int flags, const char[] rawReason, const char[] command, any source)
{
    int admin = ResolveBanSource(source);

    char reason[MAX_REASON_BYTES];
    CleanBanReason(rawReason, reason, sizeof(reason));

    if (flags & BANFLAG_IP)
    {
        AddBanToDatabase(admin, "", identity, reason, time * 60, "ban_ip");
        return Plugin_Continue;
    }

    char steamid64[32];
    if (!SteamIdTo64(identity, steamid64, sizeof(steamid64)))
    {
        LogError("Not persisting %s ban of \"%s\": unrecognised SteamID format", command, identity);
        return Plugin_Continue;
    }

    AddBanToDatabase(admin, steamid64, "", reason, time * 60, "ban_steamid");
    return Plugin_Continue;
}

// basebans' sm_unban. Without this, a ban persisted above would outlive an unban issued through
// basebans: the engine would forget it, but the next connect would find the active row and kick.
public Action OnRemoveBan(const char[] identity, int flags, const char[] command, any source)
{
    if (flags & BANFLAG_IP)
    {
        RemoveBanFromDatabase(identity, true);
        return Plugin_Continue;
    }

    char steamid64[32];
    if (SteamIdTo64(identity, steamid64, sizeof(steamid64)))
        RemoveBanFromDatabase(steamid64, false);

    return Plugin_Continue;
}

// basebans passes the reason exactly as typed after the ban length, so a quoted reason arrives
// WITH its quotes - `!ban name 60 "tk"` gives "\"tk\"". Strip one surrounding pair so the stored
// reason is the text itself.
void CleanBanReason(const char[] raw, char[] reason, int maxlen)
{
    strcopy(reason, maxlen, raw);
    TrimString(reason);
    StripQuotes(reason);
    TrimString(reason);
}

// `source` is whatever the caller passed to BanClient/BanIdentity. basebans passes the issuing
// admin's client index (0 for the server console); other plugins may pass anything, so only a
// real in-game human is treated as an admin - everything else is recorded as the console.
int ResolveBanSource(any source)
{
    int admin = view_as<int>(source);
    if (admin < 1 || admin > MaxClients || !IsClientInGame(admin) || IsFakeClient(admin))
        return 0;
    return admin;
}

// ============================================================
// COMMUNICATION RESTRICTIONS - basecomm's sm_gag / sm_mute / sm_silence and un- forms, the admin
// menu, and any plugin calling BaseComm_SetClientGag/Mute
// ============================================================
//
// basecomm tracks gag (text chat) and mute (voice) as two independent flags and reports every
// change through BaseComm_OnClientGag / BaseComm_OnClientMute, so those two forwards are the
// complete record: sm_silence arrives as a gag plus a mute, group targets like @all arrive once
// per player. Stored as "gag" and "mute" rows. Legacy "silence" rows are still honoured.
//
// Comm restrictions have no duration - they last until lifted, as they always have here.

public Action Listener_CommCommand(int client, const char[] command, int argc)
{
    // Listeners run before the command itself, so basecomm's forwards for this command see it.
    // Cleared next frame, so a later forward from elsewhere (admin menu, another plugin) is not
    // attributed to this admin.
    g_iCommIssuer = client;
    RequestFrame(Frame_ClearCommIssuer);
    return Plugin_Continue;
}

public void Frame_ClearCommIssuer(any data)
{
    g_iCommIssuer = -1;
}

public void BaseComm_OnClientGag(int client, bool gagState)
{
    OnCommStateChanged(client, "gag", gagState);
}

public void BaseComm_OnClientMute(int client, bool muteState)
{
    OnCommStateChanged(client, "mute", muteState);
}

void OnCommStateChanged(int client, const char[] punishmentType, bool enabled)
{
    // Our own re-application on connect - already stored.
    if (g_bApplyingFromDb) return;
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return;

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64)))
    {
        LogError("Not persisting %s %s of %N: no SteamID available", punishmentType, enabled ? "on" : "off", client);
        return;
    }

    if (enabled)
        AddCommPunishmentToDatabase(ResolveBanSource(g_iCommIssuer), steamid64, punishmentType);
    else
        RemoveCommPunishmentFromDatabase(steamid64, punishmentType);
}

// basecomm's natives throw unless the client is fully in game, and the punishment lookup started
// in OnClientAuthorized usually returns before that - the player is still loading. Apply now if
// possible, otherwise hold the state until OnClientPutInServer.
void ApplyStoredComm(int client, bool gag, bool mute)
{
    if (!IsClientInGame(client))
    {
        g_bPendingGag[client]  = g_bPendingGag[client] || gag;
        g_bPendingMute[client] = g_bPendingMute[client] || mute;
        return;
    }

    if (!LibraryExists("basecomm"))
    {
        LogError("Cannot re-apply stored gag/mute to %N: basecomm is not loaded", client);
        return;
    }

    g_bApplyingFromDb = true;
    if (gag)  BaseComm_SetClientGag(client, true);
    if (mute) BaseComm_SetClientMute(client, true);
    g_bApplyingFromDb = false;
}

public void OnClientPutInServer(int client)
{
    if (!g_bPendingGag[client] && !g_bPendingMute[client]) return;

    bool gag  = g_bPendingGag[client];
    bool mute = g_bPendingMute[client];
    g_bPendingGag[client]  = false;
    g_bPendingMute[client] = false;

    ApplyStoredComm(client, gag, mute);
}

public void OnClientDisconnect(int client)
{
    g_bPendingGag[client]  = false;
    g_bPendingMute[client] = false;
}

// ============================================================
// DATABASE OPERATIONS
// ============================================================

void AddBanToDatabase(int requesterClient, const char[] targetSteamID, const char[] targetIP, const char[] reason, int duration, const char[] punishmentType)
{
    bool hasIP    = (strlen(targetIP) > 0);

    char adminValue[32];
    AdminSqlValue(requesterClient, adminValue, sizeof(adminValue));

    // An IP ban of someone who is not connected has no SteamID. Writing the empty string into the
    // unquoted bigint slot would be a syntax error, so it becomes NULL.
    char steamValue[32];
    if (strlen(targetSteamID) > 0)
        strcopy(steamValue, sizeof(steamValue), targetSteamID);
    else
        strcopy(steamValue, sizeof(steamValue), "NULL");

    char ipValue[128];
    if (hasIP)
        SqlQuote(targetIP, ipValue, sizeof(ipValue));
    else
        strcopy(ipValue, sizeof(ipValue), "NULL");

    char expiresValue[128];
    if (duration == 0)
        strcopy(expiresValue, sizeof(expiresValue), "NULL");
    else
        Format(expiresValue, sizeof(expiresValue), "CURRENT_TIMESTAMP + INTERVAL '%d seconds'", duration);

    char reasonValue[MAX_REASON_BYTES * 2 + 3];
    SqlQuote(reason, reasonValue, sizeof(reasonValue));

    // Build query
    char query[MAX_QUERY_LENGTH];
    Format(query, sizeof(query),
           "INSERT INTO punishments (punishment_type, target_steam_id, target_ip, admin_steam_id, reason, expires_at) VALUES ('%s', %s, %s, %s, %s, %s)",
           punishmentType, steamValue, ipValue, adminValue, reasonValue, expiresValue);

    RunWrite(query);
}

void RemoveBanFromDatabase(const char[] target, bool isTargetIP)
{
    // Callers pass a SteamID64 (digits only, from SteamIdTo64) or an IP, which is quoted.
    char whereClause[256];
    if (isTargetIP)
    {
        char quoted[160];
        SqlQuote(target, quoted, sizeof(quoted));
        Format(whereClause, sizeof(whereClause), "target_ip = %s", quoted);
    }
    else
        Format(whereClause, sizeof(whereClause), "target_steam_id = %s", target);

    char query[MAX_QUERY_LENGTH];
    Format(query, sizeof(query),
           "UPDATE punishments SET is_active = FALSE WHERE %s AND punishment_type = '%s'",
           whereClause, isTargetIP ? "ban_ip" : "ban_steamid");

    RunWrite(query);
}

void AddCommPunishmentToDatabase(int admin, const char[] targetSteamID, const char[] punishmentType)
{
    char adminValue[32];
    AdminSqlValue(admin, adminValue, sizeof(adminValue));

    // basecomm fires the forward again when an already-gagged player is gagged again, so only
    // insert when there is no active row covering it yet (a legacy "silence" covers both).
    // targetSteamID is from GetClientAuthId; punishmentType is "gag" or "mute".
    char query[MAX_QUERY_LENGTH];
    Format(query, sizeof(query),
           "INSERT INTO punishments (punishment_type, target_steam_id, admin_steam_id, expires_at) SELECT '%s', %s, %s, NULL WHERE NOT EXISTS (SELECT 1 FROM punishments WHERE target_steam_id = %s AND punishment_type IN ('%s', 'silence') AND is_active)",
           punishmentType, targetSteamID, adminValue, targetSteamID, punishmentType);

    RunWrite(query);
}

void RemoveCommPunishmentFromDatabase(const char[] targetSteamID, const char[] punishmentType)
{
    // A legacy "silence" row is both a gag and a mute. Lifting one half must keep the other, so
    // carry the other half over into its own row before the silence row is deactivated. Writes
    // on this connection run in order, and RunWrite's retry queue preserves that order.
    char other[8];
    strcopy(other, sizeof(other), StrEqual(punishmentType, "gag") ? "mute" : "gag");

    char query[MAX_QUERY_LENGTH];
    Format(query, sizeof(query),
           "INSERT INTO punishments (punishment_type, target_steam_id, admin_steam_id, reason, expires_at) SELECT '%s', target_steam_id, admin_steam_id, reason, expires_at FROM punishments WHERE target_steam_id = %s AND punishment_type = 'silence' AND is_active AND NOT EXISTS (SELECT 1 FROM punishments WHERE target_steam_id = %s AND punishment_type = '%s' AND is_active) LIMIT 1",
           other, targetSteamID, targetSteamID, other);
    RunWrite(query);

    Format(query, sizeof(query),
           "UPDATE punishments SET is_active = FALSE WHERE target_steam_id = %s AND punishment_type IN ('%s', 'silence') AND is_active",
           targetSteamID, punishmentType);
    RunWrite(query);
}

// ============================================================
// RELIABLE WRITES
// ============================================================
//
// The pooled connection to this database is dropped when it sits idle, and nothing notices until
// the next query fails with "server closed the connection unexpectedly" (seen on main 09/20, and
// in gg2_messages, gg2_forceretry_optout and clientprefs). Punishments are written rarely, so the
// first ban after a quiet stretch was exactly the one most likely to hit a dead connection - and
// with only a LogError in the callback it was silently lost, while the engine ban still applied
// and hid the problem until the next restart.
//
// Every write now goes through here. A connection failure queues the query, reconnects, and
// replays it once the connection is back. Any other failure (bad SQL, a constraint) is logged and
// dropped - replaying those would just fail again. Each query is replayed at most once.

void RunWrite(const char[] query, bool isRetry = false)
{
    if (g_Database == null)
    {
        QueuePendingWrite(query, isRetry);
        ReconnectDatabase();
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(isRetry);
    pack.WriteString(query);
    g_Database.Query(OnWriteFinished, query, pack);
}

public void OnWriteFinished(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    bool isRetry = pack.ReadCell();
    char query[MAX_QUERY_LENGTH];
    pack.ReadString(query, sizeof(query));
    delete pack;

    if (results != null) return;

    if (!isRetry && IsConnectionError(error))
    {
        LogMessage("Database write failed on a dead connection, will retry after reconnecting: %s", error);
        QueuePendingWrite(query, false);
        ReconnectDatabase();
        return;
    }

    LogError("Failed to write punishment to database: %s -- query: %s", error, query);
}

void QueuePendingWrite(const char[] query, bool isRetry)
{
    if (isRetry)
    {
        LogError("Dropping punishment write after its retry also found no connection -- query: %s", query);
        return;
    }

    if (g_PendingWrites.Length >= MAX_PENDING_WRITES)
    {
        LogError("Pending punishment write queue full, dropping -- query: %s", query);
        return;
    }

    g_PendingWrites.PushString(query);
}

void FlushPendingWrites()
{
    int count = g_PendingWrites.Length;
    if (count == 0) return;

    LogMessage("Replaying %d punishment write(s) queued while the database was unavailable", count);

    char query[MAX_QUERY_LENGTH];
    for (int i = 0; i < count; i++)
    {
        g_PendingWrites.GetString(i, query, sizeof(query));
        RunWrite(query, true);
    }
    g_PendingWrites.Clear();
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

// The admin's SteamID64 as a SQL value, or NULL. NULL is also the answer when the admin has no
// SteamID yet (not Steam-authenticated, e.g. during a Steam outage): the empty string this used to
// write is not a valid bigint, so the whole INSERT failed and the ban was never recorded.
void AdminSqlValue(int client, char[] out, int maxlen)
{
    char steamid[32];
    if (client > 0 && GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid)))
        strcopy(out, maxlen, steamid);
    else
        strcopy(out, maxlen, "NULL");
}

// Quotes a string for Postgres without needing a live connection, so a query can be built while
// the connection is down and queued. standard_conforming_strings is on (the Postgres default since
// 9.1), so inside '...' only the single quote is special and is escaped by doubling.
void SqlQuote(const char[] value, char[] out, int maxlen)
{
    int o = 0;
    if (o < maxlen - 1) out[o++] = '\'';
    for (int i = 0; value[i] != '\0' && o < maxlen - 2; i++)
    {
        if (value[i] == '\'')
        {
            if (o >= maxlen - 3) break;
            out[o++] = '\'';
        }
        out[o++] = value[i];
    }
    out[o++] = '\'';
    out[o]   = '\0';
}
