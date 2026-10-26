#include <sourcemod>
#include <sdktools>
#include <adminmenu>
#include <dhooks>
#include <steamids>
// Provides the natives declared there, so it must not declare itself as a dependency.
#define PUNISHMENTS_PLUGIN
#include <punishments>

// Optional: without basecomm this plugin still persists and enforces bans; only gag/mute
// persistence is lost.
#undef REQUIRE_PLUGIN
#include <basecomm>
#define REQUIRE_PLUGIN

// Optional too: class bans are announced on Discord through gg2_discord when it is loaded.
#include <discord>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION    "1.0.0"
// Byte buffer for a reason. The column is varchar(255) - characters, not bytes - and basebans
// passes up to 255 bytes, so a 255-byte buffer (254 usable) could cut the last character in half,
// and Postgres rejects the whole INSERT on an invalid UTF-8 sequence.
#define MAX_REASON_BYTES  512

// Longest kick message that reaches the player intact: KickClient formats into a 256-byte buffer.
// Ban messages are built to fit this, trimming the reason rather than losing the duration.
#define KICK_MESSAGE_BYTES 256

// Seconds until expires_at, NULL for a permanent ban. Worked out by the database rather than by
// comparing against GetTime(), so clock skew between the two hosts cannot shift a ban. Capped to
// fit an int (a ban past 2038 still ends up "permanent enough").
#define BAN_REMAINING_SQL "LEAST(CEIL(EXTRACT(EPOCH FROM (expires_at - CURRENT_TIMESTAMP))), 2147483647)::int"

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

// One active ban - mirrors a punishments row. See "BAN CACHE".
enum struct BanRow
{
    bool byIp;                        // ban_ip row; otherwise ban_steamid
    char steamid[32];                 // SteamID64, or "" (an ip ban of someone never seen)
    char ip[64];                      // "" for a ban_steamid row
    int  expires;                     // GetTime() it ends at, 0 = permanent
    char reason[MAX_REASON_BYTES];
}

ArrayList g_BanCache          = null;  // BanRow
bool      g_bBanCacheLoaded   = false;
bool      g_bBanCacheLoading  = false;

// !calladmin bans - see "CALLADMIN BANS".
#define CALLADMIN_ABUSE_REASON  "Abusing !calladmin"
#define CALLADMIN_ABUSE_COMMAND "calladmin_abuse"      // BanClient command string for the auto-ban
bool     g_bCallAdminBanned[MAXPLAYERS + 1];
int      g_iCallAdminBanExpires[MAXPLAYERS + 1];       // GetTime() the ban ends, 0 = permanent
char     g_szCallAdminBanOwner[MAXPLAYERS + 1][32];    // SteamID64 of the admin who issued it, "" = console
int      g_iMenuTargetUserId[MAXPLAYERS + 1];          // admin menu: player picked, awaiting a length
ConVar   g_cvCallAdminAbuseBanMinutes;
TopMenu  g_hAdminMenu = null;

// Admin who owns the next ban OnBanClient stores, when that is not BanClient's `source` (a client
// index): the !calladmin auto-ban belongs to whoever issued the calladmin ban, who may be offline.
bool g_bBanOwnerOverride = false;
char g_szBanOwnerOverride[32];

// Class bans - see "CLASS BANS".
#define MAX_CLASS_NAME   64                             // class template name, e.g. template_combat_medic
#define MAX_SLOT_TITLE   80                             // squadSlot_t title buffer (char[0x50])
#define TEAM_SPECTATOR   1
enum struct ClassBan
{
    char className[MAX_CLASS_NAME];
    int  expires;                                       // GetTime() it ends at, 0 = permanent
    char reason[MAX_REASON_BYTES];
}
ArrayList g_ClassBans[MAXPLAYERS + 1];                  // ClassBan, per player; null = none loaded
char      g_szCurrentClass[MAXPLAYERS + 1][MAX_CLASS_NAME];   // from player_pick_squad, "" = none yet
float     g_fLastClassRefusal[MAXPLAYERS + 1];          // GetGameTime() of the last refusal message
int       g_iMenuClassTargetUserId[MAXPLAYERS + 1];     // admin menu: player picked
char      g_szMenuClass[MAXPLAYERS + 1][MAX_CLASS_NAME];// admin menu: class picked, awaiting a length
Handle    g_hGetTheaterDirector   = null;
Handle    g_hGetTeamDefinition    = null;
bool      g_bClassPickHooked      = false;              // AddPlayerToSquad detour active

// Plugin info
public Plugin myinfo =
{
    name        = "Persistent Punishments",
    author      = "sdw",
    description = "Persistent ban and communication punishment system with PostgreSQL",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("Punishments_IsCallAdminBanned", Native_IsCallAdminBanned);
    RegPluginLibrary("punitive_persistence");
    MarkNativeAsOptional("send_to_discord");
    return APLRes_Success;
}

public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    // Create plugin version cvar
    CreateConVar("sm_punishments_version", PLUGIN_VERSION, "Persistent Punishments version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvCallAdminAbuseBanMinutes = CreateConVar("sm_calladmin_abuse_ban_minutes", "60",
                                                "Minutes a player banned from !calladmin is banned from the server for each time they use it",
                                                _, true, 1.0);

    // calladmin_ban is this plugin's own punishment, so unlike bans and comms it owns the commands.
    // As sm_ commands they also work from chat as !bancalladmin / !unbancalladmin.
    RegAdminCmd("sm_bancalladmin", Command_BanCallAdmin, ADMFLAG_BAN,
                "sm_bancalladmin <#userid|name|steamid> <minutes|0> [reason] - ban the player from the server whenever they use !calladmin");
    RegAdminCmd("sm_unbancalladmin", Command_UnbanCallAdmin, ADMFLAG_BAN,
                "sm_unbancalladmin <#userid|name|steamid> - lift a !calladmin ban");
    AddCommandListener(Listener_Say, "say");
    AddCommandListener(Listener_Say, "say_team");

    RegAdminCmd("sm_banclass", Command_BanClass, ADMFLAG_BAN,
                "sm_banclass <#userid|name|steamid> <class> <minutes|0> [reason] - ban a player from a class");
    RegAdminCmd("sm_unbanclass", Command_UnbanClass, ADMFLAG_BAN,
                "sm_unbanclass <#userid|name|steamid> <class> - lift a class ban");
    RegAdminCmd("sm_classes", Command_Classes, ADMFLAG_BAN,
                "sm_classes - list the current theater's classes, for sm_banclass");
    HookEvent("player_pick_squad", Event_PlayerPickSquad);
    HookEvent("player_team", Event_PlayerTeam);
    SetupClassHooks();

    TopMenu topmenu;
    if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
        OnAdminMenuReady(topmenu);

    // Ban commands (sm_ban, sm_addban, sm_banip, sm_unban) are deliberately NOT registered here.
    // basebans owns them, and every ban and unban it issues reaches the database through the
    // OnBanClient/OnBanIdentity/OnRemoveBan forwards below. This plugin used to register its own
    // sm_addban/sm_banip/sm_unban as well; SourceMod ran BOTH handlers for each, with opposite
    // argument formats (SteamID64 + "8h" here, STEAM_X + bare minutes in basebans), so one of the
    // two always rejected the command and the other half-applied it. Seen on main 2026-09-23:
    // "sm_addban 8h STEAM_1:..." cut an 8-hour engine ban to 8 minutes and wrote nothing here.

    g_PendingWrites = new ArrayList(ByteCountToCells(MAX_QUERY_LENGTH));
    g_BanCache      = new ArrayList(sizeof(BanRow));

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
    LoadBanCache();
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
    LoadBanCache();
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

