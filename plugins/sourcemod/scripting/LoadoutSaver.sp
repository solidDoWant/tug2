// (C) 2025 LoadoutSaver sdw
// Insurgency (2014) Loadout Saving Plugin

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <morecolors>

#define PLUGIN_VERSION "1.1.0"

public Plugin myinfo =
{
    name        = "[INS] Loadout Saver",
    author      = "sdw",
    description = "Save and restore player loadouts",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

// =====================================================
// Global Variables
// =====================================================

Database g_Database = null;

// Player data
char     g_PlayerSteamId[MAXPLAYERS + 1][32];
char     g_PlayerCurrentClass[MAXPLAYERS + 1][128];

// Rate limiting
float    g_LastSaveTime[MAXPLAYERS + 1];
float    g_LastLoadTime[MAXPLAYERS + 1];

// ConVars
ConVar   g_CvarMsgSaved;
ConVar   g_CvarMsgCleared;
ConVar   g_CvarMsgClearedAll;
ConVar   g_CvarMsgLoaded;
ConVar   g_CvarMsgFailed;
ConVar   g_CvarMsgSupplyError;
ConVar   g_CvarSaveCooldown;
ConVar   g_CvarLoadCooldown;
ConVar   g_CvarMaxNamed;
ConVar   g_CvarNamedCrossClass;

// Netprop offsets
int      g_EquippedGearOffset;

// Supply point tracking
ConVar   g_CvarSupplyTokenBase;

// Constants
#define SAVE_COOLDOWN       3.0
#define LOAD_COOLDOWN       0.1

// Buffer sizes
#define LOADOUT_BUFFER_SIZE 256
#define ITEM_STRING_SIZE    64

// Named loadouts. The name is what the player types, so it is kept short enough to stay readable
// in chat and to fit the VARCHAR(64) column with room to spare.
#define MAX_LOADOUT_NAME    40
#define NAMED_LOADOUT_CAP   15

// Game limits (based on Insurgency entity structure)
#define MAX_GEAR_SLOTS      6    // armor, head, vest, accessory, perk, misc
#define MAX_WEAPON_UPGRADES 8    // optics, ammo, magazine, barrel, stock, siderail, underbarrel, aesthetic
#define MAX_LOADOUT_ITEMS   9    // 1 weapon + 8 upgrades OR 6 gear items + padding

// =====================================================
// Plugin Lifecycle
// =====================================================
public void OnPluginStart()
{
    CreateConVar("sm_loadoutsaver_version", PLUGIN_VERSION, "Loadout Saver version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_CvarMsgSaved       = CreateConVar("sm_loadout_msg_saved", "{olivedrab}[Loadout]{default} Loadout saved!", "Message when saved");
    g_CvarMsgCleared     = CreateConVar("sm_loadout_msg_cleared", "{olivedrab}[Loadout]{default} Loadout cleared!", "Message when cleared");
    g_CvarMsgClearedAll  = CreateConVar("sm_loadout_msg_cleared_all", "{olivedrab}[Loadout]{default} All class loadouts cleared! (named loadouts kept - use !dello all)", "Message when all class loadouts cleared");
    g_CvarMsgLoaded      = CreateConVar("sm_loadout_msg_loaded", "{olivedrab}[Loadout]{default} Loadout loaded!", "Message when loaded");
    g_CvarMsgFailed      = CreateConVar("sm_loadout_msg_failed", "{red}[Loadout]{default} Failed to process loadout.", "Message on failure");
    g_CvarMsgSupplyError = CreateConVar("sm_loadout_msg_supply", "{red}[Loadout]{default} Can't save loadout that costs more than starting supply ({1})!", "Message when too expensive");
    g_CvarSaveCooldown   = CreateConVar("sm_loadout_save_cooldown", "3.0", "Cooldown for save command (seconds)", _, true, 0.0);
    g_CvarLoadCooldown   = CreateConVar("sm_loadout_load_cooldown", "0.1", "Cooldown for load command (seconds)", _, true, 0.0);

    g_CvarMaxNamed        = CreateConVar("sm_loadout_max_named", "15", "How many named loadouts a player may keep. Class loadouts do not count towards this.", _, true, 0.0);
    // Kill switch. Named loadouts are only useful because they cross classes, but if the game
    // ever turns out not to enforce class restrictions on inventory_buy_weapon, setting this to 0
    // confines each named loadout to the class it was saved on without removing the feature.
    g_CvarNamedCrossClass = CreateConVar("sm_loadout_named_cross_class", "1", "Allow a named loadout to be loaded on a class other than the one it was saved on.", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "plugin.loadoutsaver");

    // Register commands
    RegConsoleCmd("sm_savelo", Command_SaveLoadout, "Save your loadout for this class, or under a name: sm_savelo <name>");
    RegConsoleCmd("sm_clearlo", Command_ClearLoadout, "Clear this class's saved loadout (use 'all' for every class)");
    RegConsoleCmd("sm_loadlo", Command_LoadLoadout, "Load this class's saved loadout, or a named one: sm_loadlo <name>");
    RegConsoleCmd("inventory_reset", Command_InventoryReset, "Hook reset button to load saved loadout");

    // Named loadout management. Several spellings each, matching how the existing commands are
    // abbreviated, so players do not have to guess which one this server uses.
    RegConsoleCmd("sm_listlo", Command_ListLoadouts, "List your named loadouts");
    RegConsoleCmd("sm_listloadouts", Command_ListLoadouts, "List your named loadouts");
    RegConsoleCmd("sm_loadouts", Command_ListLoadouts, "List your named loadouts");
    RegConsoleCmd("sm_lslo", Command_ListLoadouts, "List your named loadouts");
    RegConsoleCmd("sm_lsloadout", Command_ListLoadouts, "List your named loadouts");
    RegConsoleCmd("sm_lsloadouts", Command_ListLoadouts, "List your named loadouts");
    RegConsoleCmd("sm_dello", Command_DeleteLoadout, "Delete a named loadout: sm_dello <name|all>");
    RegConsoleCmd("sm_delloadout", Command_DeleteLoadout, "Delete a named loadout: sm_delloadout <name|all>");
    RegConsoleCmd("sm_deletelo", Command_DeleteLoadout, "Delete a named loadout: sm_deletelo <name|all>");
    RegConsoleCmd("sm_deleteloadout", Command_DeleteLoadout, "Delete a named loadout: sm_deleteloadout <name|all>");

    // Hook events
    HookEvent("player_pick_squad", Event_PlayerPickSquad);

    // Find netprop offsets
    g_EquippedGearOffset = FindSendPropInfo("CINSPlayer", "m_EquippedGear");
    if (g_EquippedGearOffset == -1)
        SetFailState("Failed to find m_EquippedGear offset!");

    // Get supply token base convar
    g_CvarSupplyTokenBase = FindConVar("mp_supply_token_base");
    if (g_CvarSupplyTokenBase == null)
        LogError("Failed to find mp_supply_token_base convar - supply validation disabled");

    // Connect to database
    ConnectDatabase();
}

public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client)) return;

    // Get Steam64 ID
    if (!GetClientAuthId(client, AuthId_SteamID64, g_PlayerSteamId[client], sizeof(g_PlayerSteamId[])))
    {
        LogError("Failed to get Steam64 ID for client %d", client);
        return;
    }
    g_PlayerCurrentClass[client][0] = '\0';
    g_LastSaveTime[client]          = 0.0;
    g_LastLoadTime[client]          = 0.0;

    // Update last_seen_at
    if (g_Database != null)
        UpdatePlayerLastSeen(g_PlayerSteamId[client]);
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;

    // Clean up tracking variables
    g_PlayerCurrentClass[client][0] = '\0';
    g_LastSaveTime[client]          = 0.0;
    g_LastLoadTime[client]          = 0.0;
}

