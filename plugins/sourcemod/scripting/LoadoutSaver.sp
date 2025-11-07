// (C) 2025 LoadoutSaver sdw
// Insurgency (2014) Loadout Saving Plugin

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <morecolors>

#define PLUGIN_VERSION "1.0.0"

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
    g_CvarMsgClearedAll  = CreateConVar("sm_loadout_msg_cleared_all", "{olivedrab}[Loadout]{default} All loadouts cleared!", "Message when all loadouts cleared");
    g_CvarMsgLoaded      = CreateConVar("sm_loadout_msg_loaded", "{olivedrab}[Loadout]{default} Loadout loaded!", "Message when loaded");
    g_CvarMsgFailed      = CreateConVar("sm_loadout_msg_failed", "{red}[Loadout]{default} Failed to process loadout.", "Message on failure");
    g_CvarMsgSupplyError = CreateConVar("sm_loadout_msg_supply", "{red}[Loadout]{default} Can't save loadout that costs more than starting supply ({1})!", "Message when too expensive");
    g_CvarSaveCooldown   = CreateConVar("sm_loadout_save_cooldown", "3.0", "Cooldown for save command (seconds)", _, true, 0.0);
    g_CvarLoadCooldown   = CreateConVar("sm_loadout_load_cooldown", "0.1", "Cooldown for load command (seconds)", _, true, 0.0);

    AutoExecConfig(true, "plugin.loadoutsaver");

    // Register commands
    RegConsoleCmd("sm_savelo", Command_SaveLoadout, "Save your current loadout");
    RegConsoleCmd("sm_clearlo", Command_ClearLoadout, "Clear your saved loadout (use 'all' to clear all classes)");
    RegConsoleCmd("sm_loadlo", Command_LoadLoadout, "Load your saved loadout");
    RegConsoleCmd("inventory_reset", Command_InventoryReset, "Hook reset button to load saved loadout");

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

    // Validate Steam ID
    if (auth[0] == '\0' || StrContains(auth, "STEAM_") != 0)
    {
        LogError("Invalid Steam ID for client %d: %s", client, auth);
        return;
    }

    strcopy(g_PlayerSteamId[client], sizeof(g_PlayerSteamId[]), auth);
    g_PlayerCurrentClass[client][0] = '\0';
    g_LastSaveTime[client]          = 0.0;
    g_LastLoadTime[client]          = 0.0;

    // Update last_seen_at
    if (g_Database != null)
        UpdatePlayerLastSeen(auth);
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
    char escapedSteamId[64];
    g_Database.Escape(steamId, escapedSteamId, sizeof(escapedSteamId));

    Format(query, sizeof(query),
           "UPDATE loadouts SET last_seen_at = CURRENT_TIMESTAMP WHERE steam_id = '%s'",
           escapedSteamId);

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

    LoadPlayerLoadout(client, false);    // Auto-load silently
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

    SaveLoadoutFromEntity(client);
    g_LastSaveTime[client] = GetGameTime();
    return Plugin_Handled;
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

    LoadPlayerLoadout(client, true);    // Manual load with messages
    g_LastLoadTime[client] = GetGameTime();
    return Plugin_Handled;
}

public Action Command_InventoryReset(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Continue;

    // Check cooldown
    float cooldown = g_CvarLoadCooldown.FloatValue;
    if (GetGameTime() - g_LastLoadTime[client] < cooldown) return Plugin_Continue;

    // Try to load saved loadout instead of resetting
    LoadPlayerLoadout(client, false);    // Silent load
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

void SaveLoadoutFromEntity(int client)
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
    SaveLoadoutToDatabase(client, gearBuffer, primaryBuffer, secondaryBuffer, explosiveBuffer);
}

// =====================================================
// Save Loadout to Database
// =====================================================

