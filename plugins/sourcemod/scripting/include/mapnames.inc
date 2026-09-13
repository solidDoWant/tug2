#if defined _mapnames_included_
  #endinput
#endif
#define _mapnames_included_

#include <sourcemod>

/**
 * Display names for maps.
 *
 * WHY THIS IS NOT A LOCALISATION LOOKUP. Weapons have display names to read - every one carries a
 * "print_name" token that resolves in the mounted localisation files (see weaponnames.inc). Maps do
 * not, at least not here: of the 133 maps in the test server's mapcycle, exactly ONE
 * (embassy_coop, a stock map) has a name token, and only one subscribed workshop item ships an
 * English localisation file at all - the TUG scripts pack, which carries no map names. Measured, not
 * assumed. Every other map on this server is a workshop map whose only name is its filename.
 *
 * So the name is DERIVED from the filename, and an override file handles the few the derivation
 * cannot get right. "district_night_coop" becomes "District Night", "cs_motel_coop_nd_v1_3" becomes
 * "Motel", "warehouse_coopv3b4" becomes "Warehouse".
 *
 * WHAT THE DERIVATION DROPS. Everything in a map filename that is not the name of the place:
 *
 *   gamemode      coop, pve, hunt, checkpoint, firefight...      market_night_coop -> Market Night
 *   build tags    b2, v1_3, rc1, coopv3b4, x64, tug24, 2021      prospect_coop_b6  -> Prospect
 *   port prefixes ins_, de_, cs_, pl_, l4d_ - which game it       de_nuke           -> Nuke
 *                 came from, not where it is
 *   port suffixes aof, gf, ws, fix, fixed, new, nd               point_blank_fix   -> Point Blank
 *
 * A number that is part of the name survives, because a build tag is recognised by the letters in
 * front of its digits rather than by the digits: "b2" and "coopv3" are tags, "trenches6" is a map.
 *
 * The derivation is deliberately conservative about gamemode words. "coop" and "pve" are dropped
 * wherever they appear and whatever is glued to them, since no place name begins with either, but
 * the rest have to match a whole token so a map called Hunters Point keeps its name.
 */

static StringMap g_MapNames = null;

// Dropped as a whole token anywhere in the name.
static char g_MapNameModes[][] = {
    "checkpoint", "firefight", "skirmish", "survival", "outpost", "ambush", "occupy", "push",
    "strike", "flashpoint", "conquer", "elimination", "infiltrate", "hunt", "pvp"
};

// Dropped as a whole token anywhere in the name: port, author and revision tags.
static char g_MapNameJunk[][] = {
    "aof", "gf", "ws", "csgo", "nd", "fix", "fixed", "new", "old", "final", "beta", "alpha",
    "remake", "remastered", "ins", "sp", "mp"
};

// Dropped only as the FIRST token: these say which game a port came from, not where it is.
// "doi" is deliberately absent - DOI maps are known by it.
static char g_MapNamePrefixes[][] = {
    "ins", "de", "cs", "pl", "cp", "l4d", "bb", "rp", "ctf", "koth", "tc", "dod", "csgo"
};

// Letters that can stand in front of a build number. A token whose letters are one of these and
// whose tail is digits is a build tag; anything else with digits in it is a name with a number.
static char g_MapNameTagHeads[][] = {
    "", "v", "b", "a", "p", "r", "rc", "pb", "rb", "x", "f", "n", "nv", "ver", "rev", "tug", "mod"
};

// Words that are acronyms rather than capitalised words.
static char g_MapNameAcronyms[][2][8] = {
    { "doi", "DOI" }, { "pow", "POW" }, { "usa", "USA" }, { "fob", "FOB" },
    { "nato", "NATO" }, { "ww2", "WW2" }, { "usmc", "USMC" }
};

/**
 * Loads configs/mapnames.cfg, the override file. Optional - without it every name is derived.
 *
 * @return  How many overrides were loaded.
 */
stock int MapNames_Load()
{
    delete g_MapNames;
    g_MapNames = new StringMap();

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/mapnames.cfg");

    KeyValues kv = new KeyValues("MapNames");
    if (!kv.ImportFromFile(path))
    {
        delete kv;
        LogMessage("[MapNames] no configs/mapnames.cfg, every name will be derived from the filename");
        return 0;
    }

    int count = 0;
    if (kv.GotoFirstSubKey(false))
    {
        do
        {
            char map[128], display[128];
            kv.GetSectionName(map, sizeof(map));
            kv.GetString(NULL_STRING, display, sizeof(display));
            if (map[0] == '\0' || display[0] == '\0') continue;

            // GetCurrentMap returns whatever case the file is on disk ("Docks_coopb2_day"), so both
            // sides of the lookup are lowercased - StringMap is case-sensitive, KeyValues is not.
            MapNames_ToLower(map, sizeof(map));
            g_MapNames.SetString(map, display, true);
            count++;
        }
        while (kv.GotoNextKey(false));
    }
    delete kv;

    LogMessage("[MapNames] %d map name overrides loaded", count);
    return count;
}

