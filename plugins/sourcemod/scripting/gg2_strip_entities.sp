/**
 * [GG2 STRIP ENTITIES] Remove map entities before they spawn.
 *
 * WHY THIS EXISTS
 * Some custom maps reference assets they forgot to pack. A client that cannot load a material does
 * not cache the failure, so it retries every time something asks for that material - many times a
 * second - and the framerate collapses. It shows up in the client console as:
 *
 *     CMaterial::PrecacheVars: error loading vmt file for decals/rug_green01
 *
 * showdown is the worked example: 21 infodecal entities using 19 materials, 18 of them packed
 * inside the BSP and exactly one - decals/rug_green01 - missing. Nothing else in the map refers to
 * it, so deleting that one entity removes the reference entirely and the retry storm stops.
 *
 * WHY NOT gg2_kill_entities
 * That plugin removes entities in OnMapStart, which is too late for this class of problem. An
 * infodecal with no targetname applies its decal and deletes itself during spawn, so by OnMapStart
 * there is no entity left to remove and the decal is already on the world. The only point early
 * enough is OnLevelInit, which hands over the raw entity lump before anything spawns.
 *
 * WHAT THIS IS NOT
 * It does not repair the map - the asset is still missing. It removes the thing that asks for it.
 * Where a missing material is baked into brush faces or a static overlay rather than referenced by
 * an entity there is nothing to strip, and the fix has to be a stub material shipped to clients.
 *
 * Rules live in configs/gg2_strip_entities.cfg so a newly discovered bad map is a config edit.
 */

#include <sourcemod>

#pragma newdecls required
#pragma semicolon 1

#define MAX_RULES        128
#define MAX_KEY          64
#define MAX_VALUE        192
#define MAX_MAPNAME      96

// The engine hands OnLevelInit a fixed 2MB buffer. Entity lumps are far smaller in practice
// (showdown is 93KB), but the buffer size is the hard ceiling on what can be written back.
#define ENT_BUFFER       2097152

enum struct StripRule
{
    char map[MAX_MAPNAME];      // map name, or "*" for every map
    char classname[MAX_KEY];    // required classname, or "" for any
    char key[MAX_KEY];          // additional keyvalue to match, or "" for none
    char value[MAX_VALUE];      // the value that key must have
    char note[MAX_VALUE];       // why this rule exists, echoed when it fires
    int  hits;
}

StripRule g_Rules[MAX_RULES];
int       g_iNumRules = 0;

ConVar    g_cvEnabled;
ConVar    g_cvDebug;

public Plugin myinfo =
{
    name        = "[GG2 STRIP] Strip Entities",
    author      = "TUG",
    description = "Removes map entities that reference missing assets, before they spawn",
    version     = "1.0.0",
    url         = "https://github.com/solidDoWant/tug2"
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar("sm_strip_entities_enabled", "1",
        "Strip entities matching configs/gg2_strip_entities.cfg at level load.", _, true, 0.0, true, 1.0);
    g_cvDebug = CreateConVar("sm_strip_entities_debug", "0",
        "Log every entity removed, not just a per-map total.", _, true, 0.0, true, 1.0);

    RegAdminCmd("sm_strip_entities_reload", Cmd_Reload, ADMFLAG_CONFIG,
        "Reload the strip rules. Takes effect on the next map load.");
    RegAdminCmd("sm_strip_entities_rules", Cmd_Rules, ADMFLAG_CONFIG,
        "List the loaded strip rules and how many entities each has removed.");

    LoadRules();
}

public Action Cmd_Reload(int client, int args)
{
    LoadRules();
    ReplyToCommand(client, "[STRIP] Reloaded: %d rule(s). Applies from the next map load.", g_iNumRules);
    return Plugin_Handled;
}

public Action Cmd_Rules(int client, int args)
{
    ReplyToCommand(client, "[STRIP] %d rule(s):", g_iNumRules);
    for (int i = 0; i < g_iNumRules; i++)
    {
        ReplyToCommand(client, "  [%s] %s%s%s%s -> %d removed this session | %s",
                       g_Rules[i].map,
                       g_Rules[i].classname[0] ? g_Rules[i].classname : "<any class>",
                       g_Rules[i].key[0] ? " where " : "",
                       g_Rules[i].key,
                       g_Rules[i].key[0] ? g_Rules[i].value : "",
                       g_Rules[i].hits, g_Rules[i].note);
    }
    return Plugin_Handled;
}

void LoadRules()
{
    g_iNumRules = 0;

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/gg2_strip_entities.cfg");
    if (!FileExists(path))
    {
        LogMessage("[STRIP] No %s - nothing to strip.", path);
        return;
    }

    KeyValues kv = new KeyValues("StripEntities");
    if (!kv.ImportFromFile(path))
    {
        LogError("[STRIP] Could not parse %s - no entities will be stripped.", path);
        delete kv;
        return;
    }

    // Structure is map -> rule -> fields, so a map section holds however many rules it needs.
    if (kv.GotoFirstSubKey())
    {
        do
        {
            char mapname[MAX_MAPNAME];
            kv.GetSectionName(mapname, sizeof(mapname));

            if (!kv.GotoFirstSubKey()) continue;
            do
            {
                if (g_iNumRules >= MAX_RULES)
                {
                    LogError("[STRIP] Rule limit (%d) reached - later rules ignored.", MAX_RULES);
                    break;
                }

                strcopy(g_Rules[g_iNumRules].map, MAX_MAPNAME, mapname);
                kv.GetString("classname", g_Rules[g_iNumRules].classname, MAX_KEY, "");
                kv.GetString("key",       g_Rules[g_iNumRules].key,       MAX_KEY, "");
                kv.GetString("value",     g_Rules[g_iNumRules].value,     MAX_VALUE, "");
                kv.GetString("note",      g_Rules[g_iNumRules].note,      MAX_VALUE, "");
                g_Rules[g_iNumRules].hits = 0;

                // A rule matching nothing in particular would strip every entity in the map.
                if (!g_Rules[g_iNumRules].classname[0] && !g_Rules[g_iNumRules].key[0])
                {
                    LogError("[STRIP] Rule for '%s' has neither classname nor key - refusing to load it.", mapname);
                    continue;
                }

                g_iNumRules++;
            }
            while (kv.GotoNextKey());
            kv.GoBack();
        }
        while (kv.GotoNextKey());
    }

    delete kv;
    LogMessage("[STRIP] Loaded %d rule(s).", g_iNumRules);
}