// =====================================================
// Database Connection
// =====================================================

void ConnectDatabase()
{
    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }

    Database.Connect(OnDatabaseConnected, "loadoutsaver");
}

void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Failed to connect to database: %s", error);
        CreateTimer(5.0, Timer_RetryConnection);
        return;
    }

    g_Database = db;
    LogMessage("Successfully connected to database");
}

public Action Timer_RetryConnection(Handle timer)
{
    if (g_Database == null)
    {
        LogMessage("Retrying database connection...");
        ConnectDatabase();
    }
    return Plugin_Handled;
}

void UpdatePlayerLastSeen(const char[] steamId)
{
    if (g_Database == null) return;

    char query[256];
    g_Database.Format(query, sizeof(query),
                      "UPDATE loadouts SET last_seen_at = CURRENT_TIMESTAMP WHERE steam_id = %s",
                      steamId);

    g_Database.Query(SQL_CheckError, query);
}

void SQL_CheckError(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null && error[0] != '\0')
    {
        LogError("SQL Error: %s", error);

        // Check for connection errors and reconnect
        if (StrContains(error, "connection", false) != -1 || StrContains(error, "server closed", false) != -1 || StrContains(error, "terminated", false) != -1)
        {
            LogError("Database connection lost, attempting reconnect...");
            g_Database = null;
            CreateTimer(1.0, Timer_RetryConnection);
        }
    }
}

// =====================================================
// Event Handlers
// =====================================================
public void Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || IsFakeClient(client)) return;

    char classTemplate[128];
    event.GetString("class_template", classTemplate, sizeof(classTemplate));

    // Update current class
    strcopy(g_PlayerCurrentClass[client], sizeof(g_PlayerCurrentClass[]), classTemplate);

    // Auto-load saved loadout with delay to ensure player is fully spawned
    CreateTimer(1.0, Timer_AutoLoadLoadout, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AutoLoadLoadout(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client)) return Plugin_Handled;

    LoadPlayerLoadout(client, false, "");    // Auto-load silently, this class only
    return Plugin_Handled;
}

