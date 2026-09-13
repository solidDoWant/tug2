#if defined _workshopmaps_included_
  #endinput
#endif
#define _workshopmaps_included_

#include <sourcemod>

/**
 * Which workshop item provides a given map.
 *
 * Nothing in the engine or SourceMod exposes this, but the filesystem does: a subscribed workshop
 * item is unpacked into its own directory named after its published file id, and a map item leaves
 * its .bsp loose inside it.
 *
 *     ../steamapps/workshop/content/222880/<published file id>/maps/<mapname>.bsp
 *
 * So the mapping is built by listing every item directory once and reading the map names out of it.
 * On this server that resolves 69 of the 70 maps in the mapcycle, each to exactly one item - the
 * only miss is embassy_coop, which is a stock base game map and not workshop content at all.
 *
 * THE PATH IS RELATIVE TO THE GAME DIRECTORY. SourceMod's non-Valve-filesystem calls resolve
 * against insurgency/, so ".." is the server root that holds both insurgency/ and steamapps/.
 * That is this deployment's layout; a server laid out differently just gets no mappings and every
 * caller falls back, which is why nothing here fails hard.
 *
 * WHY THIS ENUMERATES DIRECTORIES INSTEAD OF ASKING FOR THE FILE. The obvious implementation -
 * FileExists("<item>/maps/<map>.bsp") for the map you care about - does not work here. casecache.so
 * is LD_PRELOADed and answers stat/access from an index it builds over the game directory at
 * startup, so both FileExists and OpenFile report these paths as missing even though they are
 * present and readable. opendir is not intercepted the same way and returns the real contents.
 * Measured on this server: OpenDirectory lists game_day.bsp in item 2888145663 while FileExists on
 * that exact path returns false. Do not "simplify" this back into a FileExists call.
 */

// SourcePawn has no string concatenation, so the appid (Insurgency 2014 is 222880) is written into
// the path rather than composed from a constant.
#define WORKSHOP_CONTENT_DIR  "../steamapps/workshop/content/222880"

static StringMap g_WorkshopMaps = null;

/**
 * Builds the map-to-item mapping. One directory listing per installed item, ~108 of them here, so
 * this is a load-time cost and not something to repeat per message.
 *
 * Workshop downloads happen at server startup, so calling this once from OnPluginStart is enough.
 *
 * @return  How many maps were mapped to an item.
 */
stock int WorkshopMaps_Load()
{
    delete g_WorkshopMaps;
    g_WorkshopMaps = new StringMap();

    DirectoryListing items = OpenDirectory(WORKSHOP_CONTENT_DIR);
    if (items == null)
    {
        LogMessage("[WorkshopMaps] %s is not readable - map names will not be linked to workshop items",
                   WORKSHOP_CONTENT_DIR);
        return 0;
    }

    int mapped = 0;
    int scanned = 0;

    char item[64];
    FileType type;
    while (items.GetNext(item, sizeof(item), type))
    {
        // The directory holds one subdirectory per item, named with its published file id, plus the
        // occasional stray file (there is a .dockerignore in there). A published file id is all
        // digits, which is a cheaper and more reliable filter than the entry type.
        if (!WorkshopMaps_IsFileId(item)) continue;
        scanned++;

        char mapsDir[PLATFORM_MAX_PATH];
        Format(mapsDir, sizeof(mapsDir), "%s/%s/maps", WORKSHOP_CONTENT_DIR, item);

        DirectoryListing maps = OpenDirectory(mapsDir);
        if (maps == null) continue;    // not a map item - weapons, sounds, scripts

        char entry[PLATFORM_MAX_PATH];
        while (maps.GetNext(entry, sizeof(entry), type))
        {
            int len = strlen(entry);
            if (len <= 4 || !StrEqual(entry[len - 4], ".bsp", false)) continue;
            entry[len - 4] = '\0';

            for (int i = 0; entry[i] != '\0'; i++)
                entry[i] = CharToLower(entry[i]);

            // No map on this server is provided by two items, but nothing stops it. Keep the first
            // and say so rather than silently picking whichever the filesystem listed last.
            char existing[64];
            if (g_WorkshopMaps.GetString(entry, existing, sizeof(existing)))
            {
                if (!StrEqual(existing, item))
                    LogMessage("[WorkshopMaps] %s is provided by items %s and %s; keeping %s",
                               entry, existing, item, existing);
                continue;
            }

            g_WorkshopMaps.SetString(entry, item, true);
            mapped++;
        }
        delete maps;
    }
    delete items;

    LogMessage("[WorkshopMaps] %d maps mapped to workshop items across %d installed items", mapped, scanned);
    return mapped;
}

/**
 * The published file id of the workshop item that provides a map.
 *
 * @param map     Map name as GetCurrentMap returns it, without .bsp.
 * @param buffer  Receives the id.
 * @param maxlen  Size of buffer.
 * @return        true if the map came from a workshop item, false for a stock map or an unreadable
 *                workshop directory.
 */
stock bool WorkshopMaps_GetItem(const char[] map, char[] buffer, int maxlen)
{
    if (g_WorkshopMaps == null) return false;

    char key[PLATFORM_MAX_PATH];
    strcopy(key, sizeof(key), map);
    for (int i = 0; key[i] != '\0'; i++)
        key[i] = CharToLower(key[i]);

    return g_WorkshopMaps.GetString(key, buffer, maxlen);
}

/**
 * The workshop page URL for the item that provides a map.
 *
 * Wrapped in angle brackets, which is what suppresses Discord's link preview - the same thing
 * gen_tug_link does for player profiles. Harmless anywhere else.
 *
 * @return  true if a URL was written.
 */
stock bool WorkshopMaps_GetUrl(const char[] map, char[] buffer, int maxlen)
{
    char item[64];
    if (!WorkshopMaps_GetItem(map, item, sizeof(item))) return false;

    Format(buffer, maxlen, "<https://steamcommunity.com/sharedfiles/filedetails/?id=%s>", item);
    return true;
}

stock bool WorkshopMaps_IsFileId(const char[] name)
{
    if (name[0] == '\0') return false;

    for (int i = 0; name[i] != '\0'; i++)
        if (!IsCharNumeric(name[i])) return false;

    return true;
}