// Does this entity block satisfy the rule? The block is the raw text between { and }, so matching
// is done on the quoted key/value pairs exactly as they appear in the lump.
bool BlockMatches(const char[] block, int rule)
{
    char needle[MAX_KEY + MAX_VALUE + 8];

    if (g_Rules[rule].classname[0])
    {
        Format(needle, sizeof(needle), "\"classname\" \"%s\"", g_Rules[rule].classname);
        if (StrContains(block, needle, false) == -1) return false;
    }

    if (g_Rules[rule].key[0])
    {
        Format(needle, sizeof(needle), "\"%s\" \"%s\"", g_Rules[rule].key, g_Rules[rule].value);
        if (StrContains(block, needle, false) == -1) return false;
    }

    return true;
}

public Action OnLevelInit(const char[] mapName, char mapEntities[ENT_BUFFER])
{
    if (!g_cvEnabled.BoolValue || g_iNumRules == 0) return Plugin_Continue;

    // Which rules apply to this map? Resolved once so the per-entity loop stays cheap.
    int applicable[MAX_RULES];
    int numApplicable = 0;
    for (int i = 0; i < g_iNumRules; i++)
        if (StrEqual(g_Rules[i].map, "*", false) || StrEqual(g_Rules[i].map, mapName, false))
            applicable[numApplicable++] = i;

    if (numApplicable == 0) return Plugin_Continue;

    int originalLen = strlen(mapEntities);

    // Rebuild the lump, copying every entity block except the ones that match. Walking it by brace
    // depth rather than by line keeps this independent of how the compiler laid the text out.
    char[] rebuilt = new char[ENT_BUFFER];
    int    outPos  = 0;
    int    removed = 0;

    int pos = 0;
    while (pos < originalLen)
    {
        int open = FindCharAt(mapEntities, originalLen, pos, '{');
        if (open == -1)
        {
            // Trailing text after the last block - keep it verbatim.
            outPos += CopyRange(rebuilt, ENT_BUFFER, outPos, mapEntities, pos, originalLen);
            break;
        }

        // Anything between blocks (whitespace, usually) is preserved.
        outPos += CopyRange(rebuilt, ENT_BUFFER, outPos, mapEntities, pos, open);

        int close = FindCharAt(mapEntities, originalLen, open, '}');
        if (close == -1)
        {
            // Malformed lump: copy the remainder untouched rather than risk truncating the map.
            LogError("[STRIP] Unterminated entity block on %s at %d - leaving the rest of the lump alone.", mapName, open);
            outPos += CopyRange(rebuilt, ENT_BUFFER, outPos, mapEntities, open, originalLen);
            break;
        }

        int blockLen = close - open + 1;
        char[] block = new char[blockLen + 1];
        CopyRange(block, blockLen + 1, 0, mapEntities, open, close + 1);
        block[blockLen] = '\0';

        // worldspawn carries map-wide settings (skybox, detail material, fog) and removing it
        // breaks the level outright. It is never a legitimate strip target, and it CAN match a
        // well-meaning rule: an audit will happily report worldspawn's "detailmaterial" as a
        // missing asset referenced by an entity. Refuse it regardless of what the rules say.
        bool isWorldspawn = (StrContains(block, "\"classname\" \"worldspawn\"", false) != -1);

        int matched = -1;
        if (!isWorldspawn)
            for (int i = 0; i < numApplicable; i++)
                if (BlockMatches(block, applicable[i])) { matched = applicable[i]; break; }

        if (matched == -1)
        {
            outPos += CopyRange(rebuilt, ENT_BUFFER, outPos, mapEntities, open, close + 1);
        }
        else
        {
            g_Rules[matched].hits++;
            removed++;
            if (g_cvDebug.BoolValue)
                LogMessage("[STRIP] %s: removed entity matching rule [%s] %s %s=%s",
                           mapName, g_Rules[matched].map, g_Rules[matched].classname,
                           g_Rules[matched].key, g_Rules[matched].value);
        }

        pos = close + 1;
    }

    if (removed == 0) return Plugin_Continue;

    rebuilt[outPos] = '\0';
    strcopy(mapEntities, ENT_BUFFER, rebuilt);

    LogMessage("[STRIP] %s: removed %d entit%s (%d -> %d bytes).",
               mapName, removed, removed == 1 ? "y" : "ies", originalLen, outPos);
    return Plugin_Changed;
}

// strlen-bounded character search. SourcePawn's FindCharInString has no start offset, and the
// entity lump is far too large to keep re-slicing.
int FindCharAt(const char[] buffer, int len, int start, char c)
{
    for (int i = start; i < len; i++)
        if (buffer[i] == c) return i;
    return -1;
}

// Copies buffer[from..to) into dest at destPos. Returns how many characters were written, which is
// short of the requested range only if dest would overflow.
int CopyRange(char[] dest, int destSize, int destPos, const char[] src, int from, int to)
{
    int written = 0;
    for (int i = from; i < to && destPos + written < destSize - 1; i++)
        dest[destPos + written++] = src[i];
    return written;
}