// =====================================================
// Player Commands
// =====================================================
public Action Command_SaveLoadout(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Handled;

    if (g_PlayerCurrentClass[client][0] == '\0')
    {
        CPrintToChat(client, "{red}[Loadout]{default} Select a class first!");
        return Plugin_Handled;
    }

    // Check cooldown
    float cooldown = g_CvarSaveCooldown.FloatValue;
    if (GetGameTime() - g_LastSaveTime[client] < cooldown)
    {
        CPrintToChat(client, "{red}[Loadout]{default} You must wait before saving again.");
        return Plugin_Handled;
    }

    // A bare !savelo saves this class's loadout, exactly as before. Anything after the command is
    // treated as a loadout name, so multi-word names work without quoting.
    char name[MAX_LOADOUT_NAME + 1];
    if (!ReadLoadoutName(client, args, name, sizeof(name))) return Plugin_Handled;

    SaveLoadoutFromEntity(client, name);
    g_LastSaveTime[client] = GetGameTime();
    return Plugin_Handled;
}

// Reads a loadout name from the command arguments into name, returning false if the player typed
// something that cannot be used as one. An empty result means no name was given, which is the
// class-loadout case and always valid.
//
// Names are restricted to letters, digits, spaces, dashes and underscores. That keeps them
// readable in chat, keeps quoting rules simple, and means a name can never carry anything that
// would need escaping on its way into SQL - the queries escape it as well, but a name that cannot
// contain a quote is one less thing to reason about.
bool ReadLoadoutName(int client, int args, char[] name, int maxlen)
{
    name[0] = '\0';
    if (args < 1) return true;

    char raw[128];
    GetCmdArgString(raw, sizeof(raw));
    TrimString(raw);
    StripQuotes(raw);
    TrimString(raw);

    if (raw[0] == '\0')
    {
        // The player typed something after the command, so they meant to name a loadout. Falling
        // through to the class-loadout path here would silently overwrite or load the wrong thing.
        CPrintToChat(client, "{red}[Loadout]{default} Loadout name can't be blank.");
        return false;
    }

    // Collapse runs of spaces so "cqb  kit" and "cqb kit" cannot become two different loadouts
    // that look identical in chat.
    int write = 0;
    for (int read = 0; raw[read] != '\0'; read++)
    {
        if (raw[read] == ' ' && write > 0 && raw[write - 1] == ' ') continue;
        raw[write++] = raw[read];
    }
    raw[write] = '\0';

    if (strlen(raw) > MAX_LOADOUT_NAME)
    {
        CPrintToChat(client, "{red}[Loadout]{default} Loadout names can be at most %d characters.", MAX_LOADOUT_NAME);
        return false;
    }

    for (int i = 0; raw[i] != '\0'; i++)
    {
        if (IsCharAlpha(raw[i]) || IsCharNumeric(raw[i]) || raw[i] == ' ' || raw[i] == '-' || raw[i] == '_') continue;

        CPrintToChat(client, "{red}[Loadout]{default} Loadout names can only use letters, numbers, spaces, - and _");
        return false;
    }

    // "all" is how !dello and !clearlo mean "every one of them", so a loadout may not be called
    // that - otherwise it could never be deleted on its own.
    if (StrEqual(raw, "all", false))
    {
        CPrintToChat(client, "{red}[Loadout]{default} \"all\" is reserved, pick another name.");
        return false;
    }

    strcopy(name, maxlen, raw);
    return true;
}

public Action Command_ClearLoadout(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Handled;

    // Check if "all" argument is provided
    if (args >= 1)
    {
        char arg[32];
        GetCmdArg(1, arg, sizeof(arg));

        if (StrEqual(arg, "all", false))
        {
            ClearAllLoadouts(client);
            return Plugin_Handled;
        }
    }

    // Clear current class loadout
    if (g_PlayerCurrentClass[client][0] == '\0')
    {
        CPrintToChat(client, "{red}[Loadout]{default} Select a class first!");
        return Plugin_Handled;
    }

    ClearLoadout(client);
    return Plugin_Handled;
}

public Action Command_LoadLoadout(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Handled;

    if (g_PlayerCurrentClass[client][0] == '\0')
    {
        CPrintToChat(client, "{red}[Loadout]{default} Select a class first!");
        return Plugin_Handled;
    }

    // Check cooldown
    float cooldown = g_CvarLoadCooldown.FloatValue;
    if (GetGameTime() - g_LastLoadTime[client] < cooldown) return Plugin_Handled;

    char name[MAX_LOADOUT_NAME + 1];
    if (!ReadLoadoutName(client, args, name, sizeof(name))) return Plugin_Handled;

    LoadPlayerLoadout(client, true, name);    // Manual load with messages
    g_LastLoadTime[client] = GetGameTime();
    return Plugin_Handled;
}

public Action Command_ListLoadouts(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Handled;

    if (g_Database == null)
    {
        SendFailedMessage(client);
        return Plugin_Handled;
    }

    char query[256];
    g_Database.Format(query, sizeof(query),
                      "SELECT name, class_template FROM loadouts WHERE steam_id = %s AND name IS NOT NULL ORDER BY lower(name)",
                      g_PlayerSteamId[client]);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));

    g_Database.Query(OnLoadoutsListed, query, pack);
    return Plugin_Handled;
}

