#include <sourcemod>
#include <adminmenu>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION    "1.0.0"
#define MAX_REASON_LENGTH 255

// Database handle
Database g_Database = null;

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

    // Register admin commands
    RegAdminCmd("sm_addban", Command_AddBan, ADMFLAG_BAN, "Ban a player by SteamID");
    RegAdminCmd("sm_banip", Command_BanIP, ADMFLAG_BAN, "Ban a player by IP address");
    RegAdminCmd("sm_unban", Command_Unban, ADMFLAG_UNBAN, "Unban a player by SteamID or IP");

    RegAdminCmd("sm_gag", Command_Gag, ADMFLAG_CHAT, "Gag a player (block voice)");
    RegAdminCmd("sm_mute", Command_Mute, ADMFLAG_CHAT, "Mute a player (block text chat)");
    RegAdminCmd("sm_silence", Command_Silence, ADMFLAG_CHAT, "Silence a player (block both voice and text)");

    RegAdminCmd("sm_ungag", Command_Ungag, ADMFLAG_CHAT, "Remove gag from a player");
    RegAdminCmd("sm_unmute", Command_Unmute, ADMFLAG_CHAT, "Remove mute from a player");
    RegAdminCmd("sm_unsilence", Command_Unsilence, ADMFLAG_CHAT, "Remove silence from a player");

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
}

// Attempt to reconnect to the database
void ReconnectDatabase()
{
    LogMessage("Attempting to reconnect to database...");
    g_Database = null;
    Database.Connect(OnDatabaseReconnected, "punitive-persistence");
}

public void OnDatabaseReconnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Failed to reconnect to database: %s", error);
        // Try again after a delay
        CreateTimer(5.0, Timer_RetryReconnect);
        return;
    }

    g_Database = db;
    LogMessage("Successfully reconnected to database");
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
    if (IsFakeClient(client) || g_Database == null) return;

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
        if (StrContains(error, "no connection to the server", false) != -1)
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
            BaseComm_SetClientGag(client, true);
        }
        else if (StrEqual(punishmentType, "mute"))
        {
            muted = true;
            BaseComm_SetClientMute(client, true);
        }
        else if (StrEqual(punishmentType, "silence"))
        {
            gagged = true;
            muted  = true;
            BaseComm_SetClientGag(client, true);
            BaseComm_SetClientMute(client, true);
        }
    }

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
// COMMAND: sm_addban
// ============================================================
public Action Command_AddBan(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[SM] Usage: sm_addban <time> <steamid> [reason]");
        return Plugin_Handled;
    }

    char timeStr[32], steamid[32], reason[MAX_REASON_LENGTH];
    GetCmdArg(1, timeStr, sizeof(timeStr));
    GetCmdArg(2, steamid, sizeof(steamid));

    if (args >= 3)
        GetCmdArgString(reason, sizeof(reason));

    // Remove first two arguments from reason string
    int pos = StrContains(reason, steamid);
    if (pos != -1)
    {
        pos += strlen(steamid);
        while (pos < strlen(reason) && reason[pos] == ' ')
            pos++;

        strcopy(reason, sizeof(reason), reason[pos]);
        TrimString(reason);
    }

    // Parse time
    int duration = ParseTimeString(timeStr);
    if (duration < 0)
    {
        ReplyToCommand(client, "[SM] Invalid time format. Use: 0 (permanent), 30m, 2h, 5d, etc.");
        return Plugin_Handled;
    }

    // Validate SteamID format
    if (!IsValidSteamID(steamid))
    {
        ReplyToCommand(client, "[SM] Invalid SteamID format");
        return Plugin_Handled;
    }

    // Check if player is online
    int target = FindClientBySteamID(steamid);
    if (target > 0)
    {
        // Check immunity
        if (client != 0 && !CanUserTarget(client, target))
        {
            ReplyToCommand(client, "[SM] You cannot target this player");
            return Plugin_Handled;
        }

        // Kick the player first
        KickClient(target, "You have been banned from this server");
    }

    // Add ban to database
    AddBanToDatabase(client, steamid, "", reason, duration, "ban_steamid");

    if (duration == 0)
        ReplyToCommand(client, "[SM] Permanently banned %s", steamid);
    else
        ReplyToCommand(client, "[SM] Banned %s for %s", steamid, timeStr);

    return Plugin_Handled;
}

