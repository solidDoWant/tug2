#if defined _theateritems_included_
  #endinput
#endif
#define _theateritems_included_

/**
 * Resolves theater item NAMES to the integer IDs the inventory_* console commands take, and back.
 *
 * The problem this exists for: every weapon, upgrade, gear item and explosive in a theater is
 * addressed by an integer at runtime - m_upgradeSlots holds upgrade ids, inventory_buy_weapon takes
 * a weapon id - but nothing exposes the name-to-id mapping to a plugin. The "listtheateritems"
 * console command prints names with no ids at all. That has meant hard-coding numbers that change
 * whenever the theater changes, which is often.
 *
 * This reads the theater's own definition tables, so the mapping is always correct for whatever
 * theater is actually loaded, with nothing to configure.
 *
 * The tables are rebuilt on every map start. Call the natives after TheaterItems_OnReady, or from
 * anything that runs later - they will return 0 / false before the first map has loaded.
 */

enum TheaterCategory
{
    TheaterCategory_Weapon = 0,
    TheaterCategory_Upgrade,
    TheaterCategory_Explosive,
    TheaterCategory_Gear,
    TheaterCategory_Count
};

/**
 * The id for a named item, or 0 if the theater does not define it.
 *
 * Ids start at 1, so 0 is unambiguously "not found" - which is also why a caller can use 0 as a
 * sentinel for "not resolved yet" without colliding with a real item.
 *
 * @param category  Which definition table to look in.
 * @param name      Item name as written in the theater, e.g. "ammo_ap_m107". Case-insensitive.
 * @return          The item's id, or 0.
 */
native int TheaterItem_Find(TheaterCategory category, const char[] name);

/**
 * The name for an id, e.g. to turn an upgrade read out of m_upgradeSlots back into something
 * readable in a log.
 *
 * @param category  Which definition table to look in.
 * @param id        The item's id.
 * @param buffer    Receives the name.
 * @param maxlen    Size of buffer.
 * @return          True if the id exists.
 */
native bool TheaterItem_Name(TheaterCategory category, int id, char[] buffer, int maxlen);

/**
 * How many items the loaded theater defines in a category. Ids are 1..count with no gaps.
 */
native int TheaterItem_Count(TheaterCategory category);

/**
 * Whether the tables have been read for the current map. False means either the map has not
 * finished loading or the read failed - see the server log.
 */
native bool TheaterItem_Ready();

/**
 * Called once per map, after the tables have been read successfully. The natural place to resolve
 * the handful of names a plugin cares about into ids and cache them.
 */
forward void TheaterItems_OnReady();

public SharedPlugin __pl_theateritems =
{
    name      = "gg2_theater_items",
    file      = "gg2_theater_items.smx",
#if defined REQUIRE_PLUGIN
    required  = 1,
#else
    required  = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_theateritems_SetNTVOptional()
{
    MarkNativeAsOptional("TheaterItem_Find");
    MarkNativeAsOptional("TheaterItem_Name");
    MarkNativeAsOptional("TheaterItem_Count");
    MarkNativeAsOptional("TheaterItem_Ready");
}
#endif