// IP bans are refused here, before the player loads in. Only the IP is known this early, and it
// has to be: a player who never gets Steam-authorized (Steam outage, or deliberately) never reaches
// OnClientAuthorized, and the engine's addip - which used to stop them - no longer holds our bans.
public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
    if (IsFakeClient(client)) return true;

    char ip[64];
    GetClientIP(client, ip, sizeof(ip));

    BanRow ban;
    if (!FindCachedBan("", ip, ban)) return true;

    BuildBanMessage(RemainingBanMinutes(ban), true, ban.reason, rejectmsg, maxlen < KICK_MESSAGE_BYTES ? maxlen : KICK_MESSAGE_BYTES);
    LogMessage("Refused connection from banned IP %s: %s", ip, rejectmsg);
    return false;
}

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

    // The cache answers without the database, so a ban holds through a database outage. A miss
    // still goes to the database below, which covers the time before the cache has loaded.
    BanRow ban;
    if (FindCachedBan(steamid64, ip, ban))
    {
        KickForBan(client, ban);
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
    // Longest ban first, so the message shows the one that actually decides when they can return.
    char query[1024];
    g_Database.Format(query, sizeof(query),
                      "SELECT punishment_type, " ... BAN_REMAINING_SQL ... ", COALESCE(reason, ''), COALESCE(target_ip, ''), COALESCE(target_steam_id::text, ''), COALESCE(admin_steam_id::text, ''), COALESCE(target_class, '') FROM punishments WHERE is_active = TRUE AND (target_steam_id = %s OR target_ip = '%s') AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP) ORDER BY expires_at DESC NULLS FIRST",
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
    bool gagged         = false;
    bool muted          = false;
    bool loadedClassBan = false;

    while (results.FetchRow())
    {
        char punishmentType[32];
        results.FetchString(0, punishmentType, sizeof(punishmentType));

        if (StrEqual(punishmentType, "ban_steamid") || StrEqual(punishmentType, "ban_ip"))
        {
            // Rows are longest-first, so the first ban is the one to report. Cache it so the next
            // attempt is refused without waiting on the database.
            BanRow ban;
            ReadBanRow(results, 1, StrEqual(punishmentType, "ban_ip"), ban);
            CacheBan(ban);
            KickForBan(client, ban);
            delete pack;
            return;
        }
        else if (StrEqual(punishmentType, "calladmin_ban"))
        {
            char owner[32];
            results.FetchString(5, owner, sizeof(owner));
            SetCallAdminBanState(client, true, results.IsFieldNull(1) ? 0 : ExpiryFromRemaining(results.FetchInt(1)), owner);
        }
        else if (StrEqual(punishmentType, "class_ban"))
        {
            ClassBan classBan;
            results.FetchString(6, classBan.className, sizeof(classBan.className));
            results.FetchString(2, classBan.reason, sizeof(classBan.reason));
            classBan.expires = results.IsFieldNull(1) ? 0 : ExpiryFromRemaining(results.FetchInt(1));
            SetClientClassBan(client, classBan);
            loadedClassBan = true;
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

    // The lookup usually finishes before the player has picked a class, but not always.
    if (loadedClassBan)
        EnforceCurrentClass(client);

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
// These forwards fire before core applies the ban, and return Plugin_Handled: core then skips its
// engine `banid`/`addip`, and this plugin alone enforces the ban - from the cache, backed by the
// database (see "BAN CACHE"). The engine rejects a banned player with its own fixed text, which
// cannot be changed; taking the ban away from it is what lets every rejection carry the duration.
//
// The kick is ours too. BanClient still queues core's own kick after a handled forward, with
// basebans' message ("Banned", or the bare reason) - but core ignores a second kick for a player
// already in its kick queue, and KickClient here queues first, so this message is the one shown.
// Same for sm_banip, which kicks with "Banned: <reason>" after BanIdentity returns.
//
// The !calladmin auto-ban (see "CALLADMIN BANS") comes through here too, on purpose: it calls
// BanClient so it is stored and messaged like any other ban.

public Action OnBanClient(int client, int time, int flags, const char[] rawReason, const char[] kick_message, const char[] command, any source)
{
    // Not a real ban length (basebans rejects these); leave it to the engine rather than guess.
    if (IsFakeClient(client) || time < 0) return Plugin_Continue;

    char adminSteamId[32];
    if (g_bBanOwnerOverride)
        strcopy(adminSteamId, sizeof(adminSteamId), g_szBanOwnerOverride);
    else
        GetAdminSteamId(ResolveBanSource(source), adminSteamId, sizeof(adminSteamId));

    BanRow ban;
    ban.byIp    = (flags & BANFLAG_IP) != 0;
    ban.expires = BanExpiry(time);
    CleanBanReason(rawReason, ban.reason, sizeof(ban.reason));

    if (!GetClientAuthId(client, AuthId_SteamID64, ban.steamid, sizeof(ban.steamid)))
        ban.steamid[0] = '\0';

    if (ban.byIp)
        GetClientIP(client, ban.ip, sizeof(ban.ip));
    else if (ban.steamid[0] == '\0')
    {
        // Nothing to store or cache it under: leave this one to the engine, as before.
        LogError("Not persisting %s ban of %N: no SteamID available", command, client);
        return Plugin_Continue;
    }

    CacheBan(ban);
    AddBanToDatabase(adminSteamId, ban.steamid, ban.ip, ban.reason, time, ban.byIp ? "ban_ip" : "ban_steamid");

    if (!(flags & BANFLAG_NOKICK))
    {
        char message[KICK_MESSAGE_BYTES];
        BuildBanMessage(time, false, ban.reason, message, sizeof(message));
        KickClient(client, "%s", message);
    }

    return Plugin_Handled;
}

public Action OnBanIdentity(const char[] identity, int time, int flags, const char[] rawReason, const char[] command, any source)
{
    if (time < 0) return Plugin_Continue;

    char adminSteamId[32];
    GetAdminSteamId(ResolveBanSource(source), adminSteamId, sizeof(adminSteamId));

    BanRow ban;
    ban.byIp    = (flags & BANFLAG_IP) != 0;
    ban.expires = BanExpiry(time);
    CleanBanReason(rawReason, ban.reason, sizeof(ban.reason));

    if (ban.byIp)
        strcopy(ban.ip, sizeof(ban.ip), identity);
    else if (!SteamIdTo64(identity, ban.steamid, sizeof(ban.steamid)))
    {
        LogError("Not persisting %s ban of \"%s\": unrecognised SteamID format", command, identity);
        return Plugin_Continue;
    }

    CacheBan(ban);
    AddBanToDatabase(adminSteamId, ban.steamid, ban.ip, ban.reason, time, ban.byIp ? "ban_ip" : "ban_steamid");

    // sm_addban is usually for someone offline, but if they are here, a ban means gone now - not
    // whenever they next reconnect.
    char message[KICK_MESSAGE_BYTES];
    BuildBanMessage(time, false, ban.reason, message, sizeof(message));
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && !IsFakeClient(i) && BanMatchesClient(ban, i))
            KickClient(i, "%s", message);
    }

    return Plugin_Handled;
}

// basebans' sm_unban. Without this, a ban persisted above would outlive an unban issued through
// basebans. Returns Plugin_Continue so the engine also drops any ban it still holds from before
// this plugin took bans over (e.g. permanent ones in banned_user.cfg).
public Action OnRemoveBan(const char[] identity, int flags, const char[] command, any source)
{
    if (flags & BANFLAG_IP)
    {
        UncacheBan(true, identity);
        RemoveBanFromDatabase(identity, true);
        return Plugin_Continue;
    }

    char steamid64[32];
    if (SteamIdTo64(identity, steamid64, sizeof(steamid64)))
    {
        UncacheBan(false, steamid64);
        RemoveBanFromDatabase(steamid64, false);
    }

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
    SetCallAdminBanState(client, false, 0, "");
    delete g_ClassBans[client];
    g_szCurrentClass[client][0] = '\0';
    g_fLastClassRefusal[client] = 0.0;
}

// ============================================================
// BAN CACHE - every active ban, held in memory
// ============================================================
//
// Bans are enforced here rather than by the engine (see OnBanClient), and a lookup that needed the
// database would let banned players in whenever it is unreachable - the pooled connection drops
// when idle, so that is not rare. The cache answers every connect check first.
//
// Loaded from the database once, on the first connection that works. After that it is kept
// current by this server's own bans and unbans, which update it before their database write -
// bans are only ever issued through this server, so nothing else can change the table under it.
// Until the load completes, the database lookup in OnClientAuthorized covers SteamID bans.
//
// Rows mirror the table: matching is "SteamID matches OR IP matches", like the database check,
// and an unban removes exactly the rows RemoveBanFromDatabase deactivates.

void LoadBanCache()
{
    if (g_Database == null || g_bBanCacheLoaded || g_bBanCacheLoading) return;
    g_bBanCacheLoading = true;

    g_Database.Query(OnBanCacheLoaded,
                     "SELECT punishment_type, " ... BAN_REMAINING_SQL ... ", COALESCE(reason, ''), COALESCE(target_ip, ''), COALESCE(target_steam_id::text, '') FROM punishments WHERE is_active = TRUE AND punishment_type IN ('ban_steamid', 'ban_ip') AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)");
}

public void OnBanCacheLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    g_bBanCacheLoading = false;

    if (results == null)
    {
        // A reconnect tries again; any other failure leaves only the per-connect database lookup.
        LogError("Failed to load ban cache: %s", error);
        if (IsConnectionError(error))
            ReconnectDatabase();
        return;
    }

    // Merged, not replaced: a ban issued while this query was running is already in the cache.
    char punishmentType[32];
    BanRow ban;
    while (results.FetchRow())
    {
        results.FetchString(0, punishmentType, sizeof(punishmentType));
        ReadBanRow(results, 1, StrEqual(punishmentType, "ban_ip"), ban);
        CacheBan(ban);
    }

    g_bBanCacheLoaded = true;
    LogMessage("Loaded %d active ban(s) into the ban cache", g_BanCache.Length);
}

// Reads a ban from columns col (seconds remaining, NULL = permanent), col+1 (reason), col+2 (IP)
// and col+3 (SteamID64) - the layout both ban queries use.
void ReadBanRow(DBResultSet results, int col, bool byIp, BanRow ban)
{
    ban.byIp = byIp;

    ban.expires = results.IsFieldNull(col) ? 0 : ExpiryFromRemaining(results.FetchInt(col));

    results.FetchString(col + 1, ban.reason, sizeof(ban.reason));
    results.FetchString(col + 2, ban.ip, sizeof(ban.ip));
    results.FetchString(col + 3, ban.steamid, sizeof(ban.steamid));
}

// Adds a ban, or extends the existing one for the same target - a re-ban never shortens a ban.
void CacheBan(BanRow ban)
{
    BanRow existing;
    for (int i = 0; i < g_BanCache.Length; i++)
    {
        g_BanCache.GetArray(i, existing);
        if (existing.byIp != ban.byIp || !StrEqual(existing.steamid, ban.steamid) || !StrEqual(existing.ip, ban.ip))
            continue;

        if (!BanOutlasts(existing, ban))
            g_BanCache.SetArray(i, ban);
        return;
    }

    g_BanCache.PushArray(ban);
}

void UncacheBan(bool byIp, const char[] identity)
{
    BanRow ban;
    for (int i = g_BanCache.Length - 1; i >= 0; i--)
    {
        g_BanCache.GetArray(i, ban);
        if (ban.byIp == byIp && StrEqual(byIp ? ban.ip : ban.steamid, identity))
            g_BanCache.Erase(i);
    }
}

// The longest active ban matching either identifier ("" matches nothing). Drops expired rows.
bool FindCachedBan(const char[] steamid, const char[] ip, BanRow found)
{
    bool   foundAny = false;
    int    now = GetTime();
    BanRow ban;

    for (int i = g_BanCache.Length - 1; i >= 0; i--)
    {
        g_BanCache.GetArray(i, ban);

        if (ban.expires != 0 && ban.expires <= now)
        {
            g_BanCache.Erase(i);
            continue;
        }

        bool matches = (steamid[0] != '\0' && StrEqual(ban.steamid, steamid))
                    || (ip[0] != '\0' && StrEqual(ban.ip, ip));
        if (!matches) continue;

        if (!foundAny || BanOutlasts(ban, found))
            found = ban;
        foundAny = true;
    }

    return foundAny;
}

// True when a ends strictly later than b (permanent is latest).
bool BanOutlasts(BanRow a, BanRow b)
{
    if (b.expires == 0) return false;
    if (a.expires == 0) return true;
    return a.expires > b.expires;
}

bool BanMatchesClient(BanRow ban, int client)
{
    char value[64];
    if (ban.steamid[0] != '\0' && GetClientAuthId(client, AuthId_SteamID64, value, sizeof(value)) && StrEqual(value, ban.steamid))
        return true;

    if (ban.ip[0] != '\0')
    {
        GetClientIP(client, value, sizeof(value));
        if (StrEqual(value, ban.ip)) return true;
    }

    return false;
}

void KickForBan(int client, BanRow ban)
{
    char message[KICK_MESSAGE_BYTES];
    BuildBanMessage(RemainingBanMinutes(ban), true, ban.reason, message, sizeof(message));
    LogMessage("Kicking banned player %L: %s", client, message);
    KickClient(client, "%s", message);
}

// GetTime() a ban of this many minutes ends at; 0 (permanent) for 0. Minutes, not seconds, so a
// long ban cannot overflow on the way; anything past 2038 is clamped there.
int BanExpiry(int minutes)
{
    if (minutes <= 0) return 0;

    int now = GetTime();
    if (minutes > (2147483647 - now) / 60) return 2147483647;
    return now + minutes * 60;
}

// GetTime() something ends at, from BAN_REMAINING_SQL's seconds remaining. Clamped at 2038.
int ExpiryFromRemaining(int remaining)
{
    int now = GetTime();
    return (remaining > 2147483647 - now) ? 2147483647 : now + remaining;
}

// Whole minutes left, rounded up so a ban never reads "0m"; 0 for a permanent ban.
int RemainingBanMinutes(BanRow ban)
{
    return MinutesUntil(ban.expires);
}

// The same for any GetTime() expiry; 0 (permanent) stays 0.
int MinutesUntil(int expires)
{
    if (expires == 0) return 0;

    int seconds = expires - GetTime();
    if (seconds < 60) return 1;
    return (seconds + 59) / 60;
}

// ============================================================
// CALLADMIN BANS - calladmin_ban rows, sm_bancalladmin / sm_unbancalladmin, admin menu
// ============================================================
//
// For players who abuse !calladmin, which pings the whole admin role on Discord. A player banned
// from it can still type it: the message is relayed to Discord by gg2_discord as usual, but
// without the role ping (it asks Punishments_IsCallAdminBanned), and this plugin bans them from
// the server for sm_calladmin_abuse_ban_minutes. That server ban goes through BanClient like any
// other, so it is stored, cached, reported to Discord and messaged the same way, and it is owned by
// the admin who issued the calladmin ban. The calladmin ban itself stays, so every repeat costs
// another server ban.
//
// Re-applied on connect from the database.

public any Native_IsCallAdminBanned(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients) return false;
    return IsCallAdminBanned(client);
}

