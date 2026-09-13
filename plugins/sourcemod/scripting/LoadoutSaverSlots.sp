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
// Both counts are confirmed from the server's own send table. This version takes each bound from
// GetEntPropArraySize rather than a #define, so it covers whichever slots a theater actually uses -
// which matters here, because this repo puts gear in "misc1", a slot no stock content touches.
//
// This version reads the purchase list - m_WeaponPurchases - as its first source, and only falls back
// to walking m_hMyWeapons when that is empty. The purchase list records one entry per buy with its
// slot, sub-slot and upgrade ids, so it sees things the entity view cannot: a stack of grenades is one
// entity however many are held, and entities are not handed out until the next spawn, so a save taken
// between a buy and that spawn read the previous loadout. Array lengths come from the send table
// rather than a #define, so every item is saved whatever slot the theater invented for it.
//
// STORAGE
//
// Items are stored by NAME, not by the theater's id. Theater ids are assigned at parse time and
// shift whenever the theater is edited, so a stored id keeps resolving after a theater change - to
// a different item. gg2_theater_items turns names back into ids for whatever theater is loaded.
// An item the theater no longer defines resolves to nothing, is skipped, and starts working again
// if it ever comes back.
//
// The schema is normalised into loadouts_slots (the set), loadout_items (one row per item) and
// theater_items (the names). See loadout_saver_slots.sql for why - it is integrity and
// queryability, not space.
//
// See LoadoutSaverSlots.md for the rest.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <morecolors>
#include <theateritems>

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

// Both of these are filled in by an event - OnClientAuthorized for the id, player_pick_squad for
// the class - so a plugin that was not loaded when they fired (a hot reload, or a late load) has
// neither for anyone already in game. An empty id builds "WHERE steam_id =  AND ..." and Postgres
// rejects the statement; an empty class makes every command answer "Select a class first!". Both
// are recovered on demand instead of being left to the next round.
//
// The id is easy, GetClientAuthId works at any time. The class is not: m_nCurrentClassTemplateHandle holds
// the class as an id, always, but nothing in the game or the support library maps that id back to a
// name (gg2_theater_items deliberately leaves the class template table out; Ins_GetPlayerClass is
// declared in insurgencydy.inc but never implemented).
//
// So the mapping is learned from the events that do carry both. One observation of a class covers
// every other player on it, which is what gets players already in game past a reload. It is not
// persisted - nothing here is worth a file, and after a restart every player reconnects and the
// events fire again anyway. Handles are assigned per theater, so it is dropped on a theater change.
StringMap g_ClassByHandle = null;

// m_PlayerInventory.m_nCurrentClassTemplateHandle - 8 bits unsigned, so it must be read one byte
// wide. Ids are 1-based like every other theater id, making 0 "none".
#define CLASS_HANDLE_PROP   "m_nCurrentClassTemplateHandle"
#define CLASS_HANDLE_BYTES  1

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
ConVar   g_CvarDebug;

// Netprop offsets
int      g_EquippedGearOffset;

// CBaseCombatWeapon::GetSlot. The whole point of this variant: the authoritative slot number for a
// weapon, whatever the theater called it, rather than guessing from which bucket it was found in.
Handle   g_hGetSlot = null;

// Set once GetSlot is known good. Without it a save cannot record slots, and a loadout saved with
// every weapon claiming slot 0 would be worse than no loadout at all, so saving is refused instead.
bool     g_SlotsAvailable = false;

// m_WeaponPurchases - one entry per weapon BOUGHT, which is the only place a stack of grenades is
// still several things. It is a CUtlVector<CPlayerWeaponPurchase> at CPlayerInventory + 0x34, and it
// has to be read through that vector rather than through the send table.
//
// WHY NOT THE SEND TABLE
//
// Everything under m_PlayerInventory sits behind a datatable proxy, and a proxy table reports offset
// 0, so FindSendPropInfo returns "m_PlayerInventory + local offset" for every prop nested under it
// regardless of which proxy it belongs to. Measured on this build:
//
//     m_PlayerInventory   7660
//     m_hWeapon           7664  (base +4)     m_iSlot     7708  (base +48)
//     m_nAvailableTokens  7668  (base +8)     m_iSubSlot  7712  (base +52)
//     m_EquippedGear      7676  (base +16)
//
// m_nAvailableTokens and m_EquippedGear fall inside what a 56 byte entry at 7660 would occupy, so
// those offsets cannot all describe real memory. Walking them as an array reads the token counts and
// the gear array and calls the result a purchase list. A delta check between the three passes anyway,
// because they are consistent with each other - it is not evidence that the base is right.
//
// WHERE THE NUMBERS COME FROM
//
// The SendPropUtlVector registration for "m_WeaponPurchases" (0x2ccc80 in server.so) carries all
// three as immediates:
//
//     movl $0x34   offset of the CUtlVector inside CPlayerInventory   = 52
//     movl $0x38   sizeof(CPlayerWeaponPurchase)                      = 56
//     movl $0xc    max elements                                       = 12
//
// The stride also matches PurchaseWeapon's own "imul ecx, edx, 0x38", which is what makes the offset
// trustworthy. CPlayerInventory is derived from a prop whose local offset is known and cross-checked
// against a second one - see SetupInventoryOffset.
//
// ENTRY LAYOUT, confirmed against a live player
//
// CPlayerWeaponPurchase is polymorphic, so +0 is the vtable pointer and reads as the same value in
// every entry. +4 is named m_hWeapon but holds the weapon DEFINITION id - the same 7-bit value as
// m_hWeaponDefinitionHandle on the entity, verified by every entry matching a carried weapon
// (0x4c -> 76 -> weapon_m4a1sopmod). There is no entity handle in the struct.
#define PURCHASE_STRIDE       56
#define PURCHASE_MAX_ENTRIES  12
#define INV_VECTOR_OFFSET     0x34    // CUtlVector<CPlayerWeaponPurchase> within CPlayerInventory
#define UTLVEC_MEMORY         0x00    // T* m_Memory.m_pMemory
#define UTLVEC_SIZE           0x0c    // int m_Size
#define PURCHASE_WEAPON       0x04    // weapon definition id
#define PURCHASE_UPGRADES     0x08    // int[10] upgrade ids
#define PURCHASE_SLOT         0x30
#define PURCHASE_SUBSLOT      0x34
#define MIN_POINTER           0x10000

int      g_InventoryOffset = -1;

// Supply point tracking
ConVar   g_CvarSupplyTokenBase;
ConVar   g_CvarSupplyPlayerTokens;
bool     g_bSupplyPlayerTokensChecked = false;

// Constants
#define SAVE_COOLDOWN       3.0
#define LOAD_COOLDOWN       0.1

#define ITEM_NAME_SIZE      64

// One saved item. slot is the weapon slot for weapons and -1 for everything else; parent is the
// ordinal of the weapon an upgrade belongs to, and -1 otherwise.
//
// Position in the array IS the ordinal, and it is load-bearing rather than cosmetic: the apply path
// buys in this order and reads each weapon's purchase index back afterwards, so two grenades sharing
// a slot have to go back in the order they were saved.
enum struct LoadoutItem
{
    int  category;              // TheaterCategory
    char name[ITEM_NAME_SIZE];
    int  slot;
    int  parent;
    // How many times this was BOUGHT, not how many rounds it yielded - see quantity in
    // loadout_saver_slots.sql. Always 1 for gear and upgrades.
    int  quantity;
}

// Named loadouts. The name is what the player types, so it is kept short enough to stay readable
// in chat and to fit the VARCHAR(64) column with room to spare.
#define MAX_LOADOUT_NAME    40
// The last load that did not fully apply, so a save cannot quietly overwrite the set it came from.
// Losing items on load is recoverable - the stored set is still right - but saving afterwards writes
// the truncated result back and the original is gone. That has already happened once: a load short
// of supply dropped two explosives, the next !savelo recorded what was left, and the set has been
// wrong ever since.
int      g_LastLoadDropped[MAXPLAYERS + 1];
char     g_LastLoadName[MAXPLAYERS + 1][MAX_LOADOUT_NAME + 1];
bool     g_OverwriteConfirmed[MAXPLAYERS + 1];
#define NAMED_LOADOUT_CAP   15

// Game limits. Upper bounds only - the real counts come from the send table at runtime
// (GetEntPropArraySize), which is what stops this plugin inheriting the original's two short
// bounds. These are sized above what the game networks so a future theater cannot overflow them.
// m_EquippedGear and m_upgradeSlots are both 8-bit SendProps (verified from their registrations in
// server.so: nbits=8), so 255 is the maximum value the field can hold and is the engine's marker for
// an empty slot. Treating it as a real id is what produced 40+ "the theater cannot name" lines on
// every save - one per unused gear and upgrade slot.
#define THEATER_ID_NONE     255

#define MAX_GEAR_SLOTS      16    // send table has 7
#define MAX_WEAPON_UPGRADES 16    // send table has 10
#define MAX_WEAPON_ITEMS    16    // m_WeaponPurchases holds 12; m_hMyWeapons is 48 but most are empty
#define MAX_LOADOUT_ITEMS   (MAX_WEAPON_UPGRADES + 1)    // 1 weapon + its upgrades

