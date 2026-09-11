-- =====================================================
-- Insurgency Loadout Saver (all slots) - PostgreSQL Database Schema
-- =====================================================
-- Used by LoadoutSaverSlots.sp.
--
-- WHY ITEMS ARE STORED BY NAME
--
-- Theater item ids are assigned at parse time and move whenever the theater is edited - add one
-- weapon and every id after it shifts. A stored id therefore does not survive a theater change; it
-- keeps resolving, but to a different item, so a loadout silently becomes wrong. Names are stable,
-- and gg2_theater_items turns them back into ids for whatever theater is loaded at the time.
--
-- That also improves the failure mode. An item dropped from the theater resolves to nothing, so the
-- plugin skips it and says so, and if the item ever comes back the loadout works again.
--
-- WHY IT IS NORMALISED
--
-- Not to save space - it does not, meaningfully. Twenty items at ~25 bytes a name is ~500 bytes
-- inline, and a row per item costs about that much again in row headers. The reasons are integrity
-- and queryability: foreign keys instead of a text blob nobody can validate, "which loadouts use
-- this weapon" as a real query, and deletes that cascade instead of leaving orphans.
--
-- theater_items.id is a surrogate and is deliberately NOT the theater's id for the same item. The
-- theater's id is the unstable thing this schema exists to avoid storing.

-- =====================================================
-- Tables
-- =====================================================

-- Every theater item name this server has ever seen, with a stable local id.
-- Rows are never removed: an item dropped from the theater may come back, and a row still referenced
-- by somebody's saved loadout has to stay regardless.
CREATE TABLE IF NOT EXISTS theater_items (
    id BIGSERIAL PRIMARY KEY,
    -- Matches TheaterCategory in theateritems.inc: 0 weapon, 1 upgrade, 2 explosive, 3 gear.
    category SMALLINT NOT NULL,
    name VARCHAR(64) NOT NULL,
    first_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (category, name)
);

-- A saved set. Either a class loadout (name IS NULL, one per player per class, loaded on spawn) or
-- a named loadout (saved with !savelo <name>, loadable on any class; class_template records where
-- it was saved).
CREATE TABLE IF NOT EXISTS loadouts_slots (
    id BIGSERIAL PRIMARY KEY,
    steam_id BIGINT NOT NULL,
    class_template VARCHAR(128) NOT NULL,
    name VARCHAR(64),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_count INTEGER DEFAULT 0
);

-- The items in a set, one row each.
--
-- ordinal is buy order and is load-bearing, not decoration: the apply path buys weapons in this
-- order and reads each weapon's purchase index back afterwards, so two grenades sharing a slot have
-- to go back in the order they were saved. Every read is ORDER BY ordinal.
--
-- parent_ordinal is what the old "slot:def,upg,upg" encoding expressed by nesting: an upgrade row
-- points at the ordinal of the weapon it is installed on. NULL for weapons and gear.
--
-- Sub-slot is deliberately not stored. The buy passes -1 for it, meaning "next free", so position
-- within a slot follows from ordinal alone.
CREATE TABLE IF NOT EXISTS loadout_items (
    loadout_id BIGINT NOT NULL REFERENCES loadouts_slots(id) ON DELETE CASCADE,
    ordinal SMALLINT NOT NULL,
    item_id BIGINT NOT NULL REFERENCES theater_items(id),
    slot SMALLINT,
    parent_ordinal SMALLINT,
    PRIMARY KEY (loadout_id, ordinal)
);

-- =====================================================
-- Indexes
-- =====================================================
-- The two kinds of set have different uniqueness rules, so they are partial indexes rather than one
-- constraint: one class loadout per (player, class), one named loadout per (player, name), the
-- latter case-insensitive so "Rifle" and "rifle" cannot both exist.

CREATE UNIQUE INDEX IF NOT EXISTS idx_loadouts_slots_class_unique
    ON loadouts_slots (steam_id, class_template) WHERE name IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_loadouts_slots_name_unique
    ON loadouts_slots (steam_id, lower(name)) WHERE name IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_loadouts_slots_steam_id ON loadouts_slots(steam_id);
CREATE INDEX IF NOT EXISTS idx_loadouts_slots_last_seen ON loadouts_slots(last_seen_at);

-- For "which loadouts use this item", and to keep the FK check on deletes cheap.
CREATE INDEX IF NOT EXISTS idx_loadout_items_item ON loadout_items(item_id);

-- =====================================================
-- Named Loadout Cap
-- =====================================================
-- Backstop for anything that does not go through the plugin, which enforces the cap in the same
-- statement that inserts. Keep in step with sm_loadout_max_named - the trigger is the hard ceiling,
-- so raising the convar above it just moves the failure from a chat message to a rejected query.

CREATE OR REPLACE FUNCTION enforce_named_loadout_slots_cap() RETURNS TRIGGER AS $$
DECLARE
    cap CONSTANT INTEGER := 15;
    named_count INTEGER;
BEGIN
    IF NEW.name IS NULL THEN
        RETURN NEW;
    END IF;

    -- A row that was already named still occupies the slot it always did.
    IF TG_OP = 'UPDATE' AND OLD.name IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- Replacing a name the player already owns is not a new slot. A BEFORE INSERT trigger fires
    -- before ON CONFLICT resolves, so an overwrite at the cap would otherwise be rejected here.
    IF EXISTS (SELECT 1 FROM loadouts_slots
               WHERE steam_id = NEW.steam_id AND name IS NOT NULL
                 AND lower(name) = lower(NEW.name)) THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(*) INTO named_count FROM loadouts_slots
    WHERE steam_id = NEW.steam_id AND name IS NOT NULL;

    IF named_count >= cap THEN
        RAISE EXCEPTION 'named loadout cap of % reached for steam_id %', cap, NEW.steam_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_named_loadout_slots_cap ON loadouts_slots;
CREATE TRIGGER trg_named_loadout_slots_cap
    BEFORE INSERT OR UPDATE ON loadouts_slots
    FOR EACH ROW EXECUTE FUNCTION enforce_named_loadout_slots_cap();

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- A player's loadouts, reassembled
-- SELECT l.name, l.class_template, li.ordinal, li.slot, li.parent_ordinal, ti.category, ti.name
-- FROM loadouts_slots l
--   LEFT JOIN loadout_items li ON li.loadout_id = l.id
--   LEFT JOIN theater_items ti ON ti.id = li.item_id
-- WHERE l.steam_id = 76561197960287930 ORDER BY l.id, li.ordinal;

-- Which loadouts use a given item - the query the old text column could not answer
-- SELECT l.steam_id, l.name FROM loadout_items li
--   JOIN loadouts_slots l ON l.id = li.loadout_id
--   JOIN theater_items ti ON ti.id = li.item_id
-- WHERE ti.name = 'weapon_M107';

-- Items saved by somebody that the current theater no longer defines. The plugin skips these at
-- load time; this is how you find out which they are.
-- SELECT DISTINCT ti.category, ti.name, COUNT(*) AS saved_by
-- FROM loadout_items li JOIN theater_items ti ON ti.id = li.item_id GROUP BY 1, 2 ORDER BY 3 DESC;

-- Delete old loadouts. loadout_items cascades.
-- DELETE FROM loadouts_slots WHERE last_seen_at < NOW() - INTERVAL '30 days';