bool IsCallAdminBanned(int client)
{
    if (!g_bCallAdminBanned[client]) return false;

    // A timed ban that ran out while the player was online.
    if (g_iCallAdminBanExpires[client] != 0 && g_iCallAdminBanExpires[client] <= GetTime())
    {
        SetCallAdminBanState(client, false, 0, "");
        return false;
    }
    return true;
}

void SetCallAdminBanState(int client, bool banned, int expires, const char[] owner)
{
    g_bCallAdminBanned[client]     = banned;
    g_iCallAdminBanExpires[client] = banned ? expires : 0;
    strcopy(g_szCallAdminBanOwner[client], sizeof(g_szCallAdminBanOwner[]), banned ? owner : "");
}

public Action Listener_Say(int client, const char[] command, int argc)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Continue;

    // In the kick queue already: a second !calladmin in the same frame must not ban twice.
    if (!IsCallAdminBanned(client) || IsClientInKickQueue(client)) return Plugin_Continue;

    char message[1024];
    GetCmdArgString(message, sizeof(message));
    StripQuotes(message);
    if (!IsCallAdminMessage(message)) return Plugin_Continue;

    // Plugin_Continue either way: the message still goes out to chat and to Discord. The kick is
    // delayed to the next frame, so the player is still here for both.
    int minutes = g_cvCallAdminAbuseBanMinutes.IntValue;
    LogAction(0, client, "\"%L\" used !calladmin while banned from it and was banned (minutes \"%d\")", client, minutes);

    // The owner goes to the database through the override; `source` is only for who Discord and
    // other listeners see, and has to be a client index, so it names the issuer only if online.
    int issuer = g_szCallAdminBanOwner[client][0] != '\0' ? FindClientBySteamId64(g_szCallAdminBanOwner[client]) : 0;
    if (issuer != 0 && !IsClientInGame(issuer)) issuer = 0;

    g_bBanOwnerOverride = true;
    strcopy(g_szBanOwnerOverride, sizeof(g_szBanOwnerOverride), g_szCallAdminBanOwner[client]);
    BanClient(client, minutes, BANFLAG_AUTO, CALLADMIN_ABUSE_REASON, CALLADMIN_ABUSE_REASON, CALLADMIN_ABUSE_COMMAND, issuer);
    g_bBanOwnerOverride = false;

    return Plugin_Continue;
}

// ------------------------------------------------------------
// Commands
// ------------------------------------------------------------

public Action Command_BanCallAdmin(int client, int args)
{
    char target[MAX_TARGET_LENGTH], minutesArg[16], reason[MAX_REASON_BYTES];
    GetCallAdminBanArgs(target, sizeof(target), minutesArg, sizeof(minutesArg), reason, sizeof(reason));
    if (target[0] == '\0' || !IsDigitString(minutesArg))
    {
        ReplyToCommand(client, "[SM] Usage: sm_bancalladmin <#userid|name|steamid> <minutes|0> [reason]");
        return Plugin_Handled;
    }

    ApplyCallAdminBanCommand(client, target, true, StringToInt(minutesArg), reason);
    return Plugin_Handled;
}

public Action Command_UnbanCallAdmin(int client, int args)
{
    char target[MAX_TARGET_LENGTH], unused[16], unusedReason[16];
    GetCallAdminBanArgs(target, sizeof(target), unused, sizeof(unused), unusedReason, sizeof(unusedReason));
    if (target[0] == '\0')
    {
        ReplyToCommand(client, "[SM] Usage: sm_unbancalladmin <#userid|name|steamid>");
        return Plugin_Handled;
    }

    ApplyCallAdminBanCommand(client, target, false, 0, "");
    return Plugin_Handled;
}