// ============================================================
// COMMAND: sm_banip
// ============================================================
public Action Command_BanIP(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[SM] Usage: sm_banip <ip|#userid|name> <time> [reason]");
        return Plugin_Handled;
    }

    char targetArg[128], timeStr[32], reason[MAX_REASON_LENGTH];
    GetCmdArg(1, targetArg, sizeof(targetArg));
    GetCmdArg(2, timeStr, sizeof(timeStr));

    if (args >= 3)
        GetCmdArgString(reason, sizeof(reason));

    // Remove first two arguments from reason string
    int pos = StrContains(reason, timeStr);
    if (pos != -1)
    {
        pos += strlen(timeStr);
        while (pos < strlen(reason) && reason[pos] == ' ')
            pos++;

        strcopy(reason, sizeof(reason), reason[pos]);
        TrimString(reason);
    }

    // Parse time
    int duration = ParseTimeString(timeStr);
    if (duration < 0)
    {
        ReplyToCommand(client, "[SM] Invalid time format. Use: 0 (permanent), 30m, 2h, 5d, etc.");
        return Plugin_Handled;
    }

    char ip[64], steamid[32];
    int  target = -1;

    // Check if it's a direct IP address
    if (IsValidIP(targetArg))
    {
        strcopy(ip, sizeof(ip), targetArg);
    }
    else
    {
        // Try to find player by target
        target = FindTargetByString(targetArg);

        if (target == -1)
        {
            ReplyToCommand(client, "[SM] Target not found");
            return Plugin_Handled;
        }

        // Check immunity
        if (client != 0 && !CanUserTarget(client, target))
        {
            ReplyToCommand(client, "[SM] You cannot target this player");
            return Plugin_Handled;
        }

        if (!GetClientIP(target, ip, sizeof(ip)))
        {
            ReplyToCommand(client, "[SM] Could not retrieve IP address of target");
            return Plugin_Handled;
        }

        if (!GetClientAuthId(target, AuthId_SteamID64, steamid, sizeof(steamid)))
        {
            ReplyToCommand(client, "[SM] Could not retrieve SteamID of target");
            return Plugin_Handled;
        }

        // Kick the player
        KickClient(target, "You have been IP banned from this server");
    }

    // Add IP ban to database
    AddBanToDatabase(client, steamid, ip, reason, duration, "ban_ip");

    if (duration == 0)
        ReplyToCommand(client, "[SM] Permanently IP banned %s", ip);
    else
        ReplyToCommand(client, "[SM] IP banned %s for %s", ip, timeStr);

    return Plugin_Handled;
}

// ============================================================
// COMMAND: sm_unban
// ============================================================
public Action Command_Unban(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_unban <steamid|ip>");
        return Plugin_Handled;
    }

    char target[128];
    GetCmdArg(1, target, sizeof(target));

    // Determine if it's a SteamID or IP
    bool isIP      = IsValidIP(target);
    bool isSteamID = IsValidSteamID(target);

    if (!isIP && !isSteamID)
    {
        ReplyToCommand(client, "[SM] Invalid SteamID or IP format");
        return Plugin_Handled;
    }

    // Remove ban from database
    RemoveBanFromDatabase(target, isIP);

    ReplyToCommand(client, "[SM] Unbanned %s", target);

    return Plugin_Handled;
}

// ============================================================
// COMMANDS: Communication Restrictions
// ============================================================
public Action Command_Gag(int client, int args)
{
    return HandleCommPunishment(client, args, "gag", "gagged");
}

public Action Command_Mute(int client, int args)
{
    return HandleCommPunishment(client, args, "mute", "muted");
}