public Action Command_DeleteLoadout(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Handled;

    if (args < 1)
    {
        CPrintToChat(client, "{red}[Loadout]{default} Usage: !dello <name>, or !dello all. See !listlo for your names.");
        return Plugin_Handled;
    }

    char raw[128];
    GetCmdArgString(raw, sizeof(raw));
    TrimString(raw);
    StripQuotes(raw);
    TrimString(raw);

    if (StrEqual(raw, "all", false))
    {
        DeleteNamedLoadout(client, "");    // empty name means every named loadout
        return Plugin_Handled;
    }

    char name[MAX_LOADOUT_NAME + 1];
    if (!ReadLoadoutName(client, args, name, sizeof(name))) return Plugin_Handled;

    if (name[0] == '\0')
    {
        CPrintToChat(client, "{red}[Loadout]{default} Usage: !dello <name>, or !dello all. See !listlo for your names.");
        return Plugin_Handled;
    }

    DeleteNamedLoadout(client, name);
    return Plugin_Handled;
}

public Action Command_InventoryReset(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Continue;

    // Check cooldown
    float cooldown = g_CvarLoadCooldown.FloatValue;
    if (GetGameTime() - g_LastLoadTime[client] < cooldown) return Plugin_Continue;

    // Try to load saved loadout instead of resetting
    LoadPlayerLoadout(client, false, "");    // Silent load of this class's loadout
    g_LastLoadTime[client] = GetGameTime();

    return Plugin_Handled;    // Block default reset behavior
}

// =====================================================
// Entity Inspection - Read Loadout from Player
// =====================================================

void ExtractWeaponData(int weapon, char[] buffer, int maxlen)
{
    if (weapon <= 0)
    {
        buffer[0] = '\0';
        return;
    }

    int weaponID = GetEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle");
    if (weaponID <= 0)
    {
        buffer[0] = '\0';
        return;
    }

    Format(buffer, maxlen, "%d", weaponID);

    // Get weapon upgrades
    int upgradeOffset = GetEntSendPropOffs(weapon, "m_upgradeSlots");
    if (upgradeOffset <= 0) return;

    for (int i = 0; i < MAX_WEAPON_UPGRADES * 4; i += 4)
    {
        int upgradeID = GetEntData(weapon, upgradeOffset + i);
        if (upgradeID > 0)
            Format(buffer, maxlen, "%s;%d", buffer, upgradeID);
    }
}

bool ValidateSupplyPoints(int client)
{
    if (g_CvarSupplyTokenBase == null) return true;    // Skip validation if convar not found

    int availableTokens = GetEntProp(client, Prop_Send, "m_nAvailableTokens");
    int receivedTokens  = GetEntProp(client, Prop_Send, "m_nRecievedTokens");
    int baseTokens      = g_CvarSupplyTokenBase.IntValue;

    // Ensure saved loadout doesn't cost more than base starting supply
    // If player received bonus tokens (from objectives/kills), those shouldn't be saved
    // Check: (receivedTokens - baseTokens) represents bonus tokens
    // If bonus tokens > available tokens, then base loadout costs too much
    if ((receivedTokens - baseTokens) > availableTokens)
    {
        char message[256];
        g_CvarMsgSupplyError.GetString(message, sizeof(message));

        char baseStr[16];
        IntToString(baseTokens, baseStr, sizeof(baseStr));
        ReplaceString(message, sizeof(message), "{1}", baseStr);

        CPrintToChat(client, message);
        return false;
    }

    return true;
}

void SaveLoadoutFromEntity(int client, const char[] name)
{
    if (g_Database == null)
    {
        SendFailedMessage(client);
        return;
    }

    // Validate supply points before saving
    if (!ValidateSupplyPoints(client)) return;

    char gearBuffer[LOADOUT_BUFFER_SIZE];
    char primaryBuffer[LOADOUT_BUFFER_SIZE];
    char secondaryBuffer[LOADOUT_BUFFER_SIZE];
    char explosiveBuffer[LOADOUT_BUFFER_SIZE];

    gearBuffer[0] = '\0';

    // Get gear from player entity
    if (g_EquippedGearOffset != -1)
    {
        for (int i = 0; i < MAX_GEAR_SLOTS * 4; i += 4)
        {
            int gearID = GetEntData(client, g_EquippedGearOffset + i);
            if (gearID > 0)
            {
                if (gearBuffer[0] != '\0')
                    Format(gearBuffer, sizeof(gearBuffer), "%s;%d", gearBuffer, gearID);
                else
                    Format(gearBuffer, sizeof(gearBuffer), "%d", gearID);
            }
        }
    }

    // Get weapons using helper function
    ExtractWeaponData(GetPlayerWeaponSlot(client, 0), primaryBuffer, sizeof(primaryBuffer));
    ExtractWeaponData(GetPlayerWeaponSlot(client, 1), secondaryBuffer, sizeof(secondaryBuffer));
    ExtractWeaponData(GetPlayerWeaponSlot(client, 3), explosiveBuffer, sizeof(explosiveBuffer));

    // Save to database in a single query
    SaveLoadoutToDatabase(client, gearBuffer, primaryBuffer, secondaryBuffer, explosiveBuffer, name);
}

// =====================================================
// Save Loadout to Database
// =====================================================