void SaveLoadoutToDatabase(int client, const char[] gearBuffer, const char[] primaryBuffer, const char[] secondaryBuffer, const char[] explosiveBuffer)
{
    if (g_Database == null) return;

    // Escape strings for SQL
    char escapedSteamId[64];
    char escapedClass[256];
    char escapedGear[512];
    char escapedPrimary[512];
    char escapedSecondary[512];
    char escapedExplosive[512];

    g_Database.Escape(g_PlayerSteamId[client], escapedSteamId, sizeof(escapedSteamId));
    g_Database.Escape(g_PlayerCurrentClass[client], escapedClass, sizeof(escapedClass));
    g_Database.Escape(gearBuffer, escapedGear, sizeof(escapedGear));
    g_Database.Escape(primaryBuffer, escapedPrimary, sizeof(escapedPrimary));
    g_Database.Escape(secondaryBuffer, escapedSecondary, sizeof(escapedSecondary));
    g_Database.Escape(explosiveBuffer, escapedExplosive, sizeof(escapedExplosive));

    // Prepare NULL or quoted values
    char gearValue[550], primaryValue[550], secondaryValue[550], explosiveValue[550];
    Format(gearValue, sizeof(gearValue), gearBuffer[0] != '\0' ? "'%s'" : "NULL", escapedGear);
    Format(primaryValue, sizeof(primaryValue), primaryBuffer[0] != '\0' ? "'%s'" : "NULL", escapedPrimary);
    Format(secondaryValue, sizeof(secondaryValue), secondaryBuffer[0] != '\0' ? "'%s'" : "NULL", escapedSecondary);
    Format(explosiveValue, sizeof(explosiveValue), explosiveBuffer[0] != '\0' ? "'%s'" : "NULL", escapedExplosive);

    // Single UPSERT query
    char query[2048];
    Format(
        query, sizeof(query),
        "INSERT INTO loadouts (steam_id, class_template, gear, primary_weapon, secondary_weapon, explosive, updated_at, update_count) " ... "VALUES ('%s', '%s', %s, %s, %s, %s, CURRENT_TIMESTAMP, 1) " ... "ON CONFLICT (steam_id, class_template) DO UPDATE SET " ... "gear = EXCLUDED.gear, " ... "primary_weapon = EXCLUDED.primary_weapon, " ... "secondary_weapon = EXCLUDED.secondary_weapon, " ... "explosive = EXCLUDED.explosive, " ... "updated_at = CURRENT_TIMESTAMP, " ... "update_count = loadouts.update_count + 1",
        escapedSteamId, escapedClass, gearValue, primaryValue, secondaryValue, explosiveValue);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));

    g_Database.Query(OnLoadoutSaved, query, pack);
}

void OnLoadoutSaved(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    if (results == null)
    {
        LogError("Failed to save loadout: %s", error);
        SQL_CheckError(db, results, error, 0);

        int client = GetClientOfUserId(userid);
        if (client > 0) SendFailedMessage(client);
        return;
    }

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    char message[256];
    g_CvarMsgSaved.GetString(message, sizeof(message));
    CPrintToChat(client, message);
}

// =====================================================
// Load Loadout from Database
// =====================================================

void LoadPlayerLoadout(int client, bool showMessages)
{
    if (g_Database == null)
    {
        if (showMessages) SendFailedMessage(client);
        return;
    }

    char query[512];
    char escapedSteamId[64];
    char escapedClass[256];
    g_Database.Escape(g_PlayerSteamId[client], escapedSteamId, sizeof(escapedSteamId));
    g_Database.Escape(g_PlayerCurrentClass[client], escapedClass, sizeof(escapedClass));

    Format(query, sizeof(query), "SELECT gear, primary_weapon, secondary_weapon, explosive FROM loadouts WHERE steam_id = '%s' AND class_template = '%s'", escapedSteamId, escapedClass);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(showMessages);

    g_Database.Query(OnLoadoutRetrieved, query, pack);
}

void OnLoadoutRetrieved(Database db, DBResultSet results, const char[] error, DataPack pack)
{
    pack.Reset();
    int  userid       = pack.ReadCell();
    bool showMessages = pack.ReadCell();
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

    if (!results.FetchRow()) return;    // No saved loadout - silently do nothing

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
    ApplyLoadoutFromArrays(client, gearArray, primaryArray, secondaryArray, explosiveArray, showMessages);
}

// =====================================================
// Apply Loadout - Execute Buy Commands
// =====================================================

void ApplyLoadoutFromArrays(int client, char[][] gearArray, char[][] primaryArray, char[][] secondaryArray, char[][] explosiveArray, bool showMessages)
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
    char escapedSteamId[64];
    char escapedClass[256];
    g_Database.Escape(g_PlayerSteamId[client], escapedSteamId, sizeof(escapedSteamId));
    g_Database.Escape(g_PlayerCurrentClass[client], escapedClass, sizeof(escapedClass));

    Format(query, sizeof(query), "DELETE FROM loadouts WHERE steam_id = '%s' AND class_template = '%s'", escapedSteamId, escapedClass);

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

    char query[512];
    char escapedSteamId[64];
    g_Database.Escape(g_PlayerSteamId[client], escapedSteamId, sizeof(escapedSteamId));

    Format(query, sizeof(query), "DELETE FROM loadouts WHERE steam_id = '%s'", escapedSteamId);

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
// Utility Functions
// =====================================================

void SendFailedMessage(int client)
{
    char message[256];
    g_CvarMsgFailed.GetString(message, sizeof(message));
    CPrintToChat(client, message);
}
