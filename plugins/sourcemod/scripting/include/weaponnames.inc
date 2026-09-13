#if defined _weaponnames_included_
  #endinput
#endif
#define _weaponnames_included_

#include <sourcemod>

/**
 * Display names for weapons, from the game's own localisation files.
 *
 * WHY THIS EXISTS. Everything a plugin can get hold of names a weapon by classname -
 * GetClientWeapon, the player_death "weapon" field, LoadoutSaver's stored purchase list - and
 * "weapon_m4a1sopmod" is not a thing to show a person. The pretty name already exists: every weapon
 * in the theater carries "print_name" "#<classname>", and those tokens resolve in the localisation
 * files. This reads those files directly and hands back the same string the buy menu shows.
 *
 * The server has the files through the engine's filesystem rather than the real one - the stock one
 * lives inside insurgency_misc_dir.vpk and TUG's inside a workshop VPK - so OpenFile is called with
 * use_valve_fs.
 *
 * ENCODING IS THE AWKWARD PART. They are UTF-16LE, so every ASCII character is a byte followed by a
 * zero. ReadFileLine stops dead at the first of those zeros and KeyValues cannot parse the file at
 * all, hence the byte-level read and hand-rolled scan in WeaponNames_Load.
 *
 * This is an include rather than a natives-providing plugin on purpose: it is a few hundred
 * read-only strings built once at load, so a copy per plugin costs less than a cross-plugin load
 * order dependency would.
 *
 * Call WeaponNames_Load() once from OnPluginStart - the files are mounted by the engine and do not
 * change between maps. WeaponNames_Get works without it, falling back to trimmed classnames.
 */

static StringMap g_WeaponNames = null;

/**
 * Builds the lookup. Safe to call again; the previous table is discarded.
 *
 * @return  How many names were loaded.
 */
stock int WeaponNames_Load()
{
    delete g_WeaponNames;
    g_WeaponNames = new StringMap();

    // Stock first, TUG second: TUG renames some stock weapons and the later load must win.
    int n = WeaponNames_ParseFile("resource/insurgency_english.txt");
    n += WeaponNames_ParseFile("resource/ui/tug_english_modern.txt");

    // Four weapons name a token that is NOT their classname, so the convention the lookup relies on
    // does not hold for them and they would fall back to a bare classname. Checked across the whole
    // set: 118 of 122 use "#<classname>" and need nothing, these four are the exceptions, and each
    // token below is the print_name the theater actually declares for that weapon.
    WeaponNames_Alias("weapon_M107", "weapon_m107barrett");
    WeaponNames_Alias("weapon_m16a4", "weapon_m16");
    WeaponNames_Alias("weapon_g33", "weapon_g3a3");
    WeaponNames_Alias("weapon_c4_clicker", "weapon_c4");

    char plugin[64];
    GetPluginFilename(INVALID_HANDLE, plugin, sizeof(plugin));

    char sample[64];
    if (!g_WeaponNames.GetString("weapon_m4a1sopmod", sample, sizeof(sample)))
        strcopy(sample, sizeof(sample), "<not found>");

    char sample2[64];
    if (!g_WeaponNames.GetString("grenade_m67", sample2, sizeof(sample2)))
        strcopy(sample2, sizeof(sample2), "<not found>");

    LogMessage("[WeaponNames] %s: %d display names loaded (weapon_m4a1sopmod -> %s, grenade_m67 -> %s)",
               plugin, n, sample, sample2);
    return n;
}

/**
 * The display name for a weapon classname.
 *
 * Always writes something usable: a classname with no localised name comes back with its
 * "weapon_" prefix trimmed, which is still far more readable than the raw string.
 *
 * @param classname  Weapon classname, e.g. "weapon_m4a1sopmod" or "grenade_m67".
 * @param buffer     Receives the display name.
 * @param maxlen     Size of buffer.
 * @return           true if a localised name was found, false if this is the trimmed fallback.
 */
stock bool WeaponNames_Get(const char[] classname, char[] buffer, int maxlen)
{
    if (g_WeaponNames != null)
    {
        if (g_WeaponNames.GetString(classname, buffer, maxlen)) return true;

        // Some callers hand over a name with the prefix already gone - the player_death "weapon"
        // field is not documented to keep it, and a theater is free to write either. One retry
        // covers that without the caller having to know which it has.
        if (StrContains(classname, "weapon_") != 0 && StrContains(classname, "grenade_") != 0)
        {
            char prefixed[80];
            Format(prefixed, sizeof(prefixed), "weapon_%s", classname);
            if (g_WeaponNames.GetString(prefixed, buffer, maxlen)) return true;
        }
    }

    strcopy(buffer, maxlen, classname);
    if (StrContains(buffer, "weapon_") == 0) strcopy(buffer, maxlen, buffer[7]);
    return false;
}

/**
 * Points a classname at a token that differs from it, but only if that token actually resolved -
 * a missing one leaves the classname fallback in place rather than storing an empty name.
 */
stock void WeaponNames_Alias(const char[] classname, const char[] token)
{
    char value[64];
    if (g_WeaponNames.GetString(token, value, sizeof(value)))
        g_WeaponNames.SetString(classname, value, true);
}

/**
 * Returns how many tokens were added. Tolerates a missing file - a server without TUG mounted simply
 * gets fewer names and falls back to classnames.
 */
stock int WeaponNames_ParseFile(const char[] path)
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
                    if (WeaponNames_StoreLine(line)) added++;
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
        if (WeaponNames_StoreLine(line)) added++;
    }
    return added;
}

/**
 * One line of the Tokens block is  "key"  "value"  - take the first two quoted runs and keep the
 * pair only when the key names something a player can be killed by.
 *
 * TWO KEY FAMILIES, because guns and everything else are localised differently:
 *
 *   weapon_<classname>  the buy-menu name. Guns only - no grenade or rocket has one.
 *   death_<classname>   the kill-feed name, which is where grenades, rockets, the cache and the
 *                       props live: "death_grenade_m67" "M67". Stored under the classname with
 *                       "death_" removed so one lookup serves both families. This repo's own
 *                       localisation already follows it - see death_grenade_m777_wp_us in
 *                       fastdl/src/localization.
 *
 * A handful of death_ tokens are not weapons at all (death_fall, death_world, death_teamkill). They
 * are kept: they only ever match if a caller passes that string, and when one does, the token is
 * exactly the right words for it.
 */
stock bool WeaponNames_StoreLine(const char[] line)
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

    bool isDeath = (StrContains(key, "death_") == 0);
    if (!isDeath && StrContains(key, "weapon_") != 0) return false;

    // Descriptions share the prefix and would otherwise overwrite the name with a sentence.
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

    // "death_" is 6 characters. The two families cannot collide - that would need a token literally
    // called death_weapon_<something> - so both are stored the same way and the later file wins.
    int keyStart = isDeath ? 6 : 0;
    g_WeaponNames.SetString(key[keyStart], value, true);
    return true;
}