void SaveLoadoutToDatabase(int client, const char[] gearBuffer, const char[] primaryBuffer, const char[] secondaryBuffer, const char[] explosiveBuffer, const char[] name)
{
    if (g_Database == null) return;

    // Build NULL-safe value strings for empty buffers
    char gearValue[550];
    if (gearBuffer[0] == '\0')
        Format(gearValue, sizeof(gearValue), "NULL");
    else
        g_Database.Format(gearValue, sizeof(gearValue), "'%s'", gearBuffer);

    char primaryValue[550];
    if (primaryBuffer[0] == '\0')
        Format(primaryValue, sizeof(primaryValue), "NULL");
    else
        g_Database.Format(primaryValue, sizeof(primaryValue), "'%s'", primaryBuffer);

    char secondaryValue[550];
    if (secondaryBuffer[0] == '\0')
        Format(secondaryValue, sizeof(secondaryValue), "NULL");
    else
        g_Database.Format(secondaryValue, sizeof(secondaryValue), "'%s'", secondaryBuffer);

    char explosiveValue[550];
    if (explosiveBuffer[0] == '\0')
        Format(explosiveValue, sizeof(explosiveValue), "NULL");
    else
        g_Database.Format(explosiveValue, sizeof(explosiveValue), "'%s'", explosiveBuffer);

    char query[2048];

    if (name[0] == '\0')
    {
        // Class loadout: one row per player per class, upserted on the partial unique index that
        // replaced the old (steam_id, class_template) primary key.
        Format(
            query, sizeof(query),
            "INSERT INTO loadouts (steam_id, class_template, name, gear, primary_weapon, secondary_weapon, explosive, updated_at, update_count) VALUES (%s, '%s', NULL, %s, %s, %s, %s, CURRENT_TIMESTAMP, 1) ON CONFLICT (steam_id, class_template) WHERE name IS NULL DO UPDATE SET gear = EXCLUDED.gear, primary_weapon = EXCLUDED.primary_weapon, secondary_weapon = EXCLUDED.secondary_weapon, explosive = EXCLUDED.explosive, updated_at = CURRENT_TIMESTAMP, update_count = loadouts.update_count + 1",
            g_PlayerSteamId[client], g_PlayerCurrentClass[client], gearValue, primaryValue, secondaryValue, explosiveValue);
    }
    else
    {
        char nameValue[MAX_LOADOUT_NAME * 2 + 8];
        g_Database.Format(nameValue, sizeof(nameValue), "'%s'", name);

        // Named loadout. The cap is enforced inside the statement rather than by a read followed
        // by a write, so two saves racing each other cannot both see room and both insert.
        // Overwriting a name the player already owns is always allowed, even at the cap, which is
        // what the EXISTS arm is for. A blocked save inserts no row, which the callback detects by
        // the affected row count.
        Format(
            query, sizeof(query),
            "INSERT INTO loadouts (steam_id, class_template, name, gear, primary_weapon, secondary_weapon, explosive, updated_at, update_count) SELECT %s, '%s', %s, %s, %s, %s, %s, CURRENT_TIMESTAMP, 1 WHERE (SELECT COUNT(*) FROM loadouts WHERE steam_id = %s AND name IS NOT NULL) < %d OR EXISTS (SELECT 1 FROM loadouts WHERE steam_id = %s AND name IS NOT NULL AND lower(name) = lower(%s)) ON CONFLICT (steam_id, lower(name)) WHERE name IS NOT NULL DO UPDATE SET class_template = EXCLUDED.class_template, gear = EXCLUDED.gear, primary_weapon = EXCLUDED.primary_weapon, secondary_weapon = EXCLUDED.secondary_weapon, explosive = EXCLUDED.explosive, updated_at = CURRENT_TIMESTAMP, update_count = loadouts.update_count + 1",
            g_PlayerSteamId[client], g_PlayerCurrentClass[client], nameValue, gearValue, primaryValue, secondaryValue, explosiveValue,
            g_PlayerSteamId[client], g_CvarMaxNamed.IntValue,
            g_PlayerSteamId[client], nameValue);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(name);

    g_Database.Query(OnLoadoutSaved, query, pack);
}

void OnLoadoutSaved(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int  userid = pack.ReadCell();
    char name[MAX_LOADOUT_NAME + 1];
    pack.ReadString(name, sizeof(name));
    delete pack;

    if (results == null)
    {
        LogError("Failed to save loadout: %s", error);
        SQL_CheckError(db, results, error, 0);

        int client = GetClientOfUserId(userid);
        if (client < 1) return;

        // The database enforces the cap too. Reaching it here means the statement's own check was
        // bypassed somehow, but the player should still get the useful message rather than a
        // generic failure.
        if (StrContains(error, "named loadout cap", false) != -1)
        {
            CPrintToChat(client, "{red}[Loadout]{default} You already have %d named loadouts. Delete one with !dello <name> first.", g_CvarMaxNamed.IntValue);
            return;
        }

        SendFailedMessage(client);
        return;
    }

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    // A named save that touched no rows was turned away by the cap check in the statement.
    if (name[0] != '\0' && results.AffectedRows < 1)
    {
        CPrintToChat(client, "{red}[Loadout]{default} You already have %d named loadouts. Delete one with !dello <name> first.", g_CvarMaxNamed.IntValue);
        return;
    }

    if (name[0] != '\0')
    {
        CPrintToChat(client, "{olivedrab}[Loadout]{default} Saved as {green}%s{default}. Load it on any class with !loadlo %s", name, name);
        return;
    }

    char message[256];
    g_CvarMsgSaved.GetString(message, sizeof(message));
    CPrintToChat(client, message);
}

// =====================================================
// Load Loadout from Database
// =====================================================

// name empty = this class's own loadout (the automatic spawn load and a bare !loadlo).
// Otherwise the named loadout, which may have been saved on any class.
void LoadPlayerLoadout(int client, bool showMessages, const char[] name)
{
    if (g_Database == null)
    {
        if (showMessages) SendFailedMessage(client);
        return;
    }

    char query[512];
    if (name[0] == '\0')
    {
        g_Database.Format(query, sizeof(query),
                          "SELECT gear, primary_weapon, secondary_weapon, explosive, class_template FROM loadouts WHERE steam_id = %s AND class_template = '%s' AND name IS NULL",
                          g_PlayerSteamId[client], g_PlayerCurrentClass[client]);
    }
    else
    {
        g_Database.Format(query, sizeof(query),
                          "SELECT gear, primary_weapon, secondary_weapon, explosive, class_template FROM loadouts WHERE steam_id = %s AND name IS NOT NULL AND lower(name) = lower('%s')",
                          g_PlayerSteamId[client], name);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(showMessages);
    pack.WriteString(name);

    g_Database.Query(OnLoadoutRetrieved, query, pack);
}

void OnLoadoutRetrieved(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int  userid       = pack.ReadCell();
    bool showMessages = pack.ReadCell();
    char name[MAX_LOADOUT_NAME + 1];
    pack.ReadString(name, sizeof(name));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    if (results == null)
    {
        LogError("Failed to load loadout: %s", error);
        SQL_CheckError(db, results, error, 0);
        if (showMessages) SendFailedMessage(client);
        return;
    }

    if (!results.FetchRow())
    {
        // No class loadout saved is the normal case and stays silent, but a player who asked for
        // a name by hand should hear that it does not exist.
        if (name[0] != '\0' && showMessages)
            CPrintToChat(client, "{red}[Loadout]{default} No loadout named {green}%s{default}. See !listlo", name);
        return;
    }

    // The class the loadout was saved on. For a named loadout this may not be the class being
    // played right now, which is the whole point of them, but it is also the case that needs
    // guarding - see ApplyLoadoutFromArrays.
    char savedClass[128];
    results.FetchString(4, savedClass, sizeof(savedClass));

    if (name[0] != '\0' && !StrEqual(savedClass, g_PlayerCurrentClass[client], false) && !g_CvarNamedCrossClass.BoolValue)
    {
        if (showMessages)
            CPrintToChat(client, "{red}[Loadout]{default} {green}%s{default} was saved on another class and cross-class loading is disabled here.", name);
        return;
    }

    // Arrays sized for: 1 weapon ID + MAX_WEAPON_UPGRADES upgrade IDs = 9 items
    // Or for gear: MAX_GEAR_SLOTS gear items = 6 items (+ padding to 9)
    char gearArray[MAX_LOADOUT_ITEMS][ITEM_STRING_SIZE];
    char primaryArray[MAX_LOADOUT_ITEMS][ITEM_STRING_SIZE];
    char secondaryArray[MAX_LOADOUT_ITEMS][ITEM_STRING_SIZE];
    char explosiveArray[MAX_LOADOUT_ITEMS][ITEM_STRING_SIZE];

    // Initialize all arrays to empty strings
    for (int i = 0; i < MAX_LOADOUT_ITEMS; i++)
    {
        gearArray[i][0]      = '\0';
        primaryArray[i][0]   = '\0';
        secondaryArray[i][0] = '\0';
        explosiveArray[i][0] = '\0';
    }

    char buffer[LOADOUT_BUFFER_SIZE];

    // Read gear column
    if (!results.IsFieldNull(0))
    {
        results.FetchString(0, buffer, sizeof(buffer));
        if (buffer[0] != '\0')
            ExplodeString(buffer, ";", gearArray, MAX_LOADOUT_ITEMS, sizeof(gearArray[]));
    }

    // Read primary_weapon column
    if (!results.IsFieldNull(1))
    {
        results.FetchString(1, buffer, sizeof(buffer));
        if (buffer[0] != '\0')
            ExplodeString(buffer, ";", primaryArray, MAX_LOADOUT_ITEMS, sizeof(primaryArray[]));
    }

    // Read secondary_weapon column
    if (!results.IsFieldNull(2))
    {
        results.FetchString(2, buffer, sizeof(buffer));
        if (buffer[0] != '\0')
            ExplodeString(buffer, ";", secondaryArray, MAX_LOADOUT_ITEMS, sizeof(secondaryArray[]));
    }

    // Read explosive column
    if (!results.IsFieldNull(3))
    {
        results.FetchString(3, buffer, sizeof(buffer));
        if (buffer[0] != '\0')
            ExplodeString(buffer, ";", explosiveArray, MAX_LOADOUT_ITEMS, sizeof(explosiveArray[]));
    }

    // Apply loadout from arrays
    ApplyLoadoutFromArrays(client, gearArray, primaryArray, secondaryArray, explosiveArray, showMessages, name, savedClass);
}

// =====================================================
// Apply Loadout - Execute Buy Commands
// =====================================================

void ApplyLoadoutFromArrays(int client, char[][] gearArray, char[][] primaryArray, char[][] secondaryArray, char[][] explosiveArray, bool showMessages, const char[] name, const char[] savedClass)
{
    // Validate client is in game and alive
    if (!IsClientInGame(client)) return;
    if (!IsPlayerAlive(client)) return;

    // Clear current loadout
    FakeClientCommand(client, "inventory_sell_all");

    // Apply gear (up to MAX_GEAR_SLOTS items)
    for (int i = 0; i < MAX_LOADOUT_ITEMS; i++)
    {
        if (gearArray[i][0] == '\0') break;
        FakeClientCommand(client, "inventory_buy_gear %s", gearArray[i]);
    }

    // Buy primary, secondary, and explosive
    int weaponCount = 0;
    weaponCount += BuyWeapons(client, primaryArray, weaponCount);
    weaponCount += BuyWeapons(client, secondaryArray, weaponCount);
    BuyWeapons(client, explosiveArray, weaponCount);

    // Auto-resupply if in resupply zone
    FakeClientCommand(client, "inventory_resupply");

    if (showMessages)
    {
        char message[256];
        g_CvarMsgLoaded.GetString(message, sizeof(message));
        CPrintToChat(client, message);
    }

    // Nothing above decides what a player is allowed to carry. Every item is applied with the
    // same inventory_buy_* commands the buy menu itself issues, so the game arbitrates class
    // restrictions and supply cost exactly as it does for a manual purchase - a rifleman cannot
    // buy the machine gunner's LMG through this path any more than through the menu.
    //
    // Rather than trust that silently, a cross-class load is checked afterwards: the weapons the
    // player actually ended up holding are compared against the ones the loadout asked for. Items
    // the game refused simply are not there, and the player is told how many were dropped instead
    // of being left wondering. The comparison also lands in the server log, so if the game ever
    // does hand over something it should not, there is a record of it rather than a rumour.
    if (name[0] == '\0') return;
    if (StrEqual(savedClass, g_PlayerCurrentClass[client], false)) return;

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(showMessages);
    pack.WriteString(name);
    pack.WriteString(savedClass);
    pack.WriteString(primaryArray[0]);
    pack.WriteString(secondaryArray[0]);
    pack.WriteString(explosiveArray[0]);

    // The buys are queued as client commands, so read the result back a moment later.
    CreateTimer(0.5, Timer_VerifyCrossClassLoad, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

// Compares what a cross-class named loadout asked for against what the player is actually holding.
public Action Timer_VerifyCrossClassLoad(Handle timer, DataPack pack)
{
    pack.Reset();
    int  userid       = pack.ReadCell();
    bool showMessages = pack.ReadCell();

    char name[MAX_LOADOUT_NAME + 1];
    char savedClass[128];
    char wanted[3][ITEM_STRING_SIZE];
    pack.ReadString(name, sizeof(name));
    pack.ReadString(savedClass, sizeof(savedClass));
    pack.ReadString(wanted[0], sizeof(wanted[]));
    pack.ReadString(wanted[1], sizeof(wanted[]));
    pack.ReadString(wanted[2], sizeof(wanted[]));

    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client)) return Plugin_Handled;

    // Weapon slots in the same order they were saved and bought: primary, secondary, explosive.
    int  slots[3] = { 0, 1, 3 };
    int  dropped  = 0;
    char got[3][ITEM_STRING_SIZE];

    for (int i = 0; i < 3; i++)
    {
        ExtractWeaponData(GetPlayerWeaponSlot(client, slots[i]), got[i], sizeof(got[]));

        if (wanted[i][0] == '\0') continue;

        // ExtractWeaponData returns "id;upgrade;upgrade..."; only the weapon itself matters here,
        // since an upgrade cannot be held without the weapon it belongs to.
        char gotId[ITEM_STRING_SIZE];
        strcopy(gotId, sizeof(gotId), got[i]);
        int sep = FindCharInString(gotId, ';');
        if (sep != -1) gotId[sep] = '\0';

        if (!StrEqual(gotId, wanted[i])) dropped++;
    }

    LogMessage("[LoadoutSaver] %L loaded named loadout \"%s\" (saved on %s) while playing %s: wanted %s/%s/%s, got %s/%s/%s",
               client, name, savedClass, g_PlayerCurrentClass[client],
               wanted[0], wanted[1], wanted[2], got[0], got[1], got[2]);

    if (dropped > 0 && showMessages)
    {
        CPrintToChat(client, "{red}[Loadout]{default} %d item(s) in {green}%s{default} are not available to this class and were not equipped.", dropped, name);
    }

    return Plugin_Handled;
}

int BuyWeapons(int client, const char[][] itemArray, int upgradeSlot)
{
    int weaponsAdded = 0;
    for (int i = 0; i < MAX_LOADOUT_ITEMS; i++)
    {
        if (itemArray[i][0] == '\0')
            return weaponsAdded;

        if (i == 0)
        {
            FakeClientCommand(client, "inventory_buy_weapon %s", itemArray[i]);
            weaponsAdded++;
            continue;
        }

        FakeClientCommand(client, "inventory_buy_upgrade %d %s", weaponsAdded + upgradeSlot, itemArray[i]);
    }

    return weaponsAdded;
}

// =====================================================
// Clear Loadout
// =====================================================

void ClearLoadout(int client)
{
    if (g_Database == null)
    {
        SendFailedMessage(client);
        return;
    }

    char query[512];
    g_Database.Format(query, sizeof(query), "DELETE FROM loadouts WHERE steam_id = %s AND class_template = '%s' AND name IS NULL", g_PlayerSteamId[client], g_PlayerCurrentClass[client]);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));

    g_Database.Query(OnLoadoutCleared, query, pack);
}