// Every weapon with a full set of upgrades, plus every gear slot.
#define MAX_ITEMS           (MAX_WEAPON_ITEMS * (MAX_WEAPON_UPGRADES + 1) + MAX_GEAR_SLOTS)

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

    // Logs the supply and slot position of every buy the apply path makes. Off by default; the only
    // way to tell an item refused for cost from one refused for the class is to watch it happen.
    g_CvarDebug = CreateConVar("sm_loadout_debug", "0", "Log every purchase the apply path makes, with supply before and after.", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "plugin.loadoutsaverslots");

    // Register commands
    RegConsoleCmd("sm_savelo", Command_SaveLoadout, "Save your loadout for this class, or under a name: sm_savelo <name>");
    RegConsoleCmd("sm_clearlo", Command_ClearLoadout, "Clear this class's saved loadout (use 'all' for every class)");
    RegConsoleCmd("sm_loadlo", Command_LoadLoadout, "Load this class's saved loadout, or a named one: sm_loadlo <name>");
    RegConsoleCmd("inventory_reset", Command_InventoryReset, "Hook reset button to load saved loadout");

    // TEMPORARY DIAGNOSTIC - why does the Benelli M4 (weapon_m1014) spawn with no reserve shells
    // when its theater clip_default is 18? Reads the real numbers off every carried weapon so the
    // question can be answered from observation instead of from theater arithmetic. Remove once
    // answered.
    // Localisation files are mounted by the engine and do not change between maps, so once is enough.
    LoadWeaponNames();

    RegServerCmd("ammo_probe", Command_AmmoProbe, "TEMPORARY: dump clip/reserve ammo for every player's weapons");

    RegAdminCmd("sm_loadout_dumppurchases", Command_DumpPurchases, ADMFLAG_CONFIG,
                "sm_loadout_dumppurchases [#userid|name] - print the raw purchase list for a player");

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

    g_ClassByHandle = new StringMap();

    // Find netprop offsets
    g_EquippedGearOffset = FindSendPropInfo("CINSPlayer", "m_EquippedGear");
    if (g_EquippedGearOffset == -1)
        SetFailState("Failed to find m_EquippedGear offset!");

    SetupGetSlot();
    SetupInventoryOffset();

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
// Absolute offset of m_PlayerInventory, derived twice and only accepted if both agree.
// m_nAvailableTokens is at +8 of inventory_local and m_EquippedGear at +16, both read off the send
// table dump, and inventory_local sits at +0 of m_PlayerInventory.
void SetupInventoryOffset()
{
    int fromTokens = FindSendPropInfo("CINSPlayer", "m_nAvailableTokens");
    int fromGear   = FindSendPropInfo("CINSPlayer", "m_EquippedGear");

    if (fromTokens <= 0 || fromGear <= 0)
    {
        LogError("[LoadoutSaver] cannot locate m_PlayerInventory - purchase list unavailable");
        return;
    }

    if (fromTokens - 8 != fromGear - 16)
    {
        LogError("[LoadoutSaver] m_PlayerInventory disagrees (%d vs %d) - purchase list unavailable",
                 fromTokens - 8, fromGear - 16);
        return;
    }

    g_InventoryOffset = fromTokens - 8;
    LogMessage("[LoadoutSaver] m_PlayerInventory at +%d, purchase vector at +%d",
               g_InventoryOffset, g_InventoryOffset + INV_VECTOR_OFFSET);
}

// The purchase list as {count, base address}, or count 0 if it cannot be read safely.
int GetPurchaseList(int client, Address &base)
{
    base = Address_Null;
    if (g_InventoryOffset < 0) return 0;

    int vec = g_InventoryOffset + INV_VECTOR_OFFSET;
    int ptr = GetEntData(client, vec + UTLVEC_MEMORY);
    int n   = GetEntData(client, vec + UTLVEC_SIZE);

    // Never dereference anything unchecked: a wrong offset here takes the server down rather than
    // returning nonsense. A real list is a plausible pointer and at most the networked element count.
    if (ptr < MIN_POINTER || n <= 0 || n > PURCHASE_MAX_ENTRIES) return 0;

    base = view_as<Address>(ptr);
    return n;
}

// The index inventory_buy_upgrade wants for the weapon just bought, or -1 if it cannot be found.
//
// Called straight after the buy, so the newest entry for this definition is the one that just landed -
// hence the backwards scan. `claimed` rules out entries already handed to an earlier item, which is
// what keeps two of the same weapon in different sub-slots from both resolving to one entry. It cannot
// simply skip everything below the last index used: PurchaseWeapon inserts to keep the list in slot
// order rather than appending, so a later buy can land at a lower index.
int FindPurchaseIndex(int client, int weaponDef, bool[] claimed)
{
    Address base;
    int count = GetPurchaseList(client, base);
    if (count <= 0) return -1;

    for (int i = count - 1; i >= 0; i--)
    {
        if (claimed[i]) continue;

        Address e = base + view_as<Address>(i * PURCHASE_STRIDE + PURCHASE_WEAPON);
        if (LoadFromAddress(e, NumberType_Int32) != weaponDef) continue;

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
    g_LastLoadDropped[client]       = 0;
    g_LastLoadName[client][0]       = '\0';
    g_OverwriteConfirmed[client]    = false;

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
    g_LastLoadDropped[client]       = 0;
    g_LastLoadName[client][0]       = '\0';
    g_OverwriteConfirmed[client]    = false;
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

    // Deliberately here rather than in the event: the handle is read off the player, and by now the
    // spawn the event announced has actually happened.
    LearnPlayerClass(client);

    LoadPlayerLoadout(client, false, "");    // Auto-load silently, this class only
    return Plugin_Handled;
}

// =====================================================
// Class handle <-> name
// =====================================================

// A theater change reassigns the handles, so anything learned under the old one is now wrong.
public void TheaterItems_OnReady()
{
    if (g_ClassByHandle != null)
        g_ClassByHandle.Clear();
}

int GetPlayerClassHandle(int client)
{
    if (!IsClientInGame(client)) return 0;
    return GetEntProp(client, Prop_Send, CLASS_HANDLE_PROP, CLASS_HANDLE_BYTES);
}

// Record what this player's class id is called, for the benefit of a later load that only has the id.
void LearnPlayerClass(int client)
{
    if (g_ClassByHandle == null || g_PlayerCurrentClass[client][0] == '\0') return;

    int handle = GetPlayerClassHandle(client);
    if (handle <= 0) return;

    char key[16];
    IntToString(handle, key, sizeof(key));
    g_ClassByHandle.SetString(key, g_PlayerCurrentClass[client]);
}

// True if this player's Steam id is known, fetching it if the authorize event was missed.
bool EnsureSteamId(int client)
{
    if (g_PlayerSteamId[client][0] != '\0') return true;
    if (!IsClientAuthorized(client)) return false;

    return GetClientAuthId(client, AuthId_SteamID64, g_PlayerSteamId[client], sizeof(g_PlayerSteamId[]));
}

// True if this player's class is known. Fills it in from the learned map when the event that would
// normally have supplied it was missed.
bool ResolvePlayerClass(int client)
{
    if (g_PlayerCurrentClass[client][0] != '\0') return true;
    if (g_ClassByHandle == null) return false;

    int handle = GetPlayerClassHandle(client);
    if (handle <= 0) return false;

    char key[16];
    IntToString(handle, key, sizeof(key));

    if (!g_ClassByHandle.GetString(key, g_PlayerCurrentClass[client], sizeof(g_PlayerCurrentClass[])))
        return false;

    return true;
}

// =====================================================
// Player Commands
// =====================================================
public Action Command_SaveLoadout(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Handled;

    if (!EnsureSteamId(client))
    {
        SendFailedMessage(client);
        return Plugin_Handled;
    }

    if (!ResolvePlayerClass(client))
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

    // Refuse the save that would destroy the set the player just failed to load, and say why. The
    // second attempt goes through, so this costs one extra command when overwriting really is meant
    // and prevents silent data loss when it is not.
    if (g_LastLoadDropped[client] > 0 && StrEqual(name, g_LastLoadName[client], false)
        && !g_OverwriteConfirmed[client])
    {
        g_OverwriteConfirmed[client] = true;

        if (name[0] == '\0')
            CPrintToChat(client, "{red}[Loadout]{default} %d item(s) from your last load are missing, so saving now would lose them. Run it again to overwrite anyway.", g_LastLoadDropped[client]);
        else
            CPrintToChat(client, "{red}[Loadout]{default} %d item(s) from your last load of {green}%s{default} are missing, so saving now would lose them. Run it again to overwrite anyway.", g_LastLoadDropped[client], name);

        return Plugin_Handled;
    }

    g_LastLoadDropped[client]    = 0;
    g_OverwriteConfirmed[client] = false;

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
    if (!EnsureSteamId(client))
    {
        SendFailedMessage(client);
        return Plugin_Handled;
    }

    if (!ResolvePlayerClass(client))
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

    if (!EnsureSteamId(client))
    {
        SendFailedMessage(client);
        return Plugin_Handled;
    }

    // Check cooldown
    float cooldown = g_CvarLoadCooldown.FloatValue;
    if (GetGameTime() - g_LastLoadTime[client] < cooldown) return Plugin_Handled;

    char name[MAX_LOADOUT_NAME + 1];
    if (!ReadLoadoutName(client, args, name, sizeof(name))) return Plugin_Handled;

    // The class is only needed to pick WHICH set to load, and a name already does that. It is still
    // required for a class loadout, and for the cross-class check when that is disabled - so the gate
    // moves here from the top of the command rather than disappearing.
    //
    // Worth the distinction because the class is the one thing the plugin cannot always recover: it
    // is learned from player_pick_squad, so a reload leaves it unknown until someone picks again, and
    // refusing a named load for a class it does not need made every reload look like a broken load.
    if ((name[0] == '\0' || !g_CvarNamedCrossClass.BoolValue) && !ResolvePlayerClass(client))
    {
        CPrintToChat(client, "{red}[Loadout]{default} Select a class first!");
        return Plugin_Handled;
    }

    LoadPlayerLoadout(client, true, name);    // Manual load with messages
    g_LastLoadTime[client] = GetGameTime();
    return Plugin_Handled;
}

public Action Command_ListLoadouts(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Handled;

    if (g_Database == null || !EnsureSteamId(client))
    {
        SendFailedMessage(client);
        return Plugin_Handled;
    }

    // Each set is listed with a two-weapon preview, so a name on its own does not have to carry the
    // whole memory of what is in it. row_number picks the first two by ordinal - ordinal is buy
    // order, so these really are the first two things bought - and category 0 keeps it to weapons,
    // leaving out gear and upgrades, which are not what identifies a loadout at a glance.
    //
    // LEFT JOIN, not an inner one: a set with no weapons in it (gear only, or every weapon dropped
    // from the theater since it was saved) still has to appear in the list, with a NULL preview.
    char query[640];
    g_Database.Format(query, sizeof(query),
                      "SELECT l.name, string_agg(x.wname, ', ' ORDER BY x.ordinal) AS preview FROM loadouts_slots l LEFT JOIN (SELECT li.loadout_id, li.ordinal, ti.name AS wname, row_number() OVER (PARTITION BY li.loadout_id ORDER BY li.ordinal) AS rn FROM loadout_items li JOIN theater_items ti ON ti.id = li.item_id WHERE ti.category = 0) x ON x.loadout_id = l.id AND x.rn <= 2 WHERE l.steam_id = %s AND l.name IS NOT NULL GROUP BY l.id, l.name ORDER BY lower(l.name)",
                      g_PlayerSteamId[client]);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));

    g_Database.Query(OnLoadoutsListed, query, pack);
    return Plugin_Handled;
}

