// (C) 2025 LoadoutSaver sdw
// Insurgency (2014) Loadout Saving Plugin - every slot, not just the stock three.
//
// A sibling of LoadoutSaver.sp, not a replacement for it: the two register the same commands and
// must never be loaded together. The test server runs this one, main runs the original, the same
// way gg2_forceretry_optout stands in for gg2_forceretry.
//
// WHAT IS DIFFERENT
//
// The original reads exactly three weapons - GetPlayerWeaponSlot(client, 0/1/3) - and stores them
// in three fixed columns. GetPlayerWeaponSlot returns the FIRST weapon in a bucket and stops, so
// anything in another slot, and any second item sharing a bucket with those three, is dropped on
// save and therefore never restored. Two of its array bounds are also short of what the game
// actually networks:
//
//   m_EquippedGear   7 entries, read as 6  - the 7th gear slot is dropped
//   m_upgradeSlots  10 entries, read as 8  - the last two upgrades on every weapon are dropped
//
// Both counts are confirmed from the server's own send table, and the gear one matters right now:
// the NVG "misc1" slot this repo adds is exactly the kind of item that lands past the old bound.
//
// This version walks m_hMyWeapons instead, asks each weapon for its real slot through
// CBaseCombatWeapon::GetSlot (a plain virtual, offset already in insurgency.games.txt), and takes
// both array lengths from the send table rather than a #define. Every item a player is holding is
// saved whatever slot the theater invented for it.
//
// See LoadoutSaverSlots.md for the storage format and the one thing that is still unverified.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <morecolors>

#define PLUGIN_VERSION "2.0.0"