// <target> <minutes> [reason...], split from the raw argument string with BreakString like
// basebans: GetCmdArg would split "STEAM_1:0:123" at the colons. The reason is the rest of the
// line, as typed, with one surrounding pair of quotes removed.
void GetCallAdminBanArgs(char[] target, int targetLen, char[] minutes, int minutesLen, char[] reason, int reasonLen)
{
    char args[MAX_REASON_BYTES];
    GetCmdArgString(args, sizeof(args));

    target[0]  = '\0';
    minutes[0] = '\0';
    reason[0]  = '\0';

    int pos = BreakString(args, target, targetLen);
    if (pos == -1) return;

    int next = BreakString(args[pos], minutes, minutesLen);
    if (next == -1) return;

    CleanBanReason(args[pos + next], reason, reasonLen);
}

bool IsDigitString(const char[] s)
{
    if (s[0] == '\0') return false;
    for (int i = 0; s[i] != '\0'; i++)
        if (!IsCharNumeric(s[i])) return false;
    return true;
}

// The target is a SteamID in any form (the player may be offline), or a name / #userid / group.
void ApplyCallAdminBanCommand(int admin, const char[] target, bool ban, int minutes, const char[] reason)
{
    char details[MAX_REASON_BYTES + 64];
    FormatBanDetails(ban, minutes, reason, details, sizeof(details));

    char steamid64[32];
    if (SteamIdTo64(target, steamid64, sizeof(steamid64)))
    {
        int  online  = FindClientBySteamId64(steamid64);
        bool allowed = (online != 0) ? CanUserTarget(admin, online)
                                     : (admin == 0 || CanAdminTarget(GetUserAdmin(admin), FindAdminByIdentity("steam", target)));
        if (!allowed)
        {
            ReplyToCommand(admin, "[SM] %t", "Unable to target");
            return;
        }

        SetCallAdminBan(admin, steamid64, ban, minutes, reason);
        LogAction(admin, online != 0 ? online : -1, "\"%L\" %s %s from !calladmin%s", admin, ban ? "banned" : "unbanned", target, details);
        ShowActivity2(admin, "[SM] ", "%s %s from !calladmin%s.", ban ? "Banned" : "Unbanned", target, details);
        return;
    }

    int  targets[MAXPLAYERS];
    char targetName[MAX_TARGET_LENGTH];
    bool tnIsMl;
    int  count = ProcessTargetString(target, admin, targets, sizeof(targets), COMMAND_FILTER_NO_BOTS,
                                     targetName, sizeof(targetName), tnIsMl);
    if (count <= 0)
    {
        ReplyToTargetError(admin, count);
        return;
    }

    for (int i = 0; i < count; i++)
        CallAdminBanClient(admin, targets[i], ban, minutes, reason, details);

    if (tnIsMl)
        ShowActivity2(admin, "[SM] ", "%s %t from !calladmin%s.", ban ? "Banned" : "Unbanned", targetName, details);
    else
        ShowActivity2(admin, "[SM] ", "%s %s from !calladmin%s.", ban ? "Banned" : "Unbanned", targetName, details);
}

// One connected player, from a command or the admin menu. False, with a reply, when they have no
// SteamID yet - there is nothing to store it under.
bool CallAdminBanClient(int admin, int target, bool ban, int minutes, const char[] reason, const char[] details)
{
    char steamid64[32];
    if (!GetClientAuthId(target, AuthId_SteamID64, steamid64, sizeof(steamid64)))
    {
        ReplyToCommand(admin, "[SM] %N has no SteamID yet, not changed.", target);
        return false;
    }

    SetCallAdminBan(admin, steamid64, ban, minutes, reason);
    LogAction(admin, target, "\"%L\" %s \"%L\" from !calladmin%s", admin, ban ? "banned" : "unbanned", target, details);
    return true;
}

// " for 1d (reason)", " permanently", or "" for an unban.
void FormatBanDetails(bool ban, int minutes, const char[] reason, char[] out, int maxlen)
{
    out[0] = '\0';
    if (!ban) return;

    if (minutes > 0)
    {
        char duration[64];
        FormatBanDuration(minutes, duration, sizeof(duration));
        Format(out, maxlen, " for %s", duration);
    }
    else
        strcopy(out, maxlen, " permanently");

    if (reason[0] != '\0')
        Format(out, maxlen, "%s (%s)", out, reason);
}

// Applies to the player now if they are connected, and replaces any stored calladmin ban.
void SetCallAdminBan(int admin, const char[] steamid64, bool ban, int minutes, const char[] reason)
{
    char owner[32];
    GetAdminSteamId(admin, owner, sizeof(owner));

    int online = FindClientBySteamId64(steamid64);
    if (online != 0)
        SetCallAdminBanState(online, ban, BanExpiry(minutes), owner);

    // steamid64 is digits only (SteamIdTo64 / GetClientAuthId). Deactivate first so a re-ban with a
    // new length replaces the old row; RunWrite keeps the two in order.
    char query[MAX_QUERY_LENGTH];
    Format(query, sizeof(query),
           "UPDATE punishments SET is_active = FALSE WHERE target_steam_id = %s AND punishment_type = 'calladmin_ban' AND is_active",
           steamid64);
    RunWrite(query);

    if (!ban) return;

    char adminValue[32];
    SteamIdSqlValue(owner, adminValue, sizeof(adminValue));

    char expiresValue[128];
    if (minutes == 0)
        strcopy(expiresValue, sizeof(expiresValue), "NULL");
    else
        Format(expiresValue, sizeof(expiresValue), "CURRENT_TIMESTAMP + INTERVAL '%d minutes'", minutes);

    char reasonValue[MAX_REASON_BYTES * 2 + 3];
    if (reason[0] != '\0')
        SqlQuote(reason, reasonValue, sizeof(reasonValue));
    else
        strcopy(reasonValue, sizeof(reasonValue), "NULL");

    Format(query, sizeof(query),
           "INSERT INTO punishments (punishment_type, target_steam_id, admin_steam_id, reason, expires_at) VALUES ('calladmin_ban', %s, %s, %s, %s)",
           steamid64, adminValue, reasonValue, expiresValue);
    RunWrite(query);
}

// 0 when nobody connected has that SteamID64.
int FindClientBySteamId64(const char[] steamid64)
{
    char auth[32];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && !IsFakeClient(i)
            && GetClientAuthId(i, AuthId_SteamID64, auth, sizeof(auth)) && StrEqual(auth, steamid64))
            return i;
    }
    return 0;
}

// ------------------------------------------------------------
// Admin menu - Player Commands > "Ban/unban from !calladmin"
// ------------------------------------------------------------
//
// Pick a player; one already banned from !calladmin is unbanned, anyone else goes on to a length.
// No reason step - the menu has nowhere to type one; use the command for that.

public void OnAdminMenuReady(Handle aTopMenu)
{
    TopMenu topmenu = TopMenu.FromHandle(aTopMenu);
    if (topmenu == g_hAdminMenu) return;
    g_hAdminMenu = topmenu;

    TopMenuObject playerCommands = g_hAdminMenu.FindCategory(ADMINMENU_PLAYERCOMMANDS);
    if (playerCommands != INVALID_TOPMENUOBJECT)
    {
        g_hAdminMenu.AddItem("sm_bancalladmin", AdminMenu_BanCallAdmin, playerCommands, "sm_bancalladmin", ADMFLAG_BAN);
        g_hAdminMenu.AddItem("sm_banclass", AdminMenu_BanClass, playerCommands, "sm_banclass", ADMFLAG_BAN);
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "adminmenu"))
        g_hAdminMenu = null;
}

public void AdminMenu_BanCallAdmin(TopMenu topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
    if (action == TopMenuAction_DisplayOption)
        strcopy(buffer, maxlength, "Ban/unban from !calladmin");
    else if (action == TopMenuAction_SelectOption)
        DisplayCallAdminTargetMenu(param);
}

void DisplayCallAdminTargetMenu(int client)
{
    Menu menu = new Menu(MenuHandler_CallAdminTarget);
    menu.SetTitle("Ban/unban from !calladmin:");
    menu.ExitBackButton = true;

    char userid[16], label[MAX_NAME_LENGTH + 16];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !CanUserTarget(client, i)) continue;

        IntToString(GetClientUserId(i), userid, sizeof(userid));
        Format(label, sizeof(label), "%N%s", i, IsCallAdminBanned(i) ? " [banned]" : "");
        menu.AddItem(userid, label);
    }

    if (menu.ItemCount == 0)
        menu.AddItem("", "No players", ITEMDRAW_DISABLED);

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_CallAdminTarget(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack && g_hAdminMenu != null)
            g_hAdminMenu.Display(param1, TopMenuPosition_LastCategory);
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        int userid = StringToInt(info);

        int target = MenuTargetOrReply(param1, userid);
        if (target == 0)
            DisplayCallAdminTargetMenu(param1);
        else if (IsCallAdminBanned(target))
        {
            ApplyCallAdminBanFromMenu(param1, target, false, 0);
            DisplayCallAdminTargetMenu(param1);
        }
        else
        {
            g_iMenuTargetUserId[param1] = userid;
            DisplayCallAdminLengthMenu(param1);
        }
    }
    return 0;
}

