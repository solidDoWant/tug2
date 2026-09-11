// Theater item name <-> id lookup.
//
// Everything a theater defines is addressed at runtime by an integer: m_upgradeSlots holds upgrade
// ids, inventory_buy_weapon takes a weapon id, m_EquippedGear holds gear ids. Nothing exposes the
// name-to-id mapping to a plugin - "listtheateritems" prints names and no ids whatsoever - so
// plugins have had to hard-code numbers that shift whenever the theater changes.
//
// This reads the theater's own tables instead, so the mapping is always right for whatever theater
// is loaded, with nothing to configure and nothing to re-check after an edit.
//
// HOW
//
// CTheaterDirector holds five CUtlMap<int, definition_t*> tables. It is a file-static global, and
// on this PIC build its address is not an immediate in any instruction - but SendProxy_TheaterDirector
// exists to network it and its entire body is "return TheaterDirector", so calling that is the
// cheapest way to read it. Everything below is offsets into what it returns.
//
// All of it was read out of the shipped server_srv.so and then confirmed against the running
// server: the four tables resolve, the walk produces 126/246/29/16 entries, and those counts match
// what listtheateritems prints for the same theater.
//
// WHAT THE IDS LOOK LIKE
//
// Keys are 1-based and dense - weapons 1..126, upgrades 1..246, explosives 1..29, gear 1..16 on the
// theater this was verified against - and the tables are walked in key order, which is also
// definition order. That means listtheateritems' output position plus one IS the id. This plugin
// does not rely on that: it reads the actual key for each entry, so a theater that ever produced a
// gap would still resolve correctly.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <theateritems>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name        = "[GG2 Theater Items] Name/ID lookup",
    author      = "solidDoWant",
    description = "Resolves theater item names to the ids the inventory commands use",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

// ---------------------------------------------------------------------------------------------
// Layout, all verified against the running server.
// ---------------------------------------------------------------------------------------------

// CTheaterDirector members. There is a fifth table at +0x24 - the player class templates - left out
// because its definition struct does not hold its name as a plain char* at any offset in the first
// 0x40 bytes, so reading it needs work this does not need yet.
#define DIR_EXPLOSIVES      0x10
#define DIR_WEAPONS         0x14
#define DIR_UPGRADES        0x18
#define DIR_GEAR            0x20

// CUtlMap<int, T*>: a CUtlRBTree at +0x04, whose element array and root index are these.
#define MAP_ELEMENTS        0x08
#define MAP_ROOT            0x14

// One CUtlRBTree node: Links_t { Left, Right, Parent, Tag } then Node_t { Key, Value }.
#define NODE_SIZE           24
#define NODE_LEFT           0x00
#define NODE_RIGHT          0x04
#define NODE_PARENT         0x08
#define NODE_KEY            0x10
#define NODE_VALUE          0x14

// Offset of the name char* within each definition struct. These differ per type, which is why
// ListItems is a template instantiated four times rather than one function.
#define NAME_WEAPON         0x30
#define NAME_UPGRADE        0x1c
#define NAME_EXPLOSIVE      0x04
#define NAME_GEAR           0x10

#define MAX_NAME            64

// A theater with more entries than this in one category would be extraordinary; the cap only exists
// so a corrupt tree cannot spin forever.
#define MAX_ITEMS           4096

// Bounds for the node array. The largest table on the theater this was written against holds 246
// entries; anything past this is a sign the walk has gone wrong and should stop rather than index
// further into memory.
#define MAX_NODES           16384

// SAFETY
//
// LoadFromAddress will happily read any address handed to it, and a wrong one takes the whole server
// down - that is not hypothetical, a scanning version of this walk crashed the test server while it
// was being written. Two rules follow, and both matter:
//
//   1. Never dereference anything that has not been bounds-checked first. IsPointer rejects the
//      values that are obviously not addresses, which is what catches a table that is not a table.
//   2. Never search. Only the four documented director offsets are read; nothing probes for tables,
//      because probing means dereferencing whatever happens to be in a field, which is exactly the
//      thing that crashed it.
//
// These guards catch "not a pointer". They cannot catch "a valid pointer to the wrong thing", so
// the offsets still have to be right - they are verified against this build, and the count check in
// BuildTables is the tripwire if a game update ever moves them.
#define MIN_POINTER         0x10000