public Plugin myinfo =
{
    name        = "[INS] Loadout Saver (all slots)",
    author      = "sdw",
    description = "Save and restore player loadouts, including custom theater slots",
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
ConVar   g_CvarSkipSlots;

// Netprop offsets
int      g_EquippedGearOffset;

// CBaseCombatWeapon::GetSlot. The whole point of this variant: the authoritative slot number for a
// weapon, whatever the theater called it, rather than guessing from which bucket it was found in.
Handle   g_hGetSlot = null;

// Set once GetSlot is known good. Without it a save cannot record slots, and a loadout saved with
// every weapon claiming slot 0 would be worse than no loadout at all, so saving is refused instead.
bool     g_SlotsAvailable = false;

// m_PlayerInventory.inventory_local.m_WeaponPurchases - the list inventory_buy_upgrade indexes into.
// Read directly, because there is no other way to learn which index a weapon just landed at.
//
// Each entry is a CPlayerWeaponPurchase, 56 bytes (the stride PurchaseWeapon itself uses:
// "imul ecx, edx, 0x38"), holding { m_hWeapon, m_hUpgrades[10], m_iSlot, m_iSubSlot }. SourceMod
// hands back the offset of element 0's members only, so the rest is offset arithmetic - guarded by
// a layout check in SetupPurchaseList, which disables the lookup rather than reading nonsense.
#define PURCHASE_STRIDE       56
#define PURCHASE_MAX_ENTRIES  12
#define PURCHASE_SLOT_DELTA   44    // m_iSlot    - m_hWeapon
#define PURCHASE_SUB_DELTA    48    // m_iSubSlot - m_hWeapon

int      g_PurchaseWeaponOffset  = -1;
bool     g_PurchaseListAvailable = false;

// Supply point tracking
ConVar   g_CvarSupplyTokenBase;

// Constants
#define SAVE_COOLDOWN       3.0
#define LOAD_COOLDOWN       0.1

// Buffer sizes. One item encodes as "slot:def,up,up,..." - at most 3 + 4 + 16*4 = ~71 characters,
// and MAX_WEAPON_ITEMS of those plus separators is comfortably under the weapons buffer.
#define LOADOUT_BUFFER_SIZE 256
#define WEAPONS_BUFFER_SIZE 2048
#define ITEM_STRING_SIZE    128

// Named loadouts. The name is what the player types, so it is kept short enough to stay readable
// in chat and to fit the VARCHAR(64) column with room to spare.
#define MAX_LOADOUT_NAME    40
#define NAMED_LOADOUT_CAP   15

// Game limits. Upper bounds only - the real counts come from the send table at runtime
// (GetEntPropArraySize), which is what stops this plugin inheriting the original's two short
// bounds. These are sized above what the game networks so a future theater cannot overflow them.
#define MAX_GEAR_SLOTS      16    // send table has 7
#define MAX_WEAPON_UPGRADES 16    // send table has 10
#define MAX_WEAPON_ITEMS    16    // m_WeaponPurchases holds 12; m_hMyWeapons is 48 but most are empty
#define MAX_LOADOUT_ITEMS   (MAX_WEAPON_UPGRADES + 1)    // 1 weapon + its upgrades

// =====================================================
// Plugin Lifecycle
// =====================================================
public void OnPluginStart()
{
    CreateConVar("sm_loadoutsaverslots_version", PLUGIN_VERSION, "Loadout Saver (all slots) version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

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

    // Slot 2 - melee - is excluded, and the game is the reason rather than taste.
    // CPlayerInventory::RefundAll, which is all inventory_sell_all does, walks the purchase list and
    // skips any entry whose slot is 2 ("cmp DWORD PTR [eax+edi*1+0x30],0x2; je skip"). The knife is
    // deliberately never sold. So it is still in the inventory when a loadout is applied, and
    // re-buying it would either burn supply on a second one in the next free sub-slot or be refused
    // outright - neither of which the player asked for.
    //
    // This is also why the original plugin's positional upgrade index happened to work: the
    // surviving melee entry sits at purchase index 0, so the first weapon it bought landed at 1.
    //
    // Other slots are deliberately NOT excluded. A medic's healthkit is refunded by sell_all like
    // anything else, so re-buying it is symmetric and costs what it originally cost.
    g_CvarSkipSlots       = CreateConVar("sm_loadout_skip_slots", "2", "Comma-separated weapon slots to leave out of saved loadouts. Defaults to 2 (melee), which inventory_sell_all never sells and so must not be re-bought.");

    AutoExecConfig(true, "plugin.loadoutsaverslots");

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

    SetupGetSlot();
    SetupPurchaseList();

    // Get supply token base convar
    g_CvarSupplyTokenBase = FindConVar("mp_supply_token_base");
    if (g_CvarSupplyTokenBase == null)
        LogError("Failed to find mp_supply_token_base convar - supply validation disabled");

    // Connect to database
    ConnectDatabase();
}

// CBaseCombatWeapon::GetSlot is a plain virtual whose offset is in the shared gamedata, so this
// needs no new signature - it is the same file every other plugin here loads.
//
// That offset was WRONG when this plugin was written: the file said linux 333, which is
// GetPosition(), and GetSlot is at 332. Both return a small int, so the call would have succeeded
// and quietly recorded a weapon's position-within-slot as its slot. Corrected in
// gamedata/insurgency.games.txt, verified against _ZTV17CBaseCombatWeapon in the shipped
// server_srv.so and cross-checked at CINSPlayer::GetWeaponInSlot's own call site. Worth knowing if
// a game update ever moves it again: the failure is silent, not a crash.
//
// A missing offset is not fatal. Everything except saving still works, including loading loadouts
// that were saved while it was available, so the plugin stays up and refuses only the one operation
// it cannot do correctly.
void SetupGetSlot()
{
    Handle gameConfig = LoadGameConfigFile("insurgency.games");
    if (gameConfig == null)
    {
        LogError("Missing gamedata file \"insurgency.games\" - saving is disabled, loading still works");
        return;
    }

    StartPrepSDKCall(SDKCall_Entity);
    if (!PrepSDKCall_SetFromConf(gameConfig, SDKConf_Virtual, "GetSlot"))
    {
        delete gameConfig;
        LogError("Missing \"GetSlot\" offset in insurgency.games - saving is disabled, loading still works");
        return;
    }
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hGetSlot = EndPrepSDKCall();
    delete gameConfig;

    if (g_hGetSlot == null)
    {
        LogError("Failed to prepare CBaseCombatWeapon::GetSlot - saving is disabled, loading still works");
        return;
    }

    g_SlotsAvailable = true;
}

// Resolves the weapon purchase list and checks it is laid out the way the arithmetic below assumes.
//
// The check is the point: if a game update moves these members, the deltas stop matching and the
// lookup switches itself off instead of reading whatever happens to sit at those addresses.
void SetupPurchaseList()
{
    g_PurchaseWeaponOffset = FindSendPropInfo("CINSPlayer", "m_hWeapon");
    int slotOffset         = FindSendPropInfo("CINSPlayer", "m_iSlot");
    int subSlotOffset      = FindSendPropInfo("CINSPlayer", "m_iSubSlot");

    if (g_PurchaseWeaponOffset <= 0 || slotOffset <= 0 || subSlotOffset <= 0)
    {
        LogError("Weapon purchase list not found in the send table - upgrades will use positional indices");
        return;
    }

    if (slotOffset - g_PurchaseWeaponOffset != PURCHASE_SLOT_DELTA
        || subSlotOffset - g_PurchaseWeaponOffset != PURCHASE_SUB_DELTA)
    {
        LogError("Weapon purchase list is laid out unexpectedly (slot +%d, subslot +%d) - upgrades will use positional indices",
                 slotOffset - g_PurchaseWeaponOffset, subSlotOffset - g_PurchaseWeaponOffset);
        return;
    }

    g_PurchaseListAvailable = true;
}

// The index inventory_buy_upgrade wants for the weapon just bought, or -1 if it cannot be found.
//
// Called straight after the buy, so the newest entry for this definition is the one that just
// landed - hence the backwards scan. `claimed` rules out entries already handed to an earlier item,
// which is what keeps two of the same weapon in different sub-slots from both resolving to one
// entry. It cannot simply skip everything below the last index used: PurchaseWeapon inserts to keep
// the list in slot order rather than appending, so a later buy can land at a lower index.
int FindPurchaseIndex(int client, int weaponDef, bool[] claimed)
{
    if (!g_PurchaseListAvailable) return -1;

    for (int i = PURCHASE_MAX_ENTRIES - 1; i >= 0; i--)
    {
        if (claimed[i]) continue;

        int base = g_PurchaseWeaponOffset + i * PURCHASE_STRIDE;
        if (GetEntData(client, base) != weaponDef) continue;

        claimed[i] = true;
        return i;
    }

    return -1;
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
                      "UPDATE loadouts_slots SET last_seen_at = CURRENT_TIMESTAMP WHERE steam_id = %s",
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
                      "SELECT name, class_template FROM loadouts_slots WHERE steam_id = %s AND name IS NOT NULL ORDER BY lower(name)",
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

// Writes one weapon as "defindex,upgrade,upgrade,..." and returns its definition index, or 0 if
// the entity is not a weapon this plugin can store.
//
// The upgrade count comes from the send table rather than a constant. The original hardcoded 8;
// the game networks 10, so the last two upgrades on every weapon were being dropped on save.
int ExtractWeaponData(int weapon, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (weapon <= 0 || !IsValidEntity(weapon)) return 0;
    if (!HasEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle")) return 0;

    int weaponID = GetEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle");
    if (weaponID <= 0) return 0;

    Format(buffer, maxlen, "%d", weaponID);

    if (!HasEntProp(weapon, Prop_Send, "m_upgradeSlots")) return weaponID;

    int upgradeCount = GetEntPropArraySize(weapon, Prop_Send, "m_upgradeSlots");
    if (upgradeCount > MAX_WEAPON_UPGRADES) upgradeCount = MAX_WEAPON_UPGRADES;

    for (int i = 0; i < upgradeCount; i++)
    {
        int upgradeID = GetEntProp(weapon, Prop_Send, "m_upgradeSlots", 4, i);
        if (upgradeID > 0)
            Format(buffer, maxlen, "%s,%d", buffer, upgradeID);
    }

    return weaponID;
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

// True if sm_loadout_skip_slots names this slot.
bool IsSkippedSlot(int slot)
{
    char configured[64];
    g_CvarSkipSlots.GetString(configured, sizeof(configured));
    if (configured[0] == '\0') return false;

    char entries[16][8];
    int  count = ExplodeString(configured, ",", entries, sizeof(entries), sizeof(entries[]));

    for (int i = 0; i < count; i++)
    {
        TrimString(entries[i]);
        if (entries[i][0] == '\0') continue;

        int value;
        if (StringToIntEx(entries[i], value) && value == slot) return true;
    }

    return false;
}

int GetWeaponSlot(int weapon)
{
    if (!g_SlotsAvailable) return -1;
    return SDKCall(g_hGetSlot, weapon);
}

// Reads every gear item the player has equipped into "id;id;id".
//
// The slot count comes from the send table. The original hardcoded 6 and the game networks 7, so
// whatever sits in the last slot was being dropped - which is precisely where a theater-added slot
// such as this repo's night-vision "misc1" ends up.
void ExtractGear(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!HasEntProp(client, Prop_Send, "m_EquippedGear")) return;

    int gearCount = GetEntPropArraySize(client, Prop_Send, "m_EquippedGear");
    if (gearCount > MAX_GEAR_SLOTS) gearCount = MAX_GEAR_SLOTS;

    for (int i = 0; i < gearCount; i++)
    {
        int gearID = GetEntProp(client, Prop_Send, "m_EquippedGear", 4, i);
        if (gearID <= 0) continue;

        if (buffer[0] != '\0')
            Format(buffer, maxlen, "%s;%d", buffer, gearID);
        else
            Format(buffer, maxlen, "%d", gearID);
    }
}

// Reads every weapon the player is carrying into "slot:def,up,up;slot:def,up;...", ordered by slot.
//
// Walking m_hMyWeapons is the whole difference from the original. GetPlayerWeaponSlot answers with
// the first weapon in a bucket and offers no way to ask for the second, so three calls to it can
// only ever see three items; the backing array holds everything the player has, and GetSlot then
// says where each one actually lives.
//
// Ordering by slot is not cosmetic. It is what makes the stored list start primary, secondary,
// explosive on a stock class - the same order the original saved and bought in - so a loadout
// applies in the order the game is used to, and the upgrade indices in ApplyLoadout line up with
// what inventory_buy_upgrade expects. See LoadoutSaverSlots.md.
void ExtractWeapons(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    char items[MAX_WEAPON_ITEMS][ITEM_STRING_SIZE];
    int  slots[MAX_WEAPON_ITEMS];
    int  count = 0;

    int weaponCount = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");

    for (int i = 0; i < weaponCount && count < MAX_WEAPON_ITEMS; i++)
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon <= 0) continue;

        char data[ITEM_STRING_SIZE];
        if (ExtractWeaponData(weapon, data, sizeof(data)) <= 0) continue;

        int slot = GetWeaponSlot(weapon);
        if (slot < 0) continue;
        if (IsSkippedSlot(slot)) continue;

        // Insertion sort as we go: few enough items that anything cleverer is just more code, and
        // it keeps items within a slot in the order the array gave them.
        int at = count;
        while (at > 0 && slots[at - 1] > slot)
        {
            slots[at] = slots[at - 1];
            strcopy(items[at], sizeof(items[]), items[at - 1]);
            at--;
        }

        slots[at] = slot;
        Format(items[at], sizeof(items[]), "%d:%s", slot, data);
        count++;
    }

    for (int i = 0; i < count; i++)
    {
        if (buffer[0] != '\0')
            Format(buffer, maxlen, "%s;%s", buffer, items[i]);
        else
            strcopy(buffer, maxlen, items[i]);
    }
}

void SaveLoadoutFromEntity(int client, const char[] name)
{
    if (g_Database == null)
    {
        SendFailedMessage(client);
        return;
    }

    // Refusing to save is the right failure here. A save with no slot information would record
    // every weapon as slot 0, and loading that back would be worse than having no loadout at all.
    if (!g_SlotsAvailable)
    {
        CPrintToChat(client, "{red}[Loadout]{default} Saving is unavailable on this server right now (missing gamedata). Loading still works.");
        return;
    }

    // Validate supply points before saving
    if (!ValidateSupplyPoints(client)) return;

    char gearBuffer[LOADOUT_BUFFER_SIZE];
    char weaponsBuffer[WEAPONS_BUFFER_SIZE];

    ExtractGear(client, gearBuffer, sizeof(gearBuffer));
    ExtractWeapons(client, weaponsBuffer, sizeof(weaponsBuffer));

    // Save to database in a single query
    SaveLoadoutToDatabase(client, gearBuffer, weaponsBuffer, name);
}

// =====================================================
// Save Loadout to Database
// =====================================================

void SaveLoadoutToDatabase(int client, const char[] gearBuffer, const char[] weaponsBuffer, const char[] name)
{
    if (g_Database == null) return;

    // Build NULL-safe value strings for empty buffers
    char gearValue[LOADOUT_BUFFER_SIZE * 2 + 8];
    if (gearBuffer[0] == '\0')
        Format(gearValue, sizeof(gearValue), "NULL");
    else
        g_Database.Format(gearValue, sizeof(gearValue), "'%s'", gearBuffer);

    char weaponsValue[WEAPONS_BUFFER_SIZE * 2 + 8];
    if (weaponsBuffer[0] == '\0')
        Format(weaponsValue, sizeof(weaponsValue), "NULL");
    else
        g_Database.Format(weaponsValue, sizeof(weaponsValue), "'%s'", weaponsBuffer);

    char query[8192];

    if (name[0] == '\0')
    {
        // Class loadout: one row per player per class, upserted on the partial unique index that
        // replaced the old (steam_id, class_template) primary key.
        Format(
            query, sizeof(query),
            "INSERT INTO loadouts_slots (steam_id, class_template, name, gear, weapons, updated_at, update_count) VALUES (%s, '%s', NULL, %s, %s, CURRENT_TIMESTAMP, 1) ON CONFLICT (steam_id, class_template) WHERE name IS NULL DO UPDATE SET gear = EXCLUDED.gear, weapons = EXCLUDED.weapons, updated_at = CURRENT_TIMESTAMP, update_count = loadouts_slots.update_count + 1",
            g_PlayerSteamId[client], g_PlayerCurrentClass[client], gearValue, weaponsValue);
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
            "INSERT INTO loadouts_slots (steam_id, class_template, name, gear, weapons, updated_at, update_count) SELECT %s, '%s', %s, %s, %s, CURRENT_TIMESTAMP, 1 WHERE (SELECT COUNT(*) FROM loadouts_slots WHERE steam_id = %s AND name IS NOT NULL) < %d OR EXISTS (SELECT 1 FROM loadouts_slots WHERE steam_id = %s AND name IS NOT NULL AND lower(name) = lower(%s)) ON CONFLICT (steam_id, lower(name)) WHERE name IS NOT NULL DO UPDATE SET class_template = EXCLUDED.class_template, gear = EXCLUDED.gear, weapons = EXCLUDED.weapons, updated_at = CURRENT_TIMESTAMP, update_count = loadouts_slots.update_count + 1",
            g_PlayerSteamId[client], g_PlayerCurrentClass[client], nameValue, gearValue, weaponsValue,
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
                          "SELECT gear, weapons, class_template FROM loadouts_slots WHERE steam_id = %s AND class_template = '%s' AND name IS NULL",
                          g_PlayerSteamId[client], g_PlayerCurrentClass[client]);
    }
    else
    {
        g_Database.Format(query, sizeof(query),
                          "SELECT gear, weapons, class_template FROM loadouts_slots WHERE steam_id = %s AND name IS NOT NULL AND lower(name) = lower('%s')",
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
    // guarding - see ApplyLoadout.
    char savedClass[128];
    results.FetchString(2, savedClass, sizeof(savedClass));

    if (name[0] != '\0' && !StrEqual(savedClass, g_PlayerCurrentClass[client], false) && !g_CvarNamedCrossClass.BoolValue)
    {
        if (showMessages)
            CPrintToChat(client, "{red}[Loadout]{default} {green}%s{default} was saved on another class and cross-class loading is disabled here.", name);
        return;
    }

    char gearBuffer[LOADOUT_BUFFER_SIZE];
    char weaponsBuffer[WEAPONS_BUFFER_SIZE];
    gearBuffer[0]    = '\0';
    weaponsBuffer[0] = '\0';

    if (!results.IsFieldNull(0)) results.FetchString(0, gearBuffer, sizeof(gearBuffer));
    if (!results.IsFieldNull(1)) results.FetchString(1, weaponsBuffer, sizeof(weaponsBuffer));

    ApplyLoadout(client, gearBuffer, weaponsBuffer, showMessages, name, savedClass);
}

// =====================================================
// Apply Loadout - Execute Buy Commands
// =====================================================

// Splits a stored weapon item - "slot:def,upgrade,upgrade" - into its slot, its definition index
// and its upgrades. Returns false for anything that does not parse, so a corrupt or hand-edited row
// costs one item rather than the whole loadout.
bool ParseWeaponItem(const char[] item, int &slot, char[] defIndex, int defLen, char[][] upgrades, int maxUpgrades, int &upgradeCount)
{
    upgradeCount = 0;
    defIndex[0]  = '\0';
    slot         = -1;

    int colon = FindCharInString(item, ':');
    if (colon < 1) return false;

    char slotText[8];
    int  slotLen = colon < sizeof(slotText) ? colon : sizeof(slotText) - 1;
    strcopy(slotText, slotLen + 1, item);
    if (!StringToIntEx(slotText, slot)) return false;

    char fields[MAX_LOADOUT_ITEMS][ITEM_STRING_SIZE];
    int  fieldCount = ExplodeString(item[colon + 1], ",", fields, MAX_LOADOUT_ITEMS, sizeof(fields[]));
    if (fieldCount < 1 || fields[0][0] == '\0') return false;

    strcopy(defIndex, defLen, fields[0]);

    for (int i = 1; i < fieldCount && upgradeCount < maxUpgrades; i++)
    {
        if (fields[i][0] == '\0') continue;
        strcopy(upgrades[upgradeCount++], ITEM_STRING_SIZE, fields[i]);
    }

    return true;
}

void ApplyLoadout(int client, const char[] gearBuffer, const char[] weaponsBuffer, bool showMessages, const char[] name, const char[] savedClass)
{
    // Validate client is in game and alive
    if (!IsClientInGame(client)) return;
    if (!IsPlayerAlive(client)) return;

    // Clear current loadout
    FakeClientCommand(client, "inventory_sell_all");

    // Gear first, and that ordering is load-bearing rather than cosmetic. GetWeaponSlotCapacity is
    // 1 + the sum of the "weapon_slots" bonuses on the gear the player has equipped RIGHT NOW, so
    // until the rig and slings are back on, every weapon slot still has capacity 1 and the second
    // primary or third grenade below would be refused.
    //
    // Within gear, order does not matter - each item names the slot it belongs to.
    if (gearBuffer[0] != '\0')
    {
        char gearArray[MAX_GEAR_SLOTS][ITEM_STRING_SIZE];
        int  gearCount = ExplodeString(gearBuffer, ";", gearArray, MAX_GEAR_SLOTS, sizeof(gearArray[]));

        for (int i = 0; i < gearCount; i++)
        {
            if (gearArray[i][0] == '\0') continue;
            FakeClientCommand(client, "inventory_buy_gear %s", gearArray[i]);
        }
    }

    if (weaponsBuffer[0] != '\0')
    {
        char itemArray[MAX_WEAPON_ITEMS][ITEM_STRING_SIZE];
        int  itemCount = ExplodeString(weaponsBuffer, ";", itemArray, MAX_WEAPON_ITEMS, sizeof(itemArray[]));

        // WHY THE COMMAND HAS FOUR ARGUMENTS
        //
        // A bare "inventory_buy_weapon <def>" cannot buy a second primary, secondary or grenade. It
        // is not a restriction on the player - it is the command's defaults. The handler reads
        // args[1] as the definition, args[2] as the firemode (default -1) and args[4] as the
        // SUB-SLOT (default 0), then calls
        // CPlayerInventory::PurchaseWeapon(def, firemode, subSlot).
        //
        // Slots hold more than one item - PurchaseWeapon checks the sub-slot against
        // GetWeaponSlotCapacity(slot) - but with the sub-slot defaulting to 0 every buy targets the
        // same one, and PurchaseWeapon refunds whatever is already there before inserting. So each
        // buy REPLACES the last rather than adding to it, which is exactly the "it never bought
        // more than one" behaviour this plugin exists to fix.
        //
        // Passing -1 as the sub-slot makes PurchaseWeapon walk the existing purchases for that slot
        // and take the first free sub-slot instead. args[3] is read by nothing, so it is a
        // placeholder. Firemode -1 leaves the player's own preference alone.
        int  weaponsBought = 0;
        bool claimed[PURCHASE_MAX_ENTRIES];
        for (int i = 0; i < PURCHASE_MAX_ENTRIES; i++) claimed[i] = false;

        for (int i = 0; i < itemCount; i++)
        {
            if (itemArray[i][0] == '\0') continue;

            int  slot;
            int  upgradeCount;
            char defIndex[ITEM_STRING_SIZE];
            char upgrades[MAX_WEAPON_UPGRADES][ITEM_STRING_SIZE];

            if (!ParseWeaponItem(itemArray[i], slot, defIndex, sizeof(defIndex), upgrades, MAX_WEAPON_UPGRADES, upgradeCount))
            {
                LogError("[LoadoutSaver] %L has an unreadable loadout item \"%s\" - skipped", client, itemArray[i]);
                continue;
            }

            FakeClientCommand(client, "inventory_buy_weapon %s -1 0 -1", defIndex);
            weaponsBought++;

            if (upgradeCount < 1) continue;

            // inventory_buy_upgrade takes a position in the purchase list, which
            // PurchaseWeaponUpgrade bounds-checks as 0 <= index < purchase count. It is NOT a slot
            // and NOT the order this plugin bought things in - the list already holds whatever the
            // class template granted - so the index is read back from the list rather than counted.
            //
            // Reading it back is only possible because the buy above has already happened:
            // FakeClientCommand dispatches the ConCommand synchronously, so PurchaseWeapon has run
            // and the purchase list is up to date by the time this line executes.
            //
            // The fallback is the original plugin's positional guess, kept only so a layout change
            // degrades to today's behaviour instead of putting upgrades on an arbitrary weapon. It
            // is logged, because if it ever fires the lookup above needs fixing.
            int purchaseIndex = FindPurchaseIndex(client, StringToInt(defIndex), claimed);
            if (purchaseIndex < 0)
            {
                purchaseIndex = weaponsBought;
                LogError("[LoadoutSaver] %L: weapon %s not found in the purchase list, falling back to positional index %d",
                         client, defIndex, purchaseIndex);
            }

            for (int u = 0; u < upgradeCount; u++)
                FakeClientCommand(client, "inventory_buy_upgrade %d %s", purchaseIndex, upgrades[u]);
        }
    }

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
    // Rather than trust that silently, the result is read back: the weapons the player actually
    // ended up holding are compared against the ones the loadout asked for. Items the game refused
    // simply are not there, and the player is told how many were dropped instead of being left
    // wondering. The comparison also lands in the server log.
    //
    // The original only did this for cross-class named loadouts. Here it runs for every load, which
    // is deliberate: this variant stores items the original could not, and reading back what
    // actually arrived is the only way to find out whether an unusual slot survives the round trip.
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(showMessages);
    pack.WriteCell(name[0] != '\0' && !StrEqual(savedClass, g_PlayerCurrentClass[client], false));
    pack.WriteString(name);
    pack.WriteString(savedClass);
    pack.WriteString(weaponsBuffer);

    // Delayed on purpose, but not for the reason the original gave. FakeClientCommand is NOT
    // queued: it goes engine->ClientCommand -> CGameClient::ExecuteStringCommand -> Cmd_Dispatch ->
    // ConCommand::Dispatch, with no Cbuf_AddText anywhere on the path, so every buy above has fully
    // run by now. What is deferred is the weapon ENTITIES - the purchase list is updated
    // immediately, the items are handed out later - and ExtractWeapons reads entities.
    CreateTimer(0.5, Timer_VerifyLoadout, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

// Compares what a loadout asked for against what the player is actually holding.
public Action Timer_VerifyLoadout(Handle timer, DataPack pack)
{
    pack.Reset();
    int  userid       = pack.ReadCell();
    bool showMessages = pack.ReadCell();
    bool crossClass   = pack.ReadCell();

    char name[MAX_LOADOUT_NAME + 1];
    char savedClass[128];
    char wantedBuffer[WEAPONS_BUFFER_SIZE];
    pack.ReadString(name, sizeof(name));
    pack.ReadString(savedClass, sizeof(savedClass));
    pack.ReadString(wantedBuffer, sizeof(wantedBuffer));

    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client)) return Plugin_Handled;
    if (wantedBuffer[0] == '\0') return Plugin_Handled;

    char gotBuffer[WEAPONS_BUFFER_SIZE];
    ExtractWeapons(client, gotBuffer, sizeof(gotBuffer));

    // Compare on definition index alone. An upgrade cannot be held without its weapon, and an
    // upgrade the class may not buy is refused individually, so counting missing weapons is the
    // signal that matters to the player.
    char wanted[MAX_WEAPON_ITEMS][ITEM_STRING_SIZE];
    char got[MAX_WEAPON_ITEMS][ITEM_STRING_SIZE];
    int  wantedCount = ExplodeString(wantedBuffer, ";", wanted, MAX_WEAPON_ITEMS, sizeof(wanted[]));
    int  gotCount    = ExplodeString(gotBuffer, ";", got, MAX_WEAPON_ITEMS, sizeof(got[]));

    bool matched[MAX_WEAPON_ITEMS];
    for (int i = 0; i < MAX_WEAPON_ITEMS; i++) matched[i] = false;
    int dropped = 0;

    for (int i = 0; i < wantedCount; i++)
    {
        char wantDef[ITEM_STRING_SIZE];
        if (!ItemDefIndex(wanted[i], wantDef, sizeof(wantDef))) continue;

        bool found = false;
        for (int j = 0; j < gotCount && !found; j++)
        {
            if (matched[j]) continue;

            char gotDef[ITEM_STRING_SIZE];
            if (!ItemDefIndex(got[j], gotDef, sizeof(gotDef))) continue;
            if (!StrEqual(gotDef, wantDef)) continue;

            matched[j] = true;
            found      = true;
        }

        if (!found) dropped++;
    }

    if (dropped > 0 || crossClass)
    {
        LogMessage("[LoadoutSaver] %L loaded \"%s\" (saved on %s) while playing %s: wanted [%s], got [%s], %d missing",
                   client, name[0] == '\0' ? "<class loadout>" : name, savedClass, g_PlayerCurrentClass[client],
                   wantedBuffer, gotBuffer, dropped);
    }

    if (dropped > 0 && showMessages)
    {
        if (name[0] == '\0')
            CPrintToChat(client, "{red}[Loadout]{default} %d item(s) in your saved loadout are not available and were not equipped.", dropped);
        else
            CPrintToChat(client, "{red}[Loadout]{default} %d item(s) in {green}%s{default} are not available to this class and were not equipped.", dropped, name);
    }

    return Plugin_Handled;
}

// Pulls the definition index out of a stored "slot:def,upgrade,..." item.
bool ItemDefIndex(const char[] item, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    int colon = FindCharInString(item, ':');
    if (colon < 0) return false;

    strcopy(buffer, maxlen, item[colon + 1]);

    int comma = FindCharInString(buffer, ',');
    if (comma != -1) buffer[comma] = '\0';

    return buffer[0] != '\0';
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
    g_Database.Format(query, sizeof(query), "DELETE FROM loadouts_slots WHERE steam_id = %s AND class_template = '%s' AND name IS NULL", g_PlayerSteamId[client], g_PlayerCurrentClass[client]);

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
    g_Database.Format(query, sizeof(query), "DELETE FROM loadouts_slots WHERE steam_id = %s AND name IS NULL", g_PlayerSteamId[client]);

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
                          "DELETE FROM loadouts_slots WHERE steam_id = %s AND name IS NOT NULL",
                          g_PlayerSteamId[client]);
    }
    else
    {
        g_Database.Format(query, sizeof(query),
                          "DELETE FROM loadouts_slots WHERE steam_id = %s AND name IS NOT NULL AND lower(name) = lower('%s')",
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