void OnLoadoutCleared(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    if (results == null)
    {
        LogError("Failed to clear loadout: %s", error);
        SQL_CheckError(db, results, error, 0);
        SendFailedMessage(client);
        return;
    }

    char message[256];
    g_CvarMsgCleared.GetString(message, sizeof(message));
    CPrintToChat(client, message);
}

void ClearAllLoadouts(int client)
{
    if (g_Database == null)
    {
        SendFailedMessage(client);
        return;
    }

    // Scoped to class loadouts on purpose. !clearlo is the class-loadout command, and wiping 15
    // named loadouts as a side effect of resetting your classes would be a nasty surprise;
    // !dello all is the deliberate way to do that.
    char query[512];
    g_Database.Format(query, sizeof(query), "DELETE FROM loadouts WHERE steam_id = %s AND name IS NULL", g_PlayerSteamId[client]);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));

    g_Database.Query(OnAllLoadoutsCleared, query, pack);
}

void OnAllLoadoutsCleared(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    if (results == null)
    {
        LogError("Failed to clear all loadouts: %s", error);
        SQL_CheckError(db, results, error, 0);
        SendFailedMessage(client);
        return;
    }

    char message[256];
    g_CvarMsgClearedAll.GetString(message, sizeof(message));
    CPrintToChat(client, message);
}