public Action Command_Silence(int client, int args)
{
    return HandleCommPunishment(client, args, "silence", "silenced");
}

Action HandleCommPunishment(int requesterClient, int args, const char[] punishmentType, const char[] actionName)
{
    if (args < 1)
    {
        ReplyToCommand(requesterClient, "[SM] Usage: sm_%s <target>", punishmentType);
        return Plugin_Handled;
    }

    char targetArg[128];
    GetCmdArg(1, targetArg, sizeof(targetArg));

    int targetClient = FindTargetByString(targetArg);

    if (targetClient == -1)
    {
        ReplyToCommand(requesterClient, "[SM] Target not found");
        return Plugin_Handled;
    }

    if (IsFakeClient(targetClient))
    {
        ReplyToCommand(requesterClient, "[SM] Cannot target bots");
        return Plugin_Handled;
    }

    // Check immunity
    if (requesterClient != 0 && !CanUserTarget(requesterClient, targetClient))
    {
        ReplyToCommand(requesterClient, "[SM] You cannot target this player");
        return Plugin_Handled;
    }

    // Apply the punishment
    bool success = false;

    if (StrEqual(punishmentType, "gag"))
    {
        success = BaseComm_SetClientGag(targetClient, true);
    }
    else if (StrEqual(punishmentType, "mute"))
    {
        success = BaseComm_SetClientMute(targetClient, true);
    }
    else if (StrEqual(punishmentType, "silence"))
    {
        BaseComm_SetClientGag(targetClient, true);
        BaseComm_SetClientMute(targetClient, true);
        success = true;
    }

    if (!success)
    {
        ReplyToCommand(requesterClient, "[SM] Failed to apply punishment");
        return Plugin_Handled;
    }

    // Add to database (permanent communication restrictions)
    char targetSteamID[32];
    if (!GetClientAuthId(targetClient, AuthId_SteamID64, targetSteamID, sizeof(targetSteamID)))
    {
        ReplyToCommand(requesterClient, "[SM] Could not retrieve SteamID of target");
        return Plugin_Handled;
    }

    AddCommPunishmentToDatabase(requesterClient, targetSteamID, punishmentType);

    // Log action
    ReplyToCommand(requesterClient, "[SM] %N has been %s", targetClient, actionName);

    return Plugin_Handled;
}

// ============================================================
// COMMANDS: Remove Communication Restrictions
// ============================================================
public Action Command_Ungag(int client, int args)
{
    return HandleCommRemoval(client, args, "gag", "ungagged");
}

public Action Command_Unmute(int client, int args)
{
    return HandleCommRemoval(client, args, "mute", "unmuted");
}

public Action Command_Unsilence(int client, int args)
{
    return HandleCommRemoval(client, args, "silence", "unsilenced");
}

Action HandleCommRemoval(int requesterClient, int args, const char[] punishmentType, const char[] actionName)
{
    if (args < 1)
    {
        ReplyToCommand(requesterClient, "[SM] Usage: sm_un%s <target>", punishmentType);
        return Plugin_Handled;
    }

    char targetArg[128];
    GetCmdArg(1, targetArg, sizeof(targetArg));

    int targetClient = FindTargetByString(targetArg);

    if (targetClient == -1)
    {
        ReplyToCommand(requesterClient, "[SM] Target not found");
        return Plugin_Handled;
    }

    if (IsFakeClient(targetClient))
    {
        ReplyToCommand(requesterClient, "[SM] Cannot target bots");
        return Plugin_Handled;
    }

    // Remove the punishment
    if (StrEqual(punishmentType, "gag"))
    {
        BaseComm_SetClientGag(targetClient, false);
    }
    else if (StrEqual(punishmentType, "mute"))
    {
        BaseComm_SetClientMute(targetClient, false);
    }
    else if (StrEqual(punishmentType, "silence"))
    {
        BaseComm_SetClientGag(targetClient, false);
        BaseComm_SetClientMute(targetClient, false);
    }

    // Remove from database
    char targetSteamID[32];
    GetClientAuthId(targetClient, AuthId_SteamID64, targetSteamID, sizeof(targetSteamID));

    RemoveCommPunishmentFromDatabase(targetSteamID, punishmentType);

    ReplyToCommand(requesterClient, "[SM] %N has been %s", targetClient, actionName);

    return Plugin_Handled;
}