public Action Command_DeleteLoadout(int client, int args)
{
    if (client < 1 || IsFakeClient(client)) return Plugin_Handled;

    if (!EnsureSteamId(client))
    {
        SendFailedMessage(client);
        return Plugin_Handled;
    }

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

// Prints the purchase vector next to what the player is actually carrying, which is the only way to
// confirm that entry +0 is the weapon definition id - the 4 bytes DT_WeaponPurchases never names.
// A command rather than a hook in the save path, because every gate on !savelo (class, cooldown, the
// overwrite guard) runs before the collection does.
// TEMPORARY. See the registration comment.
public Action Command_AmmoProbe(int args)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        // Bots INCLUDED deliberately: insurgent bots carry weapon_toz, which shares the 4buckshot
        // ammo type with the m1014, and that is the only same-ammo-type comparison available.
        if (!IsClientInGame(client)) continue;

        // Reserve ammo is granted by GEAR, not by the weapon: TUG's vests carry an "extra_ammo" block
        // keyed by weapon slot (primary / secondary / explosive). Dump what is equipped alongside the
        // ammo so the two can be correlated - a shotgun is a "secondary", so if the vest grants
        // secondary ammo and the shotgun still has none, the weapon slot is not the whole story.
        char gearList[256];
        if (HasEntProp(client, Prop_Send, "m_EquippedGear"))
        {
            int slots = GetEntPropArraySize(client, Prop_Send, "m_EquippedGear");
            for (int g = 0; g < slots; g++)
            {
                int id = GetEntProp(client, Prop_Send, "m_EquippedGear", 1, g) & 0xFF;
                if (id == 0 || id == 255) continue;

                char nm[64];
                if (!TheaterItem_Name(TheaterCategory_Gear, id, nm, sizeof(nm)))
                    Format(nm, sizeof(nm), "id%d", id);

                if (gearList[0] != '\0') StrCat(gearList, sizeof(gearList), " ");
                char entry[80];
                Format(entry, sizeof(entry), "%d:%s", g, nm);
                StrCat(gearList, sizeof(gearList), entry);
            }
        }
        PrintToServer("[AMMO PROBE] --- %N (bot=%d alive=%d) gear: %s ---",
                      client, IsFakeClient(client), IsPlayerAlive(client), gearList[0] == '\0' ? "(none)" : gearList);

        int carried = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
        for (int i = 0; i < carried; i++)
        {
            int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
            if (w <= 0 || !IsValidEntity(w)) continue;

            char cls[64];
            GetEntityClassname(w, cls, sizeof(cls));

            int clip = GetEntProp(w, Prop_Send, "m_iClip1");

            // m_iPrimaryAmmoType is ONE BYTE, so anything over 127 sign-extends negative on a plain
            // read - mask it back to unsigned before using it as an index.
            int ammoType = GetEntProp(w, Prop_Send, "m_iPrimaryAmmoType") & 0xFF;

            int slots   = GetEntPropArraySize(client, Prop_Send, "m_iAmmo");
            int reserve = -1;
            if (ammoType < slots)
                reserve = GetEntProp(client, Prop_Send, "m_iAmmo", 4, ammoType);

            PrintToServer("[AMMO PROBE]   %-28s clip=%-4d ammoType=%-4d reserve=%-5d (m_iAmmo slots=%d)",
                          cls, clip, ammoType, reserve, slots);
        }
    }
    return Plugin_Handled;
}

public Action Command_DumpPurchases(int client, int args)
{
    char arg[MAX_NAME_LENGTH];
    int  target = -1;

    if (args >= 1)
    {
        GetCmdArg(1, arg, sizeof(arg));
        target = FindTarget(client, arg, true, false);
        if (target < 1) return Plugin_Handled;
    }
    else
    {
        for (int i = 1; i <= MaxClients && target < 1; i++)
            if (IsClientInGame(i) && !IsFakeClient(i)) target = i;
    }

    if (target < 1)
    {
        ReplyToCommand(client, "[Loadout] no human player in game");
        return Plugin_Handled;
    }

    Address base;
    int count = GetPurchaseList(target, base);
    ReplyToCommand(client, "[Loadout] %N: inventory +%d, vector +%d, count %d, base 0x%x",
                   target, g_InventoryOffset, g_InventoryOffset + INV_VECTOR_OFFSET, count, base);

    for (int i = 0; i < count; i++)
    {
        Address e = base + view_as<Address>(i * PURCHASE_STRIDE);
        int raw   = LoadFromAddress(e + view_as<Address>(PURCHASE_WEAPON), NumberType_Int32);
        int slot  = LoadFromAddress(e + view_as<Address>(PURCHASE_SLOT), NumberType_Int32);
        int sub   = LoadFromAddress(e + view_as<Address>(PURCHASE_SUBSLOT), NumberType_Int32);

        // A CBaseHandle is (serial << 12) | index on this build; -1 means the purchase has been made
        // but the entity not handed out yet, which is the mid-round case.
        int ent = (raw == -1) ? -1 : (raw & 0xFFF);
        char nm[ITEM_NAME_SIZE];
        strcopy(nm, sizeof(nm), "<no entity>");
        if (ent > 0 && ent <= 2048 && IsValidEntity(ent)
            && HasEntProp(ent, Prop_Send, "m_hWeaponDefinitionHandle"))
        {
            int id = GetEntProp(ent, Prop_Send, "m_hWeaponDefinitionHandle");
            if (!TheaterItem_Name(TheaterCategory_Weapon, id, nm, sizeof(nm)))
                Format(nm, sizeof(nm), "def%d", id);
        }

        char ups[192];
        for (int u = 0; u < 10; u++)
        {
            int id = LoadFromAddress(e + view_as<Address>(PURCHASE_UPGRADES + u * 4), NumberType_Int32);
            if (id <= 0 || id == THEATER_ID_NONE) continue;
            char un[ITEM_NAME_SIZE];
            if (!TheaterItem_Name(TheaterCategory_Upgrade, id, un, sizeof(un))) Format(un, sizeof(un), "id%d", id);
            Format(ups, sizeof(ups), "%s%s%s", ups, ups[0] == '\0' ? "" : ",", un);
        }
        ReplyToCommand(client, "[Loadout]   [%d] def=%d slot=%d sub=%d upgrades=[%s]", i, raw, slot, sub, ups);
    }

    // The entity view, to match against.
    int carried = GetEntPropArraySize(target, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < carried; i++)
    {
        int w = GetEntPropEnt(target, Prop_Send, "m_hMyWeapons", i);
        if (w <= 0 || !IsValidEntity(w)) continue;
        if (!HasEntProp(w, Prop_Send, "m_hWeaponDefinitionHandle")) continue;

        int id = GetEntProp(w, Prop_Send, "m_hWeaponDefinitionHandle");
        if (id <= 0) continue;

        char nm[ITEM_NAME_SIZE];
        if (!TheaterItem_Name(TheaterCategory_Weapon, id, nm, sizeof(nm))) strcopy(nm, sizeof(nm), "?");

        char ups[192];
        if (HasEntProp(w, Prop_Send, "m_upgradeSlots"))
        {
            int n = GetEntPropArraySize(w, Prop_Send, "m_upgradeSlots");
            for (int u = 0; u < n; u++)
            {
                int uid = GetEntProp(w, Prop_Send, "m_upgradeSlots", 4, u);
                if (uid <= 0 || uid == THEATER_ID_NONE) continue;
                char un[ITEM_NAME_SIZE];
                if (!TheaterItem_Name(TheaterCategory_Upgrade, uid, un, sizeof(un))) Format(un, sizeof(un), "id%d", uid);
                Format(ups, sizeof(ups), "%s%s%s", ups, ups[0] == '\0' ? "" : ",", un);
            }
        }
        ReplyToCommand(client, "[Loadout]   entity %s slot=%d upgrades=[%s]", nm, GetWeaponSlot(w), ups);
    }

    return Plugin_Handled;
}