// =====================================================
// Named Loadouts - List and Delete
// =====================================================

void OnLoadoutsListed(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    if (results == null)
    {
        LogError("Failed to list loadouts: %s", error);
        SQL_CheckError(db, results, error, 0);
        SendFailedMessage(client);
        return;
    }

    int total = results.RowCount;
    if (total < 1)
    {
        CPrintToChat(client, "{olivedrab}[Loadout]{default} You have no named loadouts. Save one with !savelo <name>");
        return;
    }

    CPrintToChat(client, "{olivedrab}[Loadout]{default} Your named loadouts (%d/%d):", total, g_CvarMaxNamed.IntValue);

    // Printed a few per line so a full set of 15 does not bury the rest of chat.
    char line[256];
    int  onLine = 0;
    char name[MAX_LOADOUT_NAME + 1];

    while (results.FetchRow())
    {
        results.FetchString(0, name, sizeof(name));

        if (onLine > 0) StrCat(line, sizeof(line), "{default}, ");
        Format(line, sizeof(line), "%s{green}%s", line, name);

        if (++onLine < 5) continue;

        CPrintToChat(client, "{olivedrab}[Loadout]{default} %s", line);
        line[0] = '\0';
        onLine  = 0;
    }

    if (onLine > 0) CPrintToChat(client, "{olivedrab}[Loadout]{default} %s", line);
}