// ============================================================
// DATABASE OPERATIONS
// ============================================================

void AddBanToDatabase(int requesterClient, const char[] targetSteamID, const char[] targetIP, const char[] reason, int duration, const char[] punishmentType)
{
    if (g_Database == null) return;

    char adminSteamID[32];
    bool hasAdmin = (requesterClient != 0);
    bool hasIP    = (strlen(targetIP) > 0);

    if (hasAdmin)
    {
        GetClientAuthId(requesterClient, AuthId_SteamID64, adminSteamID, sizeof(adminSteamID));
    }

    // Build dynamic parts of the query
    char adminValue[32];
    if (hasAdmin)
        g_Database.Format(adminValue, sizeof(adminValue), "'%s'", adminSteamID);
    else
        strcopy(adminValue, sizeof(adminValue), "NULL");

    char ipValue[128];
    if (hasIP)
        g_Database.Format(ipValue, sizeof(ipValue), "'%s'", targetIP);
    else
        strcopy(ipValue, sizeof(ipValue), "NULL");

    char expiresValue[128];
    if (duration == 0)
        strcopy(expiresValue, sizeof(expiresValue), "NULL");
    else
        Format(expiresValue, sizeof(expiresValue), "CURRENT_TIMESTAMP + INTERVAL '%d seconds'", duration);

    // Build query
    char query[1024];
    g_Database.Format(query, sizeof(query),
                      "INSERT INTO punishments (punishment_type, target_steam_id, target_ip, admin_steam_id, reason, expires_at) VALUES ('%s', %s, %!s, %!s, '%s', %!s)",
                      punishmentType, targetSteamID, ipValue, adminValue, reason, expiresValue);

    g_Database.Query(OnBanAdded, query);
}

public void OnBanAdded(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("Failed to add ban to database: %s", error);
}

void RemoveBanFromDatabase(const char[] target, bool isTargetIP)
{
    if (g_Database == null)
        return;

    // Build WHERE clause with proper escaping
    char whereClause[256];
    if (isTargetIP)
        g_Database.Format(whereClause, sizeof(whereClause), "target_ip = '%s'", target);
    else
        g_Database.Format(whereClause, sizeof(whereClause), "target_steam_id = %s", target);

    // Build query
    char query[512];
    g_Database.Format(query, sizeof(query),
                      "UPDATE punishments SET is_active = FALSE WHERE %!s AND punishment_type = '%s'",
                      whereClause, isTargetIP ? "ban_ip" : "ban_steamid");

    g_Database.Query(OnBanRemoved, query);
}

public void OnBanRemoved(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("Failed to remove ban from database: %s", error);
}

void AddCommPunishmentToDatabase(int admin, const char[] targetSteamID, const char[] punishmentType)
{
    if (g_Database == null)
        return;

    char adminSteamID[32];
    bool hasAdmin = (admin != 0);

    if (hasAdmin)
    {
        GetClientAuthId(admin, AuthId_SteamID64, adminSteamID, sizeof(adminSteamID));
    }

    // Build dynamic parts of the query
    char adminValue[32];
    if (hasAdmin)
        g_Database.Format(adminValue, sizeof(adminValue), "'%s'", adminSteamID);
    else
        strcopy(adminValue, sizeof(adminValue), "NULL");

    // Permanent communication punishment (no expiration)
    char query[1024];
    g_Database.Format(query, sizeof(query),
                      "INSERT INTO punishments (punishment_type, target_steam_id, admin_steam_id, expires_at) VALUES ('%s', %s, %!s, NULL)",
                      punishmentType, targetSteamID, adminValue);

    g_Database.Query(OnCommPunishmentAdded, query);
}