Handle    g_hGetDirector = null;

StringMap g_NameToId[view_as<int>(TheaterCategory_Count)];
ArrayList g_IdToName[view_as<int>(TheaterCategory_Count)];
int       g_Count[view_as<int>(TheaterCategory_Count)];
bool      g_bReady = false;

GlobalForward g_fwdOnReady;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("TheaterItem_Find", Native_Find);
    CreateNative("TheaterItem_Name", Native_Name);
    CreateNative("TheaterItem_Count", Native_Count);
    CreateNative("TheaterItem_Ready", Native_Ready);
    RegPluginLibrary("gg2_theater_items");
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("sm_theateritems_version", PLUGIN_VERSION, "Theater item lookup version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_fwdOnReady = new GlobalForward("TheaterItems_OnReady", ET_Ignore);

    for (int i = 0; i < view_as<int>(TheaterCategory_Count); i++)
    {
        g_NameToId[i] = new StringMap();
        g_IdToName[i] = new ArrayList(ByteCountToCells(MAX_NAME));
    }

    RegAdminCmd("sm_theateritems", Command_Dump, ADMFLAG_CONFIG, "sm_theateritems <category> [substring] - list theater items and their ids");

    SetupDirectorCall();
}

void SetupDirectorCall()
{
    Handle conf = LoadGameConfigFile("tug2.games");
    if (conf == null)
    {
        LogError("Missing gamedata \"tug2.games\" - theater item lookup unavailable");
        return;
    }

    StartPrepSDKCall(SDKCall_Static);
    if (!PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "SendProxy_TheaterDirector"))
    {
        delete conf;
        LogError("Missing \"SendProxy_TheaterDirector\" in tug2.games - theater item lookup unavailable");
        return;
    }

    // (SendProp*, void* pStructBase, void* pData, CSendProxyRecipients* pRecipients, int objectID).
    // All five are passed as null/0: the only one the function touches is pRecipients, which it
    // writes to when non-null, so a null keeps it to a plain read of the global.
    for (int i = 0; i < 5; i++) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);

    g_hGetDirector = EndPrepSDKCall();
    delete conf;

    if (g_hGetDirector == null)
        LogError("Failed to prepare SendProxy_TheaterDirector - theater item lookup unavailable");
}