void DisplayCallAdminLengthMenu(int client)
{
    Menu menu = new Menu(MenuHandler_CallAdminLength);
    menu.SetTitle("Ban from !calladmin for:");
    menu.ExitBackButton = true;

    menu.AddItem("0", "Permanently");
    menu.AddItem("1440", "1 day");
    menu.AddItem("10080", "1 week");
    menu.AddItem("43200", "30 days");

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_CallAdminLength(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
            DisplayCallAdminTargetMenu(param1);
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        int target = MenuTargetOrReply(param1, g_iMenuTargetUserId[param1]);
        if (target != 0)
            ApplyCallAdminBanFromMenu(param1, target, true, StringToInt(info));
        DisplayCallAdminTargetMenu(param1);
    }
    return 0;
}

// The picked player, re-checked: they may have left, or the admin may no longer outrank them.
int MenuTargetOrReply(int admin, int userid)
{
    int target = GetClientOfUserId(userid);
    if (target == 0)
        PrintToChat(admin, "[SM] %t", "Player no longer available");
    else if (!CanUserTarget(admin, target))
    {
        PrintToChat(admin, "[SM] %t", "Unable to target");
        target = 0;
    }
    return target;
}

void ApplyCallAdminBanFromMenu(int admin, int target, bool ban, int minutes)
{
    char details[64];
    FormatBanDetails(ban, minutes, "", details, sizeof(details));

    // Replies from the shared code go to chat: the menu has no command of its own to reply to.
    ReplySource previous = SetCmdReplySource(SM_REPLY_TO_CHAT);
    if (CallAdminBanClient(admin, target, ban, minutes, "", details))
        ShowActivity2(admin, "[SM] ", "%s %N from !calladmin%s.", ban ? "Banned" : "Unbanned", target, details);
    SetCmdReplySource(previous);
}

// ============================================================
// CLASS BANS - class_ban rows, sm_banclass / sm_unbanclass, admin menu
// ============================================================
//
// Bans a player from one class (a theater class template, e.g. template_recon_security_coop for
// the Weapons Sergeant slot, template_combat_medic for the medic). Keyed by template name, so a
// theater without that class simply never matches and the ban is still there on maps that have it.
//
// ENFORCEMENT. A detour on CPlayTeam::AddPlayerToSquad refuses the pick itself: it is the single
// place a player is put into a squad slot (every joinsquad, squad-only pick and AutoJoinSquad goes
// through it - see tug2.games.txt), and returning false leaves the player exactly as they were:
// no class, no loadout, no player_pick_squad. An AutoJoinSquad just moves on to the next free slot.
// The slot's class comes from the theater's team definition, read the way the game reads it in
// CINSPlayer::OnSquadSlotChanged.
//
// FALLBACK. If the gamedata ever stops resolving, the pick goes through and player_pick_squad moves
// the player to spectator instead. The same path handles a player already in a class when they are
// banned from it, or when their stored bans load after they picked.

void SetupClassHooks()
{
    GameData conf = new GameData("tug2.games");
    if (conf == null)
    {
        LogError("tug2.games gamedata missing - class picks cannot be blocked, only undone after the fact");
        return;
    }

    // TheaterDirector: see gg2_theater_items for why this send proxy is the way to read it.
    StartPrepSDKCall(SDKCall_Static);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "SendProxy_TheaterDirector"))
    {
        for (int i = 0; i < 5; i++) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hGetTheaterDirector = EndPrepSDKCall();
    }

    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CTheaterTeamDefinitions::GetDefinitionByTeamNumber"))
    {
        PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hGetTeamDefinition = EndPrepSDKCall();
    }

    // Kept for the plugin's lifetime: deleting the handle would remove the detour.
    static DynamicDetour detour = null;
    if (g_hGetTheaterDirector != null && g_hGetTeamDefinition != null)
    {
        detour = DynamicDetour.FromConf(conf, "CPlayTeam::AddPlayerToSquad");
        g_bClassPickHooked = detour != null && detour.Enable(Hook_Pre, Detour_AddPlayerToSquad);
    }

    if (!g_bClassPickHooked)
        LogError("Could not hook class picks - banned classes are undone by moving the player to spectator instead");

    delete conf;
}

public MRESReturn Detour_AddPlayerToSquad(Address team, DHookReturn hReturn, DHookParam hParams)
{
    int client = hParams.Get(1);
    if (client < 1 || client > MaxClients || g_ClassBans[client] == null || !IsClientInGame(client) || IsFakeClient(client))
        return MRES_Ignored;

    char className[MAX_CLASS_NAME], title[MAX_SLOT_TITLE];
    if (!GetSlotClass(GetClientTeam(client), hParams.Get(2), hParams.Get(3), className, sizeof(className), title, sizeof(title)))
        return MRES_Ignored;

    ClassBan ban;
    if (!FindClassBan(client, className, ban)) return MRES_Ignored;

    NotifyClassRefused(client, title, ban);
    hReturn.Value = false;
    return MRES_Supercede;
}

void NotifyClassRefused(int client, const char[] title, ClassBan ban)
{
    // AutoJoinSquad can refuse several slots in one go; one message is enough.
    float now = GetGameTime();
    if (now - g_fLastClassRefusal[client] < 1.0 && g_fLastClassRefusal[client] != 0.0) return;
    g_fLastClassRefusal[client] = now;

    char label[MAX_SLOT_TITLE], details[MAX_REASON_BYTES + 64];
    FormatClassLabel(title, ban.className, label, sizeof(label));
    FormatClassBanDetails(ban, details, sizeof(details));

    PrintToChat(client, "[SM] You are banned from %s%s. Pick another class.", label, details);
    PrintCenterText(client, "You are banned from %s - pick another class", label);

    // A player with no class yet is left on the selection screen's empty state; ask the client to
    // reopen it. changesquad is the client's own command for that menu.
    if (g_szCurrentClass[client][0] == '\0')
        RequestFrame(Frame_ReopenSquadMenu, GetClientUserId(client));
}

public void Frame_ReopenSquadMenu(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client != 0 && IsClientInGame(client))
        ClientCommand(client, "changesquad");
}

// ------------------------------------------------------------
// Fallback and already-in-class enforcement
// ------------------------------------------------------------

public void Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client == 0) return;

    event.GetString("class_template", g_szCurrentClass[client], sizeof(g_szCurrentClass[]));
    EnforceCurrentClass(client);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    // A team change drops the class; the next pick sets it again.
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client != 0)
        g_szCurrentClass[client][0] = '\0';
}

// Moves the player to spectator if they are in a class they are banned from. Deferred a frame:
// this runs from inside player_pick_squad, i.e. from inside JoinSquad, which is not the place to
// change the player's team.
void EnforceCurrentClass(int client)
{
    if (g_ClassBans[client] == null || g_szCurrentClass[client][0] == '\0') return;

    ClassBan ban;
    if (FindClassBan(client, g_szCurrentClass[client], ban))
        RequestFrame(Frame_EnforceCurrentClass, GetClientUserId(client));
}

public void Frame_EnforceCurrentClass(any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client)) return;

    ClassBan ban;
    if (g_szCurrentClass[client][0] == '\0' || !FindClassBan(client, g_szCurrentClass[client], ban)) return;

    char label[MAX_SLOT_TITLE], details[MAX_REASON_BYTES + 64];
    GetClassLabel(ban.className, label, sizeof(label));
    FormatClassBanDetails(ban, details, sizeof(details));

    LogMessage("Moving %L to spectator: banned from %s", client, ban.className);
    ChangeClientTeam(client, TEAM_SPECTATOR);
    PrintToChat(client, "[SM] You were moved to spectator: you are banned from %s%s. Rejoin and pick another class.", label, details);
}

// ------------------------------------------------------------
// Per-player state
// ------------------------------------------------------------

// Adds or replaces the player's ban from that class.
void SetClientClassBan(int client, ClassBan ban)
{
    if (g_ClassBans[client] == null)
        g_ClassBans[client] = new ArrayList(sizeof(ClassBan));

    RemoveClientClassBan(client, ban.className);
    g_ClassBans[client].PushArray(ban);
}

void RemoveClientClassBan(int client, const char[] className)
{
    if (g_ClassBans[client] == null) return;

    ClassBan ban;
    for (int i = g_ClassBans[client].Length - 1; i >= 0; i--)
    {
        g_ClassBans[client].GetArray(i, ban);
        if (StrEqual(ban.className, className, false))
            g_ClassBans[client].Erase(i);
    }
}