public void OnCommPunishmentAdded(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("Failed to add communication punishment to database: %s", error);
}

void RemoveCommPunishmentFromDatabase(const char[] targetSteamID, const char[] punishmentType)
{
    if (g_Database == null)
        return;

    char query[512];
    g_Database.Format(query, sizeof(query),
                      "UPDATE punishments SET is_active = FALSE WHERE target_steam_id = %s AND punishment_type = '%s'",
                      targetSteamID, punishmentType);

    g_Database.Query(OnCommPunishmentRemoved, query);
}

public void OnCommPunishmentRemoved(Database db, DBResultSet results, const char[] error, any data)
{
    if (results != null) return;
    LogError("Failed to remove communication punishment from database: %s", error);
}

// ============================================================
// UTILITY FUNCTIONS
// ============================================================

int ParseTimeString(const char[] timeStr)
{
    // Handle "0" as permanent
    if (StrEqual(timeStr, "0"))
        return 0;

    int len = strlen(timeStr);
    if (len < 2)
        return -1;

    char numStr[32];
    strcopy(numStr, len, timeStr);

    char unit       = timeStr[len - 1];
    numStr[len - 1] = '\0';

    int value       = StringToInt(numStr);
    if (value <= 0)
        return -1;

    switch (unit)
    {
        case 'm', 'M': return value * 60;
        case 'h', 'H': return value * 3600;
        case 'd', 'D': return value * 86400;
        case 'w', 'W': return value * 604800;
        default: return -1;
    }
}

bool IsValidSteamID(const char[] steamid)
{
    // Validate SteamID64 format (numeric string, typically 17 digits)
    int len = strlen(steamid);
    if (len < 10 || len > 20)
        return false;

    // Check that all characters are digits
    for (int i = 0; i < len; i++)
    {
        if (!IsCharNumeric(steamid[i]))
            return false;
    }

    return true;
}

bool IsValidIP(const char[] ip)
{
    // Basic IP validation (simple check for dots)
    int dotCount = 0;
    for (int i = 0; i < strlen(ip); i++)
        if (ip[i] == '.')
            dotCount++;

    return (dotCount == 3);
}

int FindClientBySteamID(const char[] steamid)
{
    char clientSteamID[32];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        if (!GetClientAuthId(i, AuthId_SteamID64, clientSteamID, sizeof(clientSteamID))) continue;

        if (StrEqual(steamid, clientSteamID))
            return i;
    }

    return -1;
}

int FindTargetByString(const char[] target)
{
    // Handle #userid format
    if (target[0] == '#')
    {
        char temp[128];
        strcopy(temp, sizeof(temp), target[1]);

        // Check if it's a userid
        if (IsCharNumeric(temp[0]))
        {
            int userid = StringToInt(temp);
            return GetClientOfUserId(userid);
        }

        // Check if it's a SteamID
        if (StrContains(temp, "STEAM_", false) == 0)
        {
            return FindClientBySteamID(temp);
        }

        // Otherwise it's an exact name match
        return FindClientByExactName(temp);
    }

    // Try to find by partial name
    return FindClientByPartialName(target);
}

int FindClientByExactName(const char[] name)
{
    char clientName[MAX_NAME_LENGTH];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;

        GetClientName(i, clientName, sizeof(clientName));

        if (StrEqual(name, clientName))
            return i;
    }

    return -1;
}

int FindClientByPartialName(const char[] name)
{
    char clientName[MAX_NAME_LENGTH];
    int  matches   = 0;
    int  lastMatch = -1;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;

        GetClientName(i, clientName, sizeof(clientName));

        if (StrContains(clientName, name, false) != -1)
        {
            matches++;
            lastMatch = i;
        }
    }

    // Only return if there's exactly one match
    return (matches == 1) ? lastMatch : -1;
}

// BaseComm natives stub (these should be provided by basecomm.inc)
native bool BaseComm_SetClientGag(int client, bool gagged);
native bool BaseComm_SetClientMute(int client, bool muted);