// The theater is parsed during level load, so by OnMapStart the tables are populated. The retry is
// for the case where they are not yet - cheap insurance against a load-order change.
public void OnMapStart()
{
    g_bReady = false;
    if (!BuildTables()) CreateTimer(1.0, Timer_Retry, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Retry(Handle timer)
{
    if (!g_bReady && !BuildTables())
        LogError("Theater definition tables were still unreadable a second after map start - lookups will fail");

    return Plugin_Stop;
}

bool BuildTables()
{
    if (g_hGetDirector == null) return false;

    int director = SDKCall(g_hGetDirector, 0, 0, 0, 0, 0);
    if (!IsPointer(director)) return false;

    static const int offsets[]     = { DIR_WEAPONS, DIR_UPGRADES, DIR_EXPLOSIVES, DIR_GEAR };
    static const int nameOffsets[] = { NAME_WEAPON, NAME_UPGRADE, NAME_EXPLOSIVE, NAME_GEAR };

    int total = 0;
    for (int i = 0; i < view_as<int>(TheaterCategory_Count); i++)
    {
        g_NameToId[i].Clear();
        g_IdToName[i].Clear();
        g_Count[i] = ReadTable(Deref(director, offsets[i]), nameOffsets[i], i);
        total += g_Count[i];
    }

    if (total <= 0) return false;

    g_bReady = true;
    LogMessage("Theater items: %d weapons, %d upgrades, %d explosives, %d gear",
               g_Count[0], g_Count[1], g_Count[2], g_Count[3]);

    Call_StartForward(g_fwdOnReady);
    Call_Finish();

    return true;
}

// Walks one CUtlMap in key order, exactly as the game's own ListItems does: descend to the leftmost
// node, then take the in-order successor repeatedly.
int ReadTable(int table, int nameOffset, int category)
{
    if (!IsPointer(table)) return 0;

    int elements = Deref(table, MAP_ELEMENTS);
    int root     = Deref(table, MAP_ROOT);
    if (!IsPointer(elements) || !IsNodeIndex(root)) return 0;

    int node = Leftmost(elements, root);

    int count = 0;
    while (node != -1 && count < MAX_ITEMS)
    {
        int id  = Deref(elements, node * NODE_SIZE + NODE_KEY);
        int def = Deref(elements, node * NODE_SIZE + NODE_VALUE);

        if (id < 1 || id > MAX_ITEMS) break;

        // The game skips null definitions when listing, and so does this - but note that the id is
        // still read from the key rather than inferred from position, so a hole costs one item
        // rather than shifting everything after it.
        if (IsPointer(def))
        {
            int namePtr = Deref(def, nameOffset);
            char name[MAX_NAME];
            if (IsPointer(namePtr)) ReadCString(namePtr, name, sizeof(name));
            else name[0] = '\0';

            if (name[0] != '\0')
            {
                char key[MAX_NAME];
                strcopy(key, sizeof(key), name);
                LowercaseString(key);
                g_NameToId[category].SetValue(key, id);

                // Indexed by id-1, which the dense 1..N keys make exact. A gap would leave a blank
                // entry rather than a wrong one.
                while (g_IdToName[category].Length < id) g_IdToName[category].PushString("");
                g_IdToName[category].SetString(id - 1, name);

                count++;
            }
        }

        node = NextInorder(elements, node);
    }

    return count;
}

// Both walkers bail to -1 on anything out of range rather than following it, so a tree that is not
// a tree ends the read instead of walking off into unmapped memory.
int Leftmost(int elements, int node)
{
    for (int guard = 0; guard < MAX_NODES; guard++)
    {
        if (!IsNodeIndex(node)) return -1;
        int left = Deref(elements, node * NODE_SIZE + NODE_LEFT);
        if (left == -1) return node;
        if (!IsNodeIndex(left)) return -1;
        node = left;
    }

    return -1;
}

int NextInorder(int elements, int node)
{
    if (!IsNodeIndex(node)) return -1;

    int right = Deref(elements, node * NODE_SIZE + NODE_RIGHT);
    if (IsNodeIndex(right)) return Leftmost(elements, right);
    if (right != -1) return -1;

    for (int guard = 0; guard < MAX_NODES; guard++)
    {
        int parent = Deref(elements, node * NODE_SIZE + NODE_PARENT);
        if (parent == -1) return -1;
        if (!IsNodeIndex(parent)) return -1;
        if (Deref(elements, parent * NODE_SIZE + NODE_LEFT) == node) return parent;
        node = parent;
    }

    return -1;
}

bool IsPointer(int address)
{
    return address >= MIN_POINTER;
}

bool IsNodeIndex(int index)
{
    return index >= 0 && index < MAX_NODES;
}

int Deref(int address, int offset)
{
    return LoadFromAddress(view_as<Address>(address + offset), NumberType_Int32);
}

void ReadCString(int address, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (address == 0) return;

    for (int i = 0; i < maxlen - 1; i++)
    {
        int c = LoadFromAddress(view_as<Address>(address + i), NumberType_Int8);
        buffer[i]     = view_as<char>(c);
        buffer[i + 1] = '\0';
        if (c == 0) return;
    }
}

void LowercaseString(char[] text)
{
    for (int i = 0; text[i] != '\0'; i++) text[i] = CharToLower(text[i]);
}

bool ValidCategory(int category)
{
    return category >= 0 && category < view_as<int>(TheaterCategory_Count);
}

// ---------------------------------------------------------------------------------------------
// Natives
// ---------------------------------------------------------------------------------------------

public any Native_Find(Handle plugin, int numParams)
{
    int category = GetNativeCell(1);
    if (!g_bReady || !ValidCategory(category)) return 0;

    int length;
    GetNativeStringLength(2, length);
    if (length < 1) return 0;

    char[] name = new char[length + 1];
    GetNativeString(2, name, length + 1);
    LowercaseString(name);

    int id;
    return g_NameToId[category].GetValue(name, id) ? id : 0;
}

public any Native_Name(Handle plugin, int numParams)
{
    int category = GetNativeCell(1);
    int id       = GetNativeCell(2);
    if (!g_bReady || !ValidCategory(category)) return false;
    if (id < 1 || id > g_IdToName[category].Length) return false;

    char name[MAX_NAME];
    g_IdToName[category].GetString(id - 1, name, sizeof(name));
    if (name[0] == '\0') return false;

    SetNativeString(3, name, GetNativeCell(4));
    return true;
}

public any Native_Count(Handle plugin, int numParams)
{
    int category = GetNativeCell(1);
    return (g_bReady && ValidCategory(category)) ? g_Count[category] : 0;
}

public any Native_Ready(Handle plugin, int numParams)
{
    return g_bReady;
}

// ---------------------------------------------------------------------------------------------
// Admin command - the thing you actually use to find out what an id is
// ---------------------------------------------------------------------------------------------

public Action Command_Dump(int client, int args)
{
    if (!g_bReady)
    {
        ReplyToCommand(client, "[Theater Items] Tables not read - see the server log.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Theater Items] Usage: sm_theateritems <weapon|upgrade|explosive|gear> [substring]");
        for (int i = 0; i < view_as<int>(TheaterCategory_Count); i++)
        {
            char label[16];
            CategoryName(i, label, sizeof(label));
            ReplyToCommand(client, "[Theater Items]   %s: %d", label, g_Count[i]);
        }
        return Plugin_Handled;
    }

    char arg[32];
    GetCmdArg(1, arg, sizeof(arg));

    int category = -1;
    for (int i = 0; i < view_as<int>(TheaterCategory_Count); i++)
    {
        char label[16];
        CategoryName(i, label, sizeof(label));
        if (StrEqual(arg, label, false)) category = i;
    }

    if (category == -1)
    {
        ReplyToCommand(client, "[Theater Items] Unknown category \"%s\".", arg);
        return Plugin_Handled;
    }

    char filter[MAX_NAME];
    if (args >= 2)
    {
        GetCmdArg(2, filter, sizeof(filter));
        LowercaseString(filter);
    }

    int shown = 0;
    for (int id = 1; id <= g_IdToName[category].Length; id++)
    {
        char name[MAX_NAME];
        g_IdToName[category].GetString(id - 1, name, sizeof(name));
        if (name[0] == '\0') continue;

        if (filter[0] != '\0')
        {
            char lower[MAX_NAME];
            strcopy(lower, sizeof(lower), name);
            LowercaseString(lower);
            if (StrContains(lower, filter) == -1) continue;
        }

        ReplyToCommand(client, "[Theater Items] %4d  %s", id, name);
        shown++;
    }

    char label[16];
    CategoryName(category, label, sizeof(label));
    ReplyToCommand(client, "[Theater Items] %d %s shown.", shown, label);
    return Plugin_Handled;
}

void CategoryName(int category, char[] buffer, int maxlen)
{
    static const char names[][] = { "weapon", "upgrade", "explosive", "gear" };
    strcopy(buffer, maxlen, ValidCategory(category) ? names[category] : "?");
}