// Drops expired entries on the way.
bool FindClassBan(int client, const char[] className, ClassBan found)
{
    if (g_ClassBans[client] == null) return false;

    int  now = GetTime();
    bool hit = false;
    ClassBan ban;
    for (int i = g_ClassBans[client].Length - 1; i >= 0; i--)
    {
        g_ClassBans[client].GetArray(i, ban);
        if (ban.expires != 0 && ban.expires <= now)
        {
            g_ClassBans[client].Erase(i);
            continue;
        }
        if (!hit && StrEqual(ban.className, className, false))
        {
            found = ban;
            hit   = true;
        }
    }
    return hit;
}

// ------------------------------------------------------------
// Theater team definitions
// ------------------------------------------------------------

enum struct TheaterClass
{
    char className[MAX_CLASS_NAME];
    char title[MAX_SLOT_TITLE];
}

Address GetTeamDefinition(int team)
{
    if (g_hGetTheaterDirector == null || g_hGetTeamDefinition == null) return Address_Null;

    Address director = view_as<Address>(SDKCall(g_hGetTheaterDirector, 0, 0, 0, 0, 0));
    if (director == Address_Null) return Address_Null;

    Address teamDefs = view_as<Address>(ReadInt(director, 0x28));
    if (teamDefs == Address_Null) return Address_Null;

    return view_as<Address>(SDKCall(g_hGetTeamDefinition, teamDefs, team));
}

// The class template (and slot title) a squad slot hands out on that team. False for an index the
// theater does not have, or before a theater is loaded.
bool GetSlotClass(int team, int squad, int slot, char[] className, int classLen, char[] title, int titleLen)
{
    Address teamDef = GetTeamDefinition(team);
    if (teamDef == Address_Null) return false;

    if (squad < 0 || squad >= ReadInt(teamDef, 0x4b4)) return false;
    Address squadDef = view_as<Address>(ReadInt(teamDef, 0x4a8) + squad * 0x90);

    if (slot < 0 || slot >= ReadInt(squadDef, 0x2c)) return false;
    Address slotDef = view_as<Address>(ReadInt(squadDef, 0x20) + slot * 0x54);

    Address namePtr = view_as<Address>(ReadInt(slotDef, 0x50));
    if (namePtr == Address_Null) return false;

    ReadCString(namePtr, className, classLen);
    ReadCString(slotDef, title, titleLen);
    return className[0] != '\0';
}

// Every class the current theater's play teams hand out, one entry per template. Empty when the
// theater cannot be read. The caller deletes it.
ArrayList GetTheaterClasses()
{
    ArrayList classes = new ArrayList(sizeof(TheaterClass));
    TheaterClass entry;

    for (int team = 2; team <= 3; team++)
    {
        Address teamDef = GetTeamDefinition(team);
        if (teamDef == Address_Null) continue;

        int squads = ReadInt(teamDef, 0x4b4);
        for (int squad = 0; squad < squads; squad++)
        {
            Address squadDef = view_as<Address>(ReadInt(teamDef, 0x4a8) + squad * 0x90);
            int slots = ReadInt(squadDef, 0x2c);
            for (int slot = 0; slot < slots; slot++)
            {
                if (!GetSlotClass(team, squad, slot, entry.className, sizeof(entry.className), entry.title, sizeof(entry.title)))
                    continue;
                if (FindTheaterClass(classes, entry.className) == -1)
                    classes.PushArray(entry);
            }
        }
    }
    return classes;
}

int FindTheaterClass(ArrayList classes, const char[] className)
{
    TheaterClass entry;
    for (int i = 0; i < classes.Length; i++)
    {
        classes.GetArray(i, entry);
        if (StrEqual(entry.className, className, false)) return i;
    }
    return -1;
}

int ReadInt(Address base, int offset)
{
    return LoadFromAddress(base + view_as<Address>(offset), NumberType_Int32);
}

void ReadCString(Address p, char[] out, int maxlen)
{
    int i = 0;
    for (; i < maxlen - 1; i++)
    {
        int c = LoadFromAddress(p + view_as<Address>(i), NumberType_Int8) & 0xFF;
        if (c == 0) break;
        out[i] = c;
    }
    out[i] = '\0';
}

// ------------------------------------------------------------
// Names
// ------------------------------------------------------------

// "#Squad_Fireteam_WeaponsSgt" -> "Fireteam WeaponsSgt"; falls back to the template name.
void FormatClassLabel(const char[] title, const char[] className, char[] out, int maxlen)
{
    if (title[0] == '\0')
    {
        strcopy(out, maxlen, className);
        return;
    }

    int start = (title[0] == '#') ? 1 : 0;
    if (strncmp(title[start], "Squad_", 6, false) == 0) start += 6;
    strcopy(out, maxlen, title[start]);
    ReplaceString(out, maxlen, "_", " ");
}

// The label for a template, via its slot in the current theater if it has one.
void GetClassLabel(const char[] className, char[] out, int maxlen)
{
    ArrayList classes = GetTheaterClasses();
    int index = FindTheaterClass(classes, className);

    TheaterClass entry;
    if (index != -1)
        classes.GetArray(index, entry);
    else
        entry.title[0] = '\0';
    delete classes;

    FormatClassLabel(entry.title, className, out, maxlen);
}

// " for another 1d 2h (reason)", " permanently (reason)".
void FormatClassBanDetails(ClassBan ban, char[] out, int maxlen)
{
    int minutes = MinutesUntil(ban.expires);
    if (minutes > 0)
    {
        char duration[64];
        FormatBanDuration(minutes, duration, sizeof(duration));
        Format(out, maxlen, " for another %s", duration);
    }
    else
        strcopy(out, maxlen, " permanently");

    if (ban.reason[0] != '\0')
        Format(out, maxlen, "%s (%s)", out, ban.reason);
}

// Turns what an admin typed into a class template name: an exact template name, or text found in
// exactly one of the current theater's template names or slot titles ("medic", "sgt"). A full
// "template_..." name is taken as is even when this theater lacks it - the ban still applies on
// maps whose theater has that class.
bool ResolveClassArg(int admin, const char[] text, char[] out, int maxlen)
{
    ArrayList classes = GetTheaterClasses();
    TheaterClass entry;

    int  matches = 0;
    char list[256];
    list[0] = '\0';

    for (int i = 0; i < classes.Length; i++)
    {
        classes.GetArray(i, entry);
        if (StrEqual(entry.className, text, false))
        {
            strcopy(out, maxlen, entry.className);
            delete classes;
            return true;
        }
        if (StrContains(entry.className, text, false) == -1 && StrContains(entry.title, text, false) == -1)
            continue;

        if (++matches == 1)
            strcopy(out, maxlen, entry.className);
        Format(list, sizeof(list), "%s%s%s", list, list[0] != '\0' ? ", " : "", entry.className);
    }
    delete classes;

    if (matches == 1) return true;

    if (matches > 1)
    {
        ReplyToCommand(admin, "[SM] \"%s\" matches more than one class: %s", text, list);
        return false;
    }

    if (strncmp(text, "template_", 9, false) == 0 && strlen(text) < maxlen)
    {
        strcopy(out, maxlen, text);
        return true;
    }

    ReplyToCommand(admin, "[SM] No class in the current theater matches \"%s\". Any part of a name below works:", text);
    PrintTheaterClasses(admin);
    ReplyToCommand(admin, "[SM] For a class this theater does not have, give its full template_ name.");
    return false;
}

// ------------------------------------------------------------
// Commands
// ------------------------------------------------------------

public Action Command_BanClass(int client, int args)
{
    char target[MAX_TARGET_LENGTH], classArg[MAX_CLASS_NAME], minutesArg[16], reason[MAX_REASON_BYTES];
    GetClassBanArgs(target, sizeof(target), classArg, sizeof(classArg), minutesArg, sizeof(minutesArg), reason, sizeof(reason));
    if (target[0] == '\0' || classArg[0] == '\0' || !IsDigitString(minutesArg))
    {
        ReplyToCommand(client, "[SM] Usage: sm_banclass <#userid|name|steamid> <class> <minutes|0> [reason]");
        return Plugin_Handled;
    }

    char className[MAX_CLASS_NAME];
    if (ResolveClassArg(client, classArg, className, sizeof(className)))
        ApplyClassBanCommand(client, target, className, true, StringToInt(minutesArg), reason);
    return Plugin_Handled;
}

public Action Command_UnbanClass(int client, int args)
{
    char target[MAX_TARGET_LENGTH], classArg[MAX_CLASS_NAME], unused[16], unusedReason[16];
    GetClassBanArgs(target, sizeof(target), classArg, sizeof(classArg), unused, sizeof(unused), unusedReason, sizeof(unusedReason));
    if (target[0] == '\0' || classArg[0] == '\0')
    {
        ReplyToCommand(client, "[SM] Usage: sm_unbanclass <#userid|name|steamid> <class>");
        return Plugin_Handled;
    }

    char className[MAX_CLASS_NAME];
    if (ResolveClassArg(client, classArg, className, sizeof(className)))
        ApplyClassBanCommand(client, target, className, false, 0, "");
    return Plugin_Handled;
}