// An empty name deletes every named loadout the player has.
void DeleteNamedLoadout(int client, const char[] name)
{
    if (g_Database == null)
    {
        SendFailedMessage(client);
        return;
    }

    char query[512];
    if (name[0] == '\0')
    {
        g_Database.Format(query, sizeof(query),
                          "DELETE FROM loadouts WHERE steam_id = %s AND name IS NOT NULL",
                          g_PlayerSteamId[client]);
    }
    else
    {
        g_Database.Format(query, sizeof(query),
                          "DELETE FROM loadouts WHERE steam_id = %s AND name IS NOT NULL AND lower(name) = lower('%s')",
                          g_PlayerSteamId[client], name);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(name);

    g_Database.Query(OnNamedLoadoutDeleted, query, pack);
}

void OnNamedLoadoutDeleted(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int  userid = pack.ReadCell();
    char name[MAX_LOADOUT_NAME + 1];
    pack.ReadString(name, sizeof(name));
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    if (results == null)
    {
        LogError("Failed to delete named loadout: %s", error);
        SQL_CheckError(db, results, error, 0);
        SendFailedMessage(client);
        return;
    }

    if (name[0] == '\0')
    {
        CPrintToChat(client, "{olivedrab}[Loadout]{default} Deleted all %d named loadout(s).", results.AffectedRows);
        return;
    }

    if (results.AffectedRows < 1)
    {
        CPrintToChat(client, "{red}[Loadout]{default} No loadout named {green}%s{default}. See !listlo", name);
        return;
    }

    CPrintToChat(client, "{olivedrab}[Loadout]{default} Deleted {green}%s{default}.", name);
}

// =====================================================
// Utility Functions
// =====================================================

void SendFailedMessage(int client)
{
    char message[256];
    g_CvarMsgFailed.GetString(message, sizeof(message));
    CPrintToChat(client, message);
}