/**
 * The display name for a map.
 *
 * Always writes something usable, so there is no failure case to handle - a name with no override
 * and nothing the derivation recognises comes back as the filename with its underscores turned into
 * spaces and its words capitalised.
 *
 * @param map     Map name as GetCurrentMap returns it.
 * @param buffer  Receives the display name.
 * @param maxlen  Size of buffer.
 * @return        true if this came from the override file, false if it was derived.
 */
stock bool MapNames_Get(const char[] map, char[] buffer, int maxlen)
{
    char key[128];
    strcopy(key, sizeof(key), map);
    MapNames_ToLower(key, sizeof(key));

    if (g_MapNames != null && g_MapNames.GetString(key, buffer, maxlen)) return true;

    MapNames_Derive(key, buffer, maxlen);
    return false;
}

/**
 * The display name for the map that is loaded now. Convenience wrapper - the callers that want this
 * all want the current map.
 */
stock bool MapNames_GetCurrent(char[] buffer, int maxlen)
{
    char map[128];
    GetCurrentMap(map, sizeof(map));
    return MapNames_Get(map, buffer, maxlen);
}

stock void MapNames_Derive(const char[] lowerMap, char[] buffer, int maxlen)
{
    char work[128];
    strcopy(work, sizeof(work), lowerMap);
    ReplaceString(work, sizeof(work), "-", "_");

    char parts[12][32];
    int  n = ExplodeString(work, "_", parts, sizeof(parts), sizeof(parts[]));

    char kept[12][32];
    int  keptCount = 0;

    for (int i = 0; i < n; i++)
    {
        if (parts[i][0] == '\0') continue;
        if (MapNames_IsDropped(parts[i], i == 0)) continue;

        // A word that ends in a build number keeps the word: trenches6 -> trenches. Only when there
        // is a real word in front of the digits, which is the same test MapNames_IsBuildTag uses.
        char word[32];
        strcopy(word, sizeof(word), parts[i]);
        for (int c = 0; word[c] != '\0'; c++)
        {
            if (!IsCharNumeric(word[c])) continue;
            if (c >= 4) word[c] = '\0';
            break;
        }

        strcopy(kept[keptCount], sizeof(kept[]), word);
        if (++keptCount >= sizeof(kept)) break;
    }

    // Everything was dropped - a name made entirely of tags. Better the raw first token than "".
    if (keptCount == 0)
    {
        strcopy(kept[0], sizeof(kept[]), parts[0]);
        keptCount = 1;
    }

    buffer[0] = '\0';
    for (int i = 0; i < keptCount; i++)
    {
        if (i > 0) StrCat(buffer, maxlen, " ");

        char word[32];
        strcopy(word, sizeof(word), kept[i]);
        MapNames_Capitalise(word, sizeof(word));
        StrCat(buffer, maxlen, word);
    }
}

stock bool MapNames_IsDropped(const char[] word, bool isFirst)
{
    // No place name starts with either, so these go whatever is glued to them: coop, coopb2,
    // coopv3b4, coop2021, coopvfix, pve.
    if (StrContains(word, "coop") == 0) return true;
    if (StrContains(word, "pve") == 0) return true;

    for (int i = 0; i < sizeof(g_MapNameModes); i++)
        if (StrEqual(word, g_MapNameModes[i])) return true;

    for (int i = 0; i < sizeof(g_MapNameJunk); i++)
        if (StrEqual(word, g_MapNameJunk[i])) return true;

    if (isFirst)
    {
        for (int i = 0; i < sizeof(g_MapNamePrefixes); i++)
            if (StrEqual(word, g_MapNamePrefixes[i])) return true;
    }

    // A lone letter left over from a chopped-up filename carries nothing.
    if (strlen(word) == 1) return true;

    return MapNames_IsBuildTag(word);
}

// b2, v1, rc3, x64, nv1, tug24, 2021 - but not trenches6 or dust2, where the letters in front of
// the digits are the name.
stock bool MapNames_IsBuildTag(const char[] word)
{
    int firstDigit = -1;
    for (int i = 0; word[i] != '\0'; i++)
    {
        if (!IsCharNumeric(word[i])) continue;
        firstDigit = i;
        break;
    }
    if (firstDigit == -1) return false;

    char head[32];
    strcopy(head, firstDigit + 1, word);

    for (int i = 0; i < sizeof(g_MapNameTagHeads); i++)
        if (StrEqual(head, g_MapNameTagHeads[i])) return true;

    return false;
}

stock void MapNames_Capitalise(char[] word, int maxlen)
{
    for (int i = 0; i < sizeof(g_MapNameAcronyms); i++)
    {
        if (!StrEqual(word, g_MapNameAcronyms[i][0])) continue;
        strcopy(word, maxlen, g_MapNameAcronyms[i][1]);
        return;
    }

    if (word[0] != '\0') word[0] = CharToUpper(word[0]);
}

stock void MapNames_ToLower(char[] text, int maxlen)
{
    for (int i = 0; i < maxlen && text[i] != '\0'; i++)
        text[i] = CharToLower(text[i]);
}