public Action Command_Classes(int client, int args)
{
    PrintTheaterClasses(client);

    if (!g_bClassPickHooked)
        ReplyToCommand(client, "[SM] Class picks are not hooked: banned classes are undone by moving the player to spectator.");
    return Plugin_Handled;
}

// One line per class: "Combat Medic - template_combat_medic".
void PrintTheaterClasses(int client)
{
    ArrayList classes = GetTheaterClasses();
    if (classes.Length == 0)
        ReplyToCommand(client, "[SM] Could not read the theater's classes%s.", g_bClassPickHooked ? "" : " (gamedata did not resolve)");

    TheaterClass entry;
    char label[MAX_SLOT_TITLE];
    for (int i = 0; i < classes.Length; i++)
    {
        classes.GetArray(i, entry);
        FormatClassLabel(entry.title, entry.className, label, sizeof(label));
        ReplyToCommand(client, "[SM] %s - %s", label, entry.className);
    }
    delete classes;
}

// <target> <class> <minutes> [reason...], split with BreakString like sm_bancalladmin.
void GetClassBanArgs(char[] target, int targetLen, char[] className, int classLen, char[] minutes, int minutesLen, char[] reason, int reasonLen)
{
    char args[MAX_REASON_BYTES];
    GetCmdArgString(args, sizeof(args));

    target[0]    = '\0';
    className[0] = '\0';
    minutes[0]   = '\0';
    reason[0]    = '\0';

    int pos = BreakString(args, target, targetLen);
    if (pos == -1) return;

    int next = BreakString(args[pos], className, classLen);
    if (next == -1) return;
    pos += next;

    next = BreakString(args[pos], minutes, minutesLen);
    if (next == -1) return;

    CleanBanReason(args[pos + next], reason, reasonLen);
}

// The target is a SteamID in any form (the player may be offline), or a name / #userid / group.
void ApplyClassBanCommand(int admin, const char[] target, const char[] className, bool ban, int minutes, const char[] reason)
{
    char label[MAX_SLOT_TITLE], details[MAX_REASON_BYTES + 64];
    GetClassLabel(className, label, sizeof(label));
    FormatBanDetails(ban, minutes, reason, details, sizeof(details));

    char steamid64[32];
    if (SteamIdTo64(target, steamid64, sizeof(steamid64)))
    {
        int  online  = FindClientBySteamId64(steamid64);
        bool allowed = (online != 0) ? CanUserTarget(admin, online)
                                     : (admin == 0 || CanAdminTarget(GetUserAdmin(admin), FindAdminByIdentity("steam", target)));
        if (!allowed)
        {
            ReplyToCommand(admin, "[SM] %t", "Unable to target");
            return;
        }

        SetClassBan(admin, steamid64, className, ban, minutes, reason);
        LogAction(admin, online != 0 ? online : -1, "\"%L\" %s %s from class \"%s\"%s", admin, ban ? "banned" : "unbanned", target, className, details);
        PostClassBanToDiscord(admin, target, ban, label, details);
        ShowActivity2(admin, "[SM] ", "%s %s from %s%s.", ban ? "Banned" : "Unbanned", target, label, details);
        return;
    }

    int  targets[MAXPLAYERS];
    char targetName[MAX_TARGET_LENGTH];
    bool tnIsMl;
    int  count = ProcessTargetString(target, admin, targets, sizeof(targets), COMMAND_FILTER_NO_BOTS,
                                     targetName, sizeof(targetName), tnIsMl);
    if (count <= 0)
    {
        ReplyToTargetError(admin, count);
        return;
    }

    for (int i = 0; i < count; i++)
        ClassBanClient(admin, targets[i], className, ban, minutes, reason);

    if (tnIsMl)
        ShowActivity2(admin, "[SM] ", "%s %t from %s%s.", ban ? "Banned" : "Unbanned", targetName, label, details);
    else
        ShowActivity2(admin, "[SM] ", "%s %s from %s%s.", ban ? "Banned" : "Unbanned", targetName, label, details);
}

// One connected player, from a command or the admin menu. False, with a reply, when they have no
// SteamID yet.
bool ClassBanClient(int admin, int target, const char[] className, bool ban, int minutes, const char[] reason)
{
    char steamid64[32];
    if (!GetClientAuthId(target, AuthId_SteamID64, steamid64, sizeof(steamid64)))
    {
        ReplyToCommand(admin, "[SM] %N has no SteamID yet, not changed.", target);
        return false;
    }

    SetClassBan(admin, steamid64, className, ban, minutes, reason);
    LogAction(admin, target, "\"%L\" %s \"%L\" from class \"%s\" (minutes \"%d\") (reason \"%s\")", admin, ban ? "banned" : "unbanned", target, className, minutes, reason);

    char name[MAX_NAME_LENGTH], label[MAX_SLOT_TITLE], details[MAX_REASON_BYTES + 64];
    GetClientName(target, name, sizeof(name));
    GetClassLabel(className, label, sizeof(label));
    FormatBanDetails(ban, minutes, reason, details, sizeof(details));
    PostClassBanToDiscord(admin, name, ban, label, details);
    return true;
}

// "<admin>: **CLASS BAN:** banned X from Combat Medic for 1d (reason)", when gg2_discord is loaded.
void PostClassBanToDiscord(int admin, const char[] target, bool ban, const char[] label, const char[] details)
{
    if (GetFeatureStatus(FeatureType_Native, "send_to_discord") != FeatureStatus_Available) return;

    char message[MAX_REASON_BYTES + 256];
    Format(message, sizeof(message), "**CLASS %s:** %s %s from %s%s",
           ban ? "BAN" : "UNBAN", ban ? "banned" : "unbanned", target, label, details);
    send_to_discord(admin, message);
}

// Applies to the player now if they are connected (moving them out of the class if they are in
// it), and replaces any stored ban from that class.
void SetClassBan(int admin, const char[] steamid64, const char[] className, bool ban, int minutes, const char[] reason)
{
    int online = FindClientBySteamId64(steamid64);
    if (online != 0)
    {
        if (ban)
        {
            ClassBan entry;
            strcopy(entry.className, sizeof(entry.className), className);
            strcopy(entry.reason, sizeof(entry.reason), reason);
            entry.expires = BanExpiry(minutes);
            SetClientClassBan(online, entry);
            EnforceCurrentClass(online);
        }
        else
            RemoveClientClassBan(online, className);
    }

    char classValue[MAX_CLASS_NAME * 2 + 3];
    SqlQuote(className, classValue, sizeof(classValue));

    // Deactivate first so a re-ban replaces the old row; RunWrite keeps the two in order.
    char query[MAX_QUERY_LENGTH];
    Format(query, sizeof(query),
           "UPDATE punishments SET is_active = FALSE WHERE target_steam_id = %s AND punishment_type = 'class_ban' AND lower(target_class) = lower(%s) AND is_active",
           steamid64, classValue);
    RunWrite(query);

    if (!ban) return;

    char adminValue[32];
    AdminSqlValue(admin, adminValue, sizeof(adminValue));

    char expiresValue[128];
    if (minutes == 0)
        strcopy(expiresValue, sizeof(expiresValue), "NULL");
    else
        Format(expiresValue, sizeof(expiresValue), "CURRENT_TIMESTAMP + INTERVAL '%d minutes'", minutes);

    char reasonValue[MAX_REASON_BYTES * 2 + 3];
    if (reason[0] != '\0')
        SqlQuote(reason, reasonValue, sizeof(reasonValue));
    else
        strcopy(reasonValue, sizeof(reasonValue), "NULL");

    Format(query, sizeof(query),
           "INSERT INTO punishments (punishment_type, target_steam_id, admin_steam_id, reason, expires_at, target_class) VALUES ('class_ban', %s, %s, %s, %s, %s)",
           steamid64, adminValue, reasonValue, expiresValue, classValue);
    RunWrite(query);
}

// ------------------------------------------------------------
// Admin menu - Player Commands > "Ban/unban from a class"
// ------------------------------------------------------------
//
// Player, then class: the current theater's classes, plus any class the player is banned from that
// this theater lacks. A class marked [banned] is unbanned when picked; anything else goes on to a
// length. No reason step, as with the !calladmin menu.

public void AdminMenu_BanClass(TopMenu topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
    if (action == TopMenuAction_DisplayOption)
        strcopy(buffer, maxlength, "Ban/unban from a class");
    else if (action == TopMenuAction_SelectOption)
        DisplayClassTargetMenu(param);
}