// =====================================================
// Entity Inspection - Read Loadout from Player
// =====================================================

// What a player actually spawns with, which is not necessarily mp_supply_token_base.
//
// gg2_supply raises m_nRecievedTokens to sm_supply_player_tokens on spawn (100 by default, against
// a mp_supply_token_base of 10 here), and only ever raises it, so the effective starting supply is
// the larger of the two. Validating against the cvar alone rejected every loadout costing more than
// 10 - which is nearly all of them - and did so invisibly, because before gg2_supply has run the
// two values are equal and the check passes trivially.
//
// Looked up lazily rather than in OnPluginStart: gg2_supply may not have created its convar yet
// when this plugin loads.
int GetStartingSupply()
{
    if (!g_bSupplyPlayerTokensChecked)
    {
        g_CvarSupplyPlayerTokens     = FindConVar("sm_supply_player_tokens");
        g_bSupplyPlayerTokensChecked = true;
    }

    int starting = g_CvarSupplyTokenBase.IntValue;
    if (g_CvarSupplyPlayerTokens != null && g_CvarSupplyPlayerTokens.IntValue > starting)
        starting = g_CvarSupplyPlayerTokens.IntValue;

    return starting;
}

bool ValidateSupplyPoints(int client)
{
    if (g_CvarSupplyTokenBase == null) return true;    // Skip validation if convar not found

    int availableTokens = GetEntProp(client, Prop_Send, "m_nAvailableTokens");
    int receivedTokens  = GetEntProp(client, Prop_Send, "m_nRecievedTokens");
    int startingSupply  = GetStartingSupply();

    // Refuse a loadout the player could not have afforded at spawn - it would only fail to apply
    // on load. What they have spent is everything received that is no longer available, so bonus
    // supply earned during the round is what this catches.
    int spent = receivedTokens - availableTokens;
    if (spent > startingSupply)
    {
        char message[256];
        g_CvarMsgSupplyError.GetString(message, sizeof(message));

        char startingStr[16];
        IntToString(startingSupply, startingStr, sizeof(startingStr));
        ReplaceString(message, sizeof(message), "{1}", startingStr);

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

// Collects everything the player is carrying into the item list that gets stored.
//
// Names, not ids: gg2_theater_items turns each runtime id back into the theater name. An item the
// lookup cannot name is dropped with a log line rather than stored as a number that will mean
// something else after the next theater edit.
int CollectItems(int client, LoadoutItem[] items, int maxItems)
{
    int count = 0;

    // Gear first in the list because it is applied first - weapon slot capacity is computed from
    // the gear currently worn, so the rig and slings have to be back on before the extra weapons
    // are bought. The count comes from the send table, not a constant: the game networks 7 slots
    // and the original plugin read 6.
    if (HasEntProp(client, Prop_Send, "m_EquippedGear"))
    {
        int gearCount = GetEntPropArraySize(client, Prop_Send, "m_EquippedGear");

        for (int i = 0; i < gearCount && count < maxItems; i++)
        {
            int gearId = GetEntProp(client, Prop_Send, "m_EquippedGear", 4, i);
            if (gearId <= 0 || gearId == THEATER_ID_NONE) continue;

            LoadoutItem item;
            if (!TheaterItem_Name(TheaterCategory_Gear, gearId, item.name, sizeof(item.name)))
            {
                LogError("[LoadoutSaver] %L has gear id %d the theater cannot name - not saved", client, gearId);
                continue;
            }

            item.category = view_as<int>(TheaterCategory_Gear);
            item.slot     = -1;
            item.parent   = -1;
            item.quantity = 1;
            items[count++] = item;
        }
    }

    // Weapons: the purchase list when it has anything, the carried entities otherwise. NEITHER source
    // is right on its own, and both failures have been seen on this server.
    //
    // The purchase list is one entry per buy, correct the instant the buy is made, and carries the
    // definition id, slot, sub-slot and upgrade ids. It is the only source that can see a stack:
    // "clip_max_rounds" "-1" collapses however many grenades a player holds into ONE weapon_m67 entity
    // with the count in reserve ammo, so the entity view can only ever report one of them. It is also
    // the only source that is right between a buy and the next spawn - inventory_buy_weapon records and
    // charges immediately while the item is handed out later, so a save in that window read the
    // PREVIOUS loadout, or nothing at all when the player was dead.
    //
    // But it is empty after a map change, while the player still holds everything: count 0, base
    // 0x00000000, seven weapons in hand. Saving from it alone wrote three gear rows and no weapons.
    //
    // So: prefer it, fall back to walking m_hMyWeapons. The fallback cannot recover quantity - one
    // entity is one row - which is the one thing that degrades, and it says so in the log.
    int afterGear = count;

    count = CollectWeaponsFromPurchases(client, items, maxItems, count);
    if (count == afterGear)
        count = CollectWeaponsFromEntities(client, items, maxItems, count);

    return count;
}

// Weapons as the game recorded the buys. Returns the new item count.
int CollectWeaponsFromPurchases(int client, LoadoutItem[] items, int maxItems, int count)
{
    Address base;
    int purchases = GetPurchaseList(client, base);

    // Ordered by (slot, sub-slot) so the stored order is the order the buy menu shows and the apply
    // path re-buys in. The vector itself is in neither order - melee sits at index 0 on slot 2.
    int order[PURCHASE_MAX_ENTRIES];
    int ordered = 0;

    for (int i = 0; i < purchases && ordered < PURCHASE_MAX_ENTRIES; i++)
    {
        Address e = base + view_as<Address>(i * PURCHASE_STRIDE);
        int slot  = LoadFromAddress(e + view_as<Address>(PURCHASE_SLOT), NumberType_Int32);
        int sub   = LoadFromAddress(e + view_as<Address>(PURCHASE_SUBSLOT), NumberType_Int32);

        if (slot < 0 || IsSkippedSlot(slot)) continue;

        int key = slot * 256 + sub;
        int at  = ordered;
        while (at > 0)
        {
            Address prev = base + view_as<Address>(order[at - 1] * PURCHASE_STRIDE);
            int pslot    = LoadFromAddress(prev + view_as<Address>(PURCHASE_SLOT), NumberType_Int32);
            int psub     = LoadFromAddress(prev + view_as<Address>(PURCHASE_SUBSLOT), NumberType_Int32);
            if (pslot * 256 + psub <= key) break;

            order[at] = order[at - 1];
            at--;
        }

        order[at] = i;
        ordered++;
    }

    // Every weapon row emitted so far, so a repeat buy can find its row wherever it landed. Merging
    // only with the row just emitted is not enough: sub-slot values repeat in the vector, so the order
    // is ambiguous and two buys of one weapon can arrive with something else between them. That wrote
    // "m67 q2" and a second "m67 q1" into the same set, which then asked for more explosive sub-slots
    // than the slot has and lost the tail of the loadout on every load.
    int emittedOrdinal[MAX_WEAPON_ITEMS];
    int emittedDef[MAX_WEAPON_ITEMS];
    bool emittedKitted[MAX_WEAPON_ITEMS];
    int emitted = 0;

    for (int o = 0; o < ordered && count < maxItems; o++)
    {
        Address e = base + view_as<Address>(order[o] * PURCHASE_STRIDE);
        int def   = LoadFromAddress(e + view_as<Address>(PURCHASE_WEAPON), NumberType_Int32);
        int slot  = LoadFromAddress(e + view_as<Address>(PURCHASE_SLOT), NumberType_Int32);
        int subsl = LoadFromAddress(e + view_as<Address>(PURCHASE_SUBSLOT), NumberType_Int32);

        if (def <= 0 || def == THEATER_ID_NONE) continue;

        // One sub-slot is one item, so two entries claiming the same (slot, sub-slot) are the same
        // item recorded twice - not two of it. That happens because a respawn re-grants the class
        // buy_order on top of a loadout already applied: two loaded m67 plus the class's one showed up
        // as three entries at sub-slots 1, 1 and 2. Counting entries made the stored quantity climb on
        // every save/load cycle until it asked for more sub-slots than the slot has and the tail of the
        // loadout stopped arriving. Occupancy is what matters, so a repeated sub-slot is skipped.
        bool seenSubSlot = false;
        for (int q = 0; q < o && !seenSubSlot; q++)
        {
            Address prev = base + view_as<Address>(order[q] * PURCHASE_STRIDE);
            if (LoadFromAddress(prev + view_as<Address>(PURCHASE_WEAPON), NumberType_Int32) == def
                && LoadFromAddress(prev + view_as<Address>(PURCHASE_SLOT), NumberType_Int32) == slot
                && LoadFromAddress(prev + view_as<Address>(PURCHASE_SUBSLOT), NumberType_Int32) == subsl)
                seenSubSlot = true;
        }
        if (seenSubSlot) continue;

        // Collect this entry's upgrades first, so a repeat buy can be told from a second instance that
        // happens to carry its own attachments.
        int  upgradeIds[MAX_WEAPON_UPGRADES];
        int  upgradeCount = 0;
        for (int u = 0; u < 10; u++)
        {
            int id = LoadFromAddress(e + view_as<Address>(PURCHASE_UPGRADES + u * 4), NumberType_Int32);
            if (id <= 0 || id == THEATER_ID_NONE) continue;
            upgradeIds[upgradeCount++] = id;
        }

        // A bare repeat of a weapon already emitted is another of the same stack, so it becomes
        // quantity rather than a second row. Anything carrying upgrades stays its own row, because two
        // instances of one weapon can be kitted differently and merging them would lose that.
        if (upgradeCount == 0)
        {
            int merged = -1;
            for (int m = 0; m < emitted && merged < 0; m++)
                if (emittedDef[m] == def && !emittedKitted[m]) merged = emittedOrdinal[m];

            if (merged >= 0)
            {
                items[merged].quantity++;
                continue;
            }
        }

        LoadoutItem item;
        if (!TheaterItem_Name(TheaterCategory_Weapon, def, item.name, sizeof(item.name)))
        {
            LogError("[LoadoutSaver] %L has weapon id %d the theater cannot name - not saved", client, def);
            continue;
        }

        item.category = view_as<int>(TheaterCategory_Weapon);
        item.slot     = slot;
        item.parent   = -1;
        item.quantity = 1;

        int weaponOrdinal = count;
        items[count++]    = item;

        if (emitted < MAX_WEAPON_ITEMS)
        {
            emittedOrdinal[emitted] = weaponOrdinal;
            emittedDef[emitted]     = def;
            emittedKitted[emitted]  = (upgradeCount > 0);
            emitted++;
        }

        for (int u = 0; u < upgradeCount && count < maxItems; u++)
        {
            LoadoutItem upgrade;
            if (!TheaterItem_Name(TheaterCategory_Upgrade, upgradeIds[u], upgrade.name, sizeof(upgrade.name)))
            {
                LogError("[LoadoutSaver] %L has upgrade id %d the theater cannot name - not saved",
                         client, upgradeIds[u]);
                continue;
            }

            upgrade.category = view_as<int>(TheaterCategory_Upgrade);
            upgrade.slot     = -1;
            upgrade.parent   = weaponOrdinal;
            upgrade.quantity = 1;
            items[count++]   = upgrade;
        }
    }

    return count;
}

// Fallback for when the purchase list is empty but the player is holding weapons - after a map change,
// where the vector is cleared and the items are not. Quantity is always 1 here: a stack is a single
// entity, so there is nothing to count.
int CollectWeaponsFromEntities(int client, LoadoutItem[] items, int maxItems, int count)
{
    if (!g_SlotsAvailable) return count;

    int weaponEnts[MAX_WEAPON_ITEMS];
    int slots[MAX_WEAPON_ITEMS];
    int weaponCount = 0;

    int carried = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < carried && weaponCount < MAX_WEAPON_ITEMS; i++)
    {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon <= 0 || !IsValidEntity(weapon)) continue;
        if (!HasEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle")) continue;
        if (GetEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle") <= 0) continue;

        int slot = GetWeaponSlot(weapon);
        if (slot < 0 || IsSkippedSlot(slot)) continue;

        int at = weaponCount;
        while (at > 0 && slots[at - 1] > slot)
        {
            slots[at]      = slots[at - 1];
            weaponEnts[at] = weaponEnts[at - 1];
            at--;
        }

        slots[at]      = slot;
        weaponEnts[at] = weapon;
        weaponCount++;
    }

    if (weaponCount > 0)
        LogMessage("[LoadoutSaver] %L: purchase list empty, saved %d weapon(s) from carried entities - stack sizes not recorded",
                   client, weaponCount);

    for (int i = 0; i < weaponCount && count < maxItems; i++)
    {
        int weapon   = weaponEnts[i];
        int weaponId = GetEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle");

        LoadoutItem item;
        if (!TheaterItem_Name(TheaterCategory_Weapon, weaponId, item.name, sizeof(item.name)))
        {
            LogError("[LoadoutSaver] %L has weapon id %d the theater cannot name - not saved", client, weaponId);
            continue;
        }

        item.category = view_as<int>(TheaterCategory_Weapon);
        item.slot     = slots[i];
        item.parent   = -1;
        item.quantity = 1;

        int weaponOrdinal = count;
        items[count++] = item;

        if (!HasEntProp(weapon, Prop_Send, "m_upgradeSlots")) continue;

        int upgradeCount = GetEntPropArraySize(weapon, Prop_Send, "m_upgradeSlots");
        for (int u = 0; u < upgradeCount && count < maxItems; u++)
        {
            int upgradeId = GetEntProp(weapon, Prop_Send, "m_upgradeSlots", 4, u);
            if (upgradeId <= 0 || upgradeId == THEATER_ID_NONE) continue;

            LoadoutItem upgrade;
            if (!TheaterItem_Name(TheaterCategory_Upgrade, upgradeId, upgrade.name, sizeof(upgrade.name)))
            {
                LogError("[LoadoutSaver] %L has upgrade id %d the theater cannot name - not saved", client, upgradeId);
                continue;
            }

            upgrade.category = view_as<int>(TheaterCategory_Upgrade);
            upgrade.slot     = -1;
            upgrade.parent   = weaponOrdinal;
            upgrade.quantity = 1;
            items[count++]   = upgrade;
        }
    }

    return count;
}

void SaveLoadoutFromEntity(int client, const char[] name)
{
    if (g_Database == null)
    {
        SendFailedMessage(client);
        return;
    }

    // Deliberately NOT gated on g_SlotsAvailable. That guard existed because a save with no slot
    // information would record every weapon as slot 0, which is worse than no loadout - but slots now
    // come from the purchase entries, and only the entity fallback needs CBaseCombatWeapon::GetSlot.
    // Refusing the whole save here would block the path that still works; the fallback checks for
    // itself and returns nothing rather than guessing.

    // Without the name lookup every item would have to be stored as a raw id, which is exactly the
    // thing this schema exists to avoid.
    if (!TheaterItem_Ready())
    {
        CPrintToChat(client, "{red}[Loadout]{default} Saving is unavailable right now (theater not read). Try again in a moment.");
        return;
    }

    if (!ValidateSupplyPoints(client)) return;

    LoadoutItem items[MAX_ITEMS];
    int count = CollectItems(client, items, sizeof(items));

    SaveLoadoutToDatabase(client, items, count, name);
}

// =====================================================
// Save Loadout to Database
// =====================================================

// Four statements in one transaction:
//   1. add any names not seen before
//   2. upsert the set (and enforce the named cap, in the statement, so two saves racing cannot both
//      see room)
//   3. drop the set's existing items
//   4. insert the new ones, joining the names back to their ids
//
// The set is addressed by its natural key in statement 4 rather than by an id carried between
// statements, which keeps each one independent and avoids needing RETURNING across a transaction.
void SaveLoadoutToDatabase(int client, LoadoutItem[] items, int count, const char[] name)
{
    if (g_Database == null) return;

    char query[8192];
    char escapedName[MAX_LOADOUT_NAME * 2 + 8];
    char nameValue[MAX_LOADOUT_NAME * 2 + 16];

    if (name[0] == '\0')
    {
        strcopy(nameValue, sizeof(nameValue), "NULL");
    }
    else
    {
        g_Database.Escape(name, escapedName, sizeof(escapedName));
        Format(nameValue, sizeof(nameValue), "'%s'", escapedName);
    }

    char escapedClass[256];
    g_Database.Escape(g_PlayerCurrentClass[client], escapedClass, sizeof(escapedClass));

    Transaction txn = new Transaction();

    // 1. names
    if (count > 0)
    {
        Format(query, sizeof(query), "INSERT INTO theater_items (category, name) VALUES ");
        for (int i = 0; i < count; i++)
        {
            char escapedItem[ITEM_NAME_SIZE * 2 + 4];
            g_Database.Escape(items[i].name, escapedItem, sizeof(escapedItem));
            Format(query, sizeof(query), "%s%s(%d,'%s')", query, i > 0 ? "," : "", items[i].category, escapedItem);
        }
        StrCat(query, sizeof(query), " ON CONFLICT (category, name) DO NOTHING");
        txn.AddQuery(query);
    }

    // 2. the set
    if (name[0] == '\0')
    {
        Format(query, sizeof(query),
               "INSERT INTO loadouts_slots (steam_id, class_template, name, updated_at, update_count) VALUES (%s, '%s', NULL, CURRENT_TIMESTAMP, 1) ON CONFLICT (steam_id, class_template) WHERE name IS NULL DO UPDATE SET updated_at = CURRENT_TIMESTAMP, update_count = loadouts_slots.update_count + 1",
               g_PlayerSteamId[client], escapedClass);
    }
    else
    {
        Format(query, sizeof(query),
               "INSERT INTO loadouts_slots (steam_id, class_template, name, updated_at, update_count) SELECT %s, '%s', %s, CURRENT_TIMESTAMP, 1 WHERE (SELECT COUNT(*) FROM loadouts_slots WHERE steam_id = %s AND name IS NOT NULL) < %d OR EXISTS (SELECT 1 FROM loadouts_slots WHERE steam_id = %s AND name IS NOT NULL AND lower(name) = lower(%s)) ON CONFLICT (steam_id, lower(name)) WHERE name IS NOT NULL DO UPDATE SET class_template = EXCLUDED.class_template, updated_at = CURRENT_TIMESTAMP, update_count = loadouts_slots.update_count + 1",
               g_PlayerSteamId[client], escapedClass, nameValue,
               g_PlayerSteamId[client], g_CvarMaxNamed.IntValue,
               g_PlayerSteamId[client], nameValue);
    }
    txn.AddQuery(query);

    // The set's natural key, reused by statements 3 and 4.
    //
    // Every column is qualified with the "l." alias. Statement 4 joins theater_items, which also has
    // a "name" column, so an unqualified reference there is ambiguous and Postgres rejects the whole
    // statement ("column reference \"name\" is ambiguous"). Statement 3 therefore aliases
    // loadouts_slots as l too, so one selector is valid in both.
    char selector[512];
    if (name[0] == '\0')
        Format(selector, sizeof(selector), "l.steam_id = %s AND l.class_template = '%s' AND l.name IS NULL",
               g_PlayerSteamId[client], escapedClass);
    else
        Format(selector, sizeof(selector), "l.steam_id = %s AND l.name IS NOT NULL AND lower(l.name) = lower(%s)",
               g_PlayerSteamId[client], nameValue);

    // 3. clear the old items
    Format(query, sizeof(query),
           "DELETE FROM loadout_items WHERE loadout_id = (SELECT l.id FROM loadouts_slots l WHERE %s)", selector);
    txn.AddQuery(query);

    // 4. the items
    if (count > 0)
    {
        Format(query, sizeof(query),
               "INSERT INTO loadout_items (loadout_id, ordinal, item_id, slot, parent_ordinal, quantity) SELECT l.id, v.ord, ti.id, v.slot, v.parent, v.qty FROM loadouts_slots l CROSS JOIN (VALUES ");

        for (int i = 0; i < count; i++)
        {
            char escapedItem[ITEM_NAME_SIZE * 2 + 4];
            g_Database.Escape(items[i].name, escapedItem, sizeof(escapedItem));

            char slotValue[16], parentValue[16];
            if (items[i].slot < 0) strcopy(slotValue, sizeof(slotValue), "NULL");
            else IntToString(items[i].slot, slotValue, sizeof(slotValue));
            if (items[i].parent < 0) strcopy(parentValue, sizeof(parentValue), "NULL");
            else IntToString(items[i].parent, parentValue, sizeof(parentValue));

            // The first row carries the casts so Postgres can infer the column types; a leading
            // NULL with no type is the one thing a VALUES list will not accept.
            int qty = items[i].quantity > 0 ? items[i].quantity : 1;

            if (i == 0)
                Format(query, sizeof(query), "%s(%d::smallint,%d::smallint,'%s',%s::smallint,%s::smallint,%d::smallint)",
                       query, i, items[i].category, escapedItem, slotValue, parentValue, qty);
            else
                Format(query, sizeof(query), "%s,(%d,%d,'%s',%s,%s,%d)",
                       query, i, items[i].category, escapedItem, slotValue, parentValue, qty);
        }

        Format(query, sizeof(query),
               "%s) AS v(ord, cat, nm, slot, parent, qty) JOIN theater_items ti ON ti.category = v.cat AND ti.name = v.nm WHERE %s",
               query, selector);
        txn.AddQuery(query);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(name);
    pack.WriteCell(count);

    g_Database.Execute(txn, OnSaveSuccess, OnSaveFailure, pack);
}

public void OnSaveSuccess(Database db, DataPack pack, int numQueries, DBResultSet[] results, any[] queryData)
{
    pack.Reset();
    int  userid = pack.ReadCell();
    char name[MAX_LOADOUT_NAME + 1];
    pack.ReadString(name, sizeof(name));
    int count = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    // A named save that inserted nothing was turned away by the cap check inside the statement.
    // The set upsert is the second query when names were written and the first when they were not.
    if (name[0] != '\0')
    {
        int setIndex = (count > 0) ? 1 : 0;
        if (setIndex < numQueries && results[setIndex] != null && results[setIndex].AffectedRows < 1)
        {
            CPrintToChat(client, "{red}[Loadout]{default} You already have %d named loadouts. Delete one with !dello <name> first.", g_CvarMaxNamed.IntValue);
            return;
        }

        CPrintToChat(client, "{olivedrab}[Loadout]{default} Saved as {green}%s{default}. Load it on any class with !loadlo %s", name, name);
        return;
    }

    char message[256];
    g_CvarMsgSaved.GetString(message, sizeof(message));
    CPrintToChat(client, message);
}

public void OnSaveFailure(Database db, DataPack pack, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    pack.Reset();
    int  userid = pack.ReadCell();
    char name[MAX_LOADOUT_NAME + 1];
    pack.ReadString(name, sizeof(name));
    delete pack;

    LogError("[LoadoutSaver] Save failed at statement %d: %s", failIndex, error);

    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    // The trigger is the hard ceiling behind the statement's own check.
    if (StrContains(error, "named loadout cap", false) != -1)
    {
        CPrintToChat(client, "{red}[Loadout]{default} You already have %d named loadouts. Delete one with !dello <name> first.", g_CvarMaxNamed.IntValue);
        return;
    }

    SendFailedMessage(client);
}

// =====================================================
// Load Loadout from Database
// =====================================================

// name empty = this class's own loadout (the automatic spawn load and a bare !loadlo).
// Otherwise the named loadout, which may have been saved on any class.
void LoadPlayerLoadout(int client, bool showMessages, const char[] name)
{
    if (g_Database == null || !EnsureSteamId(client))
    {
        if (showMessages) SendFailedMessage(client);
        return;
    }

    if (name[0] == '\0' && !ResolvePlayerClass(client))
    {
        if (showMessages) CPrintToChat(client, "{red}[Loadout]{default} Select a class first!");
        return;
    }

    // LEFT JOIN so an empty set still returns its row - that is how a saved-but-empty loadout is
    // told apart from one that does not exist.
    char query[1024];
    if (name[0] == '\0')
    {
        g_Database.Format(query, sizeof(query),
                          "SELECT l.class_template, ti.category, ti.name, li.slot, li.parent_ordinal, li.quantity FROM loadouts_slots l LEFT JOIN loadout_items li ON li.loadout_id = l.id LEFT JOIN theater_items ti ON ti.id = li.item_id WHERE l.steam_id = %s AND l.class_template = '%s' AND l.name IS NULL ORDER BY li.ordinal",
                          g_PlayerSteamId[client], g_PlayerCurrentClass[client]);
    }
    else
    {
        g_Database.Format(query, sizeof(query),
                          "SELECT l.class_template, ti.category, ti.name, li.slot, li.parent_ordinal, li.quantity FROM loadouts_slots l LEFT JOIN loadout_items li ON li.loadout_id = l.id LEFT JOIN theater_items ti ON ti.id = li.item_id WHERE l.steam_id = %s AND l.name IS NOT NULL AND lower(l.name) = lower('%s') ORDER BY li.ordinal",
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
        // No class loadout saved is the normal case and stays silent, but a player who asked for a
        // name by hand should hear that it does not exist.
        if (name[0] != '\0' && showMessages)
            CPrintToChat(client, "{red}[Loadout]{default} No loadout named {green}%s{default}. See !listlo", name);
        return;
    }

    char savedClass[128];
    results.FetchString(0, savedClass, sizeof(savedClass));

    if (name[0] != '\0' && !StrEqual(savedClass, g_PlayerCurrentClass[client], false) && !g_CvarNamedCrossClass.BoolValue)
    {
        if (showMessages)
            CPrintToChat(client, "{red}[Loadout]{default} {green}%s{default} was saved on another class and cross-class loading is disabled here.", name);
        return;
    }

    LoadoutItem items[MAX_ITEMS];
    int count = 0;

    // The first row is already fetched, so read it before advancing.
    do
    {
        if (count >= MAX_ITEMS) break;
        if (results.IsFieldNull(2)) continue;    // the LEFT JOIN row of an empty set

        LoadoutItem item;
        item.category = results.FetchInt(1);
        results.FetchString(2, item.name, sizeof(item.name));
        item.slot   = results.IsFieldNull(3) ? -1 : results.FetchInt(3);
        item.parent = results.IsFieldNull(4) ? -1 : results.FetchInt(4);
        // NOT NULL with a default, so a null here would mean a row written before the column
        // existed; treat that as the single purchase it was.
        item.quantity = results.IsFieldNull(5) ? 1 : results.FetchInt(5);
        if (item.quantity < 1) item.quantity = 1;

        items[count++] = item;
    }
    while (results.FetchRow());

    ApplyLoadout(client, items, count, showMessages, name, savedClass);
}

// =====================================================
// Apply Loadout - Execute Buy Commands
// =====================================================

void ApplyLoadout(int client, LoadoutItem[] items, int count, bool showMessages, const char[] name, const char[] savedClass)
{
    if (!IsClientInGame(client)) return;
    if (!IsPlayerAlive(client)) return;

    if (!TheaterItem_Ready())
    {
        if (showMessages) CPrintToChat(client, "{red}[Loadout]{default} Loading is unavailable right now (theater not read).");
        return;
    }

    FakeClientCommand(client, "inventory_sell_all");

    bool debug = g_CvarDebug.BoolValue;
    if (debug)
    {
        LogMessage("[LoadoutSaver:debug] %L apply start: available=%d received=%d starting_supply=%d",
                   client, GetEntProp(client, Prop_Send, "m_nAvailableTokens"),
                   GetEntProp(client, Prop_Send, "m_nRecievedTokens"), GetStartingSupply());
    }

    // Gear before weapons, and that ordering is load-bearing. GetWeaponSlotCapacity is 1 plus the
    // "weapon_slots" bonuses on the gear worn RIGHT NOW, so until the rig and slings are back on
    // every slot still has capacity 1 and the second primary or third grenade is refused.
    for (int i = 0; i < count; i++)
    {
        if (items[i].category != view_as<int>(TheaterCategory_Gear)) continue;

        int id = TheaterItem_Find(TheaterCategory_Gear, items[i].name);
        if (id <= 0)
        {
            LogMessage("[LoadoutSaver] %L: gear \"%s\" is not in the loaded theater - skipped", client, items[i].name);
            continue;
        }

        FakeClientCommand(client, "inventory_buy_gear %d", id);
    }

    // What ended up worn, by slot. sec_tactical_carrier carries "weapon_slots { explosive 3 }", so
    // if it is not on by this point the explosive slot holds one item and the rest are refused - and
    // gear is invisible to the verify pass, which only counts weapons.
    if (debug && HasEntProp(client, Prop_Send, "m_EquippedGear"))
    {
        char worn[256];
        int gearSlots = GetEntPropArraySize(client, Prop_Send, "m_EquippedGear");
        for (int g = 0; g < gearSlots; g++)
        {
            int id = GetEntProp(client, Prop_Send, "m_EquippedGear", 4, g);
            if (id <= 0 || id == THEATER_ID_NONE) continue;

            char gname[ITEM_NAME_SIZE];
            if (!TheaterItem_Name(TheaterCategory_Gear, id, gname, sizeof(gname)))
                Format(gname, sizeof(gname), "id%d", id);

            Format(worn, sizeof(worn), "%s%s%d:%s", worn, worn[0] == '\0' ? "" : " ", g, gname);
        }
        LogMessage("[LoadoutSaver:debug] %L gear after buy: [%s]", client, worn);
    }

    // Weapons in stored order, each followed by its own upgrades.
    int  weaponsBought = 0;
    bool claimed[PURCHASE_MAX_ENTRIES];
    for (int i = 0; i < PURCHASE_MAX_ENTRIES; i++) claimed[i] = false;

    for (int i = 0; i < count; i++)
    {
        if (items[i].category != view_as<int>(TheaterCategory_Weapon)) continue;

        int weaponId = TheaterItem_Find(TheaterCategory_Weapon, items[i].name);
        if (weaponId <= 0)
        {
            LogMessage("[LoadoutSaver] %L: weapon \"%s\" is not in the loaded theater - skipped", client, items[i].name);
            continue;
        }

        // Sub-slot -1 means "next free". Without it every buy targets sub-slot 0 and PurchaseWeapon
        // refunds whatever is already there, which is why a bare inventory_buy_weapon can never hold
        // more than one item per slot. Firemode -1 leaves the player's own preference alone, and
        // args[3] is read by nothing.
        int beforeWeapon = debug ? GetEntProp(client, Prop_Send, "m_nAvailableTokens") : 0;
        int occupied     = 0;
        if (debug)
        {
            int held = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
            for (int h = 0; h < held; h++)
            {
                int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", h);
                if (w > 0 && IsValidEntity(w) && GetWeaponSlot(w) == items[i].slot) occupied++;
            }
        }

        FakeClientCommand(client, "inventory_buy_weapon %d -1 0 -1", weaponId);
        weaponsBought++;

        if (debug)
            LogMessage("[LoadoutSaver:debug] %L buy weapon %s (slot %d, qty %d, slot held %d before): available %d -> %d",
                       client, items[i].name, items[i].slot, items[i].quantity, occupied, beforeWeapon,
                       GetEntProp(client, Prop_Send, "m_nAvailableTokens"));

        // inventory_buy_upgrade takes a position in the purchase list, bounds-checked as
        // 0 <= index < purchase count. Not a slot, and not the order this plugin bought things in -
        // the list already holds whatever the class template granted - so it is read back rather
        // than counted. The buy above has already run: FakeClientCommand dispatches the ConCommand
        // synchronously.
        int purchaseIndex = FindPurchaseIndex(client, weaponId, claimed);
        if (purchaseIndex < 0)
        {
            purchaseIndex = weaponsBought;
            LogError("[LoadoutSaver] %L: weapon %s not found in the purchase list, falling back to positional index %d",
                     client, items[i].name, purchaseIndex);
        }

        // The rest of a stack. Replaying the buy is what makes a round-count-per-purchase weapon
        // like weapon_m79_napalm come back right: the theater grants whatever clip_default says on
        // each one, so this restores purchases rather than a remembered round count.
        //
        // The game arbitrates as always - weapon_max_subslot, the ammo type's carry cap and supply
        // all still apply, so a buy that cannot be honoured is simply refused, and the read-back
        // below reports it like any other missing item. Upgrades are deliberately attached only to
        // the first purchase: nothing that stacks takes upgrades, and the extra entries are claimed
        // purely so a later weapon does not resolve its index to one of them.
        for (int extra = 1; extra < items[i].quantity; extra++)
        {
            FakeClientCommand(client, "inventory_buy_weapon %d -1 0 -1", weaponId);
            weaponsBought++;
            FindPurchaseIndex(client, weaponId, claimed);

            if (debug)
                LogMessage("[LoadoutSaver:debug] %L buy weapon %s again (%d of %d): available now %d",
                           client, items[i].name, extra + 1, items[i].quantity,
                           GetEntProp(client, Prop_Send, "m_nAvailableTokens"));
        }

        for (int u = 0; u < count; u++)
        {
            if (items[u].category != view_as<int>(TheaterCategory_Upgrade)) continue;
            if (items[u].parent != i) continue;

            int upgradeId = TheaterItem_Find(TheaterCategory_Upgrade, items[u].name);
            if (upgradeId <= 0)
            {
                LogMessage("[LoadoutSaver] %L: upgrade \"%s\" is not in the loaded theater - skipped", client, items[u].name);
                continue;
            }

            int beforeUpgrade = debug ? GetEntProp(client, Prop_Send, "m_nAvailableTokens") : 0;

            FakeClientCommand(client, "inventory_buy_upgrade %d %d", purchaseIndex, upgradeId);

            if (debug)
                LogMessage("[LoadoutSaver:debug] %L   upgrade %s on index %d: available %d -> %d",
                           client, items[u].name, purchaseIndex, beforeUpgrade,
                           GetEntProp(client, Prop_Send, "m_nAvailableTokens"));
        }
    }

    FakeClientCommand(client, "inventory_resupply");

    // The buy PANEL is not refreshed here, and cannot be from the server. It caches its contents and
    // does not re-read them when the server buys on a player's behalf, so after a load the list keeps
    // showing what it last drew even though the items are in hand.
    //
    // The obvious lever does not work. CINSPlayer hands "changeinventory" to engine->ClientCommand
    // (string at 0xa29342 in server.so) and client.so registers it next to the other inventory panel
    // commands, so it looks like exactly the right thing to re-issue - but sending it changes nothing,
    // and neither does inventory_open. The channel itself is shut: a server-sent "say" never comes back
    // either, because a modern client only executes server stringcmds for commands carrying
    // FCVAR_SERVER_CAN_EXECUTE, which key-bound UI commands do not. Tested, not assumed.
    //
    // Reopening the menu rebuilds it correctly, so this is cosmetic. Anything further would mean
    // finding a networked value the panel watches and poking that, which trades a display quirk for a
    // gameplay side effect.

    if (showMessages)
    {
        char message[256];
        g_CvarMsgLoaded.GetString(message, sizeof(message));
        CPrintToChat(client, message);
    }

    // Nothing above decides what a player may carry. Every item goes through the same
    // inventory_buy_* commands the buy menu issues, so the game arbitrates class restrictions and
    // supply cost exactly as it does for a manual purchase. Rather than trust that silently, the
    // result is read back and the player is told how many items did not arrive.
    char wanted[512];
    for (int i = 0; i < count; i++)
    {
        if (items[i].category != view_as<int>(TheaterCategory_Weapon)) continue;
        Format(wanted, sizeof(wanted), "%s%s%s", wanted, wanted[0] == '\0' ? "" : ",", items[i].name);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(showMessages);
    pack.WriteCell(name[0] != '\0' && !StrEqual(savedClass, g_PlayerCurrentClass[client], false));
    pack.WriteString(name);
    pack.WriteString(savedClass);
    pack.WriteString(wanted);

    // Delayed on purpose, but not because the buys are queued - FakeClientCommand dispatches them
    // synchronously. What is deferred is the weapon ENTITIES: the purchase list updates
    // immediately, the items are handed out later, and the check below reads entities.
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
    char wantedBuffer[512];
    pack.ReadString(name, sizeof(name));
    pack.ReadString(savedClass, sizeof(savedClass));
    pack.ReadString(wantedBuffer, sizeof(wantedBuffer));

    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client)) return Plugin_Handled;
    if (wantedBuffer[0] == '\0') return Plugin_Handled;

    char wanted[MAX_WEAPON_ITEMS][ITEM_NAME_SIZE];
    int  wantedCount = ExplodeString(wantedBuffer, ",", wanted, sizeof(wanted), sizeof(wanted[]));

    // What the player actually ended up with - from the PURCHASE LIST first, for the same reason the
    // save reads it: a buy is recorded and charged immediately while the entity is handed out at the
    // next spawn. Counting entities half a second after the buys reports every pending item as
    // "missing", which is what produced "5 items are missing" on loads where the log shows all seven
    // purchases succeeding and supply going 120 -> 70. The entity walk stays as the fallback for when
    // the vector is empty, i.e. after a map change.
    char got[MAX_WEAPON_ITEMS][ITEM_NAME_SIZE];
    int  gotCount = 0;

    Address pbase;
    int purchases = GetPurchaseList(client, pbase);

    for (int i = 0; i < purchases && gotCount < MAX_WEAPON_ITEMS; i++)
    {
        Address e = pbase + view_as<Address>(i * PURCHASE_STRIDE + PURCHASE_WEAPON);
        int id    = LoadFromAddress(e, NumberType_Int32);
        if (id <= 0 || id == THEATER_ID_NONE) continue;
        if (TheaterItem_Name(TheaterCategory_Weapon, id, got[gotCount], sizeof(got[]))) gotCount++;
    }

    if (gotCount == 0)
    {
        int carried = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
        for (int i = 0; i < carried && gotCount < MAX_WEAPON_ITEMS; i++)
        {
            int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
            if (weapon <= 0 || !IsValidEntity(weapon)) continue;
            if (!HasEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle")) continue;

            int id = GetEntProp(weapon, Prop_Send, "m_hWeaponDefinitionHandle");
            if (id <= 0) continue;
            if (TheaterItem_Name(TheaterCategory_Weapon, id, got[gotCount], sizeof(got[]))) gotCount++;
        }
    }

    bool matched[MAX_WEAPON_ITEMS];
    for (int i = 0; i < MAX_WEAPON_ITEMS; i++) matched[i] = false;
    int dropped = 0;

    for (int i = 0; i < wantedCount; i++)
    {
        if (wanted[i][0] == '\0') continue;

        bool found = false;
        for (int j = 0; j < gotCount && !found; j++)
        {
            if (matched[j] || !StrEqual(got[j], wanted[i], false)) continue;
            matched[j] = true;
            found      = true;
        }

        if (!found) dropped++;
    }

    // Remembered so a following save cannot overwrite the set this came from with the short version.
    g_LastLoadDropped[client] = dropped;
    strcopy(g_LastLoadName[client], sizeof(g_LastLoadName[]), name);
    g_OverwriteConfirmed[client] = false;

    if (dropped > 0 || crossClass)
    {
        LogMessage("[LoadoutSaver] %L loaded \"%s\" (saved on %s) while playing %s: wanted [%s], %d missing",
                   client, name[0] == '\0' ? "<class loadout>" : name, savedClass,
                   g_PlayerCurrentClass[client], wantedBuffer, dropped);
    }

    if (dropped > 0 && showMessages)
    {
        // Deliberately not "not available to this class": the commonest cause is running out of
        // supply part way through, because the buys run in stored order and the explosives are last.
        if (name[0] == '\0')
            CPrintToChat(client, "{red}[Loadout]{default} %d item(s) could not be equipped - not enough supply, or not allowed on this class. Your saved loadout is unchanged.", dropped);
        else
            CPrintToChat(client, "{red}[Loadout]{default} %d item(s) in {green}%s{default} could not be equipped - not enough supply, or not allowed on this class. The saved loadout is unchanged.", dropped, name);
    }

    return Plugin_Handled;
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

// ---------------------------------------------------------------------------------------------
// Weapon display names
// ---------------------------------------------------------------------------------------------
// theater_items stores entity classnames ("weapon_m4a1sopmod"), which is right for lookups and
// unreadable in chat. The theater already knows the pretty name - every weapon carries
// "print_name" "#<classname>" - and those tokens resolve in the game's localisation files. The
// server has both, through the engine's filesystem rather than the real one: the stock file lives
// inside insurgency_misc_dir.vpk and TUG's inside the workshop VPK, so OpenFile is called with
// use_valve_fs so it searches mounted VPKs.
//
// ENCODING IS THE AWKWARD PART. These files are UTF-16LE, so every ASCII character is a byte
// followed by a zero. ReadFileLine would stop dead at the first of those zeros, and KeyValues
// cannot parse the file at all - hence the byte-level read and the hand-rolled scan below. Only
// keys beginning with "weapon_" are kept, which is a few hundred entries rather than the whole
// several-thousand-line file.
StringMap g_WeaponNames = null;

void LoadWeaponNames()
{
    delete g_WeaponNames;
    g_WeaponNames = new StringMap();

    // Stock first, TUG second: TUG renames some stock weapons and the later load must win.
    int n = ParseLocalisation("resource/insurgency_english.txt");
    n += ParseLocalisation("resource/ui/tug_english_modern.txt");

    // Four weapons name a token that is NOT their classname, so the convention the lookup relies on
    // does not hold for them and they would fall back to a bare classname. Checked across the whole
    // set: 118 of 122 use "#<classname>" and need nothing, these four are the exceptions, and each
    // token below is the print_name the theater actually declares for that weapon.
    AliasWeaponName("weapon_M107", "weapon_m107barrett");
    AliasWeaponName("weapon_m16a4", "weapon_m16");
    AliasWeaponName("weapon_g33", "weapon_g3a3");
    AliasWeaponName("weapon_c4_clicker", "weapon_c4");

    char sample[64];
    if (!g_WeaponNames.GetString("weapon_m4a1sopmod", sample, sizeof(sample)))
        strcopy(sample, sizeof(sample), "<not found>");

    char sample2[64];
    if (!g_WeaponNames.GetString("weapon_M107", sample2, sizeof(sample2)))
        strcopy(sample2, sizeof(sample2), "<not found>");
    LogMessage("[LoadoutSaver] %d weapon display names loaded (weapon_m4a1sopmod -> %s, weapon_M107 -> %s)",
               n, sample, sample2);
}

// Points a classname at a token that differs from it, but only if that token actually resolved -
// a missing one leaves the classname fallback in place rather than storing an empty name.
void AliasWeaponName(const char[] classname, const char[] token)
{
    char value[64];
    if (g_WeaponNames.GetString(token, value, sizeof(value)))
        g_WeaponNames.SetString(classname, value, true);
}

// Returns how many "weapon_*" tokens were added. Tolerates a missing file - a server without TUG
// mounted simply gets fewer names and falls back to classnames.
int ParseLocalisation(const char[] path)
{
    File f = OpenFile(path, "rb", true, "GAME");
    if (f == null) return 0;

    int added = 0;
    int bytes[1024];
    char line[512];
    int  len = 0;

    while (!f.EndOfFile())
    {
        int got = f.Read(bytes, sizeof(bytes), 1);
        if (got <= 0) break;

        for (int i = 0; i < got; i++)
        {
            int b = bytes[i] & 0xFF;

            // The zero half of each UTF-16LE code unit, and the BOM, carry nothing for us.
            if (b == 0 || b == 0xFF || b == 0xFE) continue;

            if (b == '\n' || b == '\r')
            {
                if (len > 0)
                {
                    line[len] = '\0';
                    if (StoreLocalisedName(line)) added++;
                    len = 0;
                }
                continue;
            }

            if (len < sizeof(line) - 1) line[len++] = b;
        }
    }
    delete f;

    if (len > 0)
    {
        line[len] = '\0';
        if (StoreLocalisedName(line)) added++;
    }
    return added;
}

// One line of the Tokens block is  "key"  "value"  - take the first two quoted runs and keep the
// pair only when the key names a weapon.
bool StoreLocalisedName(const char[] line)
{
    int start = StrContains(line, "\"");
    if (start == -1) return false;

    int keyEnd = StrContains(line[start + 1], "\"");
    if (keyEnd == -1) return false;
    keyEnd += start + 1;

    char key[64];
    int  keyLen = keyEnd - start - 1;
    if (keyLen < 1 || keyLen >= sizeof(key)) return false;
    strcopy(key, keyLen + 1, line[start + 1]);

    // Descriptions share the prefix and would otherwise overwrite the name with a sentence.
    if (StrContains(key, "weapon_") != 0) return false;
    if (StrContains(key, "_desc") != -1) return false;

    int valStart = StrContains(line[keyEnd + 1], "\"");
    if (valStart == -1) return false;
    valStart += keyEnd + 1;

    int valEnd = StrContains(line[valStart + 1], "\"");
    if (valEnd == -1) return false;
    valEnd += valStart + 1;

    char value[64];
    int  valLen = valEnd - valStart - 1;
    if (valLen < 1 || valLen >= sizeof(value)) return false;
    strcopy(value, valLen + 1, line[valStart + 1]);

    g_WeaponNames.SetString(key, value, true);
    return true;
}

// Turns "weapon_m4a1sopmod, weapon_m1014" into "M4A1 SOPMOD, Benelli M4", falling back to the
// classname with its "weapon_" prefix trimmed when a token has no localised name.
void PrettifyWeaponList(char[] buffer, int maxlen)
{
    if (buffer[0] == '\0') return;

    char parts[2][64];
    int  count = ExplodeString(buffer, ", ", parts, sizeof(parts), sizeof(parts[]));

    buffer[0] = '\0';
    for (int i = 0; i < count; i++)
    {
        char pretty[64];
        if (g_WeaponNames == null || !g_WeaponNames.GetString(parts[i], pretty, sizeof(pretty)))
        {
            strcopy(pretty, sizeof(pretty), parts[i]);
            if (StrContains(pretty, "weapon_") == 0) strcopy(pretty, sizeof(pretty), pretty[7]);
        }

        if (i > 0) StrCat(buffer, maxlen, "{default}, ");
        StrCat(buffer, maxlen, pretty);
    }
}

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

    // One per line now that each carries a preview - several names per line left no room for it.
    char name[MAX_LOADOUT_NAME + 1];
    char preview[128];

    while (results.FetchRow())
    {
        results.FetchString(0, name, sizeof(name));

        // NULL when the set has no weapons at all - see the LEFT JOIN note on the query.
        if (results.IsFieldNull(1)) preview[0] = '\0';
        else                        results.FetchString(1, preview, sizeof(preview));

        PrettifyWeaponList(preview, sizeof(preview));

        if (preview[0] == '\0')
            CPrintToChat(client, "{olivedrab}[Loadout]{default} {green}%s", name);
        else
            CPrintToChat(client, "{olivedrab}[Loadout]{default} {green}%s{default} - %s", name, preview);
    }
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