void DisplayClassTargetMenu(int client)
{
    Menu menu = new Menu(MenuHandler_ClassTarget);
    menu.SetTitle("Ban/unban from a class:");
    menu.ExitBackButton = true;

    char userid[16], label[MAX_NAME_LENGTH + 24];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || !CanUserTarget(client, i)) continue;

        IntToString(GetClientUserId(i), userid, sizeof(userid));
        int bans = (g_ClassBans[i] != null) ? g_ClassBans[i].Length : 0;
        if (bans > 0)
            Format(label, sizeof(label), "%N [%d class ban%s]", i, bans, bans == 1 ? "" : "s");
        else
            Format(label, sizeof(label), "%N", i);
        menu.AddItem(userid, label);
    }

    if (menu.ItemCount == 0)
        menu.AddItem("", "No players", ITEMDRAW_DISABLED);

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClassTarget(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack && g_hAdminMenu != null)
            g_hAdminMenu.Display(param1, TopMenuPosition_LastCategory);
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        g_iMenuClassTargetUserId[param1] = StringToInt(info);

        if (MenuTargetOrReply(param1, g_iMenuClassTargetUserId[param1]) != 0)
            DisplayClassListMenu(param1);
        else
            DisplayClassTargetMenu(param1);
    }
    return 0;
}

void DisplayClassListMenu(int client)
{
    int target = GetClientOfUserId(g_iMenuClassTargetUserId[client]);
    if (target == 0)
    {
        DisplayClassTargetMenu(client);
        return;
    }

    Menu menu = new Menu(MenuHandler_ClassList);
    menu.SetTitle("Class for %N:", target);
    menu.ExitBackButton = true;

    ArrayList classes = GetTheaterClasses();
    TheaterClass entry;
    ClassBan ban;
    char label[MAX_SLOT_TITLE + 16];

    for (int i = 0; i < classes.Length; i++)
    {
        classes.GetArray(i, entry);
        FormatClassLabel(entry.title, entry.className, label, sizeof(label));
        if (FindClassBan(target, entry.className, ban))
            StrCat(label, sizeof(label), " [banned]");
        menu.AddItem(entry.className, label);
    }

    // Bans from classes this theater does not have - still listed, so they can be lifted here.
    if (g_ClassBans[target] != null)
    {
        for (int i = 0; i < g_ClassBans[target].Length; i++)
        {
            g_ClassBans[target].GetArray(i, ban);
            if (FindTheaterClass(classes, ban.className) != -1) continue;
            Format(label, sizeof(label), "%s [banned]", ban.className);
            menu.AddItem(ban.className, label);
        }
    }

    if (classes.Length == 0)
        menu.AddItem("", "Class list unavailable - use sm_banclass", ITEMDRAW_DISABLED);
    delete classes;

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClassList(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
            DisplayClassTargetMenu(param1);
    }
    else if (action == MenuAction_Select)
    {
        char className[MAX_CLASS_NAME];
        menu.GetItem(param2, className, sizeof(className));

        int target = MenuTargetOrReply(param1, g_iMenuClassTargetUserId[param1]);
        if (target == 0)
        {
            DisplayClassTargetMenu(param1);
            return 0;
        }

        ClassBan ban;
        if (FindClassBan(target, className, ban))
        {
            ApplyClassBanFromMenu(param1, target, className, false, 0);
            DisplayClassListMenu(param1);
        }
        else
        {
            strcopy(g_szMenuClass[param1], sizeof(g_szMenuClass[]), className);
            DisplayClassLengthMenu(param1);
        }
    }
    return 0;
}

void DisplayClassLengthMenu(int client)
{
    char label[MAX_SLOT_TITLE];
    GetClassLabel(g_szMenuClass[client], label, sizeof(label));

    Menu menu = new Menu(MenuHandler_ClassLength);
    menu.SetTitle("Ban from %s for:", label);
    menu.ExitBackButton = true;

    menu.AddItem("0", "Permanently");
    menu.AddItem("1440", "1 day");
    menu.AddItem("10080", "1 week");
    menu.AddItem("43200", "30 days");

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClassLength(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
            DisplayClassListMenu(param1);
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        int target = MenuTargetOrReply(param1, g_iMenuClassTargetUserId[param1]);
        if (target != 0)
        {
            ApplyClassBanFromMenu(param1, target, g_szMenuClass[param1], true, StringToInt(info));
            DisplayClassListMenu(param1);
        }
        else
            DisplayClassTargetMenu(param1);
    }
    return 0;
}

void ApplyClassBanFromMenu(int admin, int target, const char[] className, bool ban, int minutes)
{
    char label[MAX_SLOT_TITLE], details[64];
    GetClassLabel(className, label, sizeof(label));
    FormatBanDetails(ban, minutes, "", details, sizeof(details));

    // Replies from the shared code go to chat: the menu has no command of its own to reply to.
    ReplySource previous = SetCmdReplySource(SM_REPLY_TO_CHAT);
    if (ClassBanClient(admin, target, className, ban, minutes, ""))
        ShowActivity2(admin, "[SM] ", "%s %N from %s%s.", ban ? "Banned" : "Unbanned", target, label, details);
    SetCmdReplySource(previous);
}

// ============================================================
// BAN MESSAGES
// ============================================================

// "Banned for 1d 8h" (on the ban), "Banned - 23h 12m remaining" (on a later connect), or
// "Permanently banned", then ". Reason: <reason>".
// minutes 0 = permanent.
//
// Fits maxlen, which callers cap at KICK_MESSAGE_BYTES. The duration is never cut: the reason is
// trimmed to what is left, on a UTF-8 character boundary, with "..." to show it was cut, and left
// out entirely when too little room remains for it to say anything.
void BuildBanMessage(int minutes, bool remaining, const char[] reason, char[] out, int maxlen)
{
    if (minutes == 0)
        strcopy(out, maxlen, "Permanently banned");
    else
    {
        char duration[64];
        FormatBanDuration(minutes, duration, sizeof(duration));
        if (remaining)
            Format(out, maxlen, "Banned - %s remaining", duration);
        else
            Format(out, maxlen, "Banned for %s", duration);
    }

    // basebans passes the literal "Banned" when the admin gave no reason.
    if (reason[0] == '\0' || StrEqual(reason, "Banned", false)) return;

    static const char separator[] = ". Reason: ";
    int room = maxlen - 1 - strlen(out) - (sizeof(separator) - 1);
    if (room < 16) return;

    StrCat(out, maxlen, separator);

    int len = strlen(reason);
    if (len <= room)
    {
        StrCat(out, maxlen, reason);
        return;
    }

    // Back off to the start of a character so a multi-byte one is not split.
    int cut = room - 3;
    while (cut > 0 && (reason[cut] & 0xC0) == 0x80) cut--;

    int end = strlen(out);
    for (int i = 0; i < cut; i++)
        out[end + i] = reason[i];
    out[end + cut] = '\0';
    StrCat(out, maxlen, "...");
}

// Compact duration: 1440 -> "1d", 2042 -> "1d 10h 2m", 90 -> "1h 30m". Zero units are left out;
// a year is 365 days.
void FormatBanDuration(int minutes, char[] out, int maxlen)
{
    int years = minutes / 525600;
    minutes %= 525600;
    int days = minutes / 1440;
    minutes %= 1440;
    int hours = minutes / 60;
    minutes %= 60;

    out[0] = '\0';
    AppendDurationUnit(out, maxlen, years, "y");
    AppendDurationUnit(out, maxlen, days, "d");
    AppendDurationUnit(out, maxlen, hours, "h");
    AppendDurationUnit(out, maxlen, minutes, "m");
}

void AppendDurationUnit(char[] out, int maxlen, int value, const char[] unit)
{
    if (value == 0) return;
    Format(out, maxlen, "%s%s%d%s", out, out[0] != '\0' ? " " : "", value, unit);
}

// ============================================================
// DATABASE OPERATIONS
// ============================================================

void AddBanToDatabase(const char[] adminSteamId, const char[] targetSteamID, const char[] targetIP, const char[] reason, int minutes, const char[] punishmentType)
{
    bool hasIP    = (strlen(targetIP) > 0);

    char adminValue[32];
    SteamIdSqlValue(adminSteamId, adminValue, sizeof(adminValue));

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
    // In minutes, as given: converting to seconds first overflowed an int for bans over ~68 years
    // and stored them as already expired.
    if (minutes == 0)
        strcopy(expiresValue, sizeof(expiresValue), "NULL");
    else
        Format(expiresValue, sizeof(expiresValue), "CURRENT_TIMESTAMP + INTERVAL '%d minutes'", minutes);

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
// in gg2_messages, gg2_forceretry and clientprefs). Punishments are written rarely, so the
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
    GetAdminSteamId(client, steamid, sizeof(steamid));
    SteamIdSqlValue(steamid, out, maxlen);
}

// A SteamID64 as a SQL value; "" becomes NULL.
void SteamIdSqlValue(const char[] steamid, char[] out, int maxlen)
{
    strcopy(out, maxlen, steamid[0] != '\0' ? steamid : "NULL");
}

// The admin's SteamID64, or "" for the console or an admin with no SteamID yet.
void GetAdminSteamId(int client, char[] out, int maxlen)
{
    if (client < 1 || !GetClientAuthId(client, AuthId_SteamID64, out, maxlen))
        out[0] = '\0';
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
