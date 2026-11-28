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
--
-- quantity is how many TIMES the item was bought, not how many rounds the player ended up holding.
-- Those differ: a grenade with "clip_max_rounds" "-1" stacks into ONE weapon entity whose count
-- lives in reserve ammo, and a single purchase can grant several rounds (weapon_m79_napalm being
-- the obvious case). Storing purchases means the apply path just replays the buy that many times
-- and the theater decides what each one grants - so a theater that changes clip_default does not
-- silently change what a saved loadout restores. 1 for everything that is bought once.
CREATE TABLE IF NOT EXISTS loadout_items (
    loadout_id BIGINT NOT NULL REFERENCES loadouts_slots(id) ON DELETE CASCADE,
    ordinal SMALLINT NOT NULL,
    item_id BIGINT NOT NULL REFERENCES theater_items(id),
    slot SMALLINT,
    parent_ordinal SMALLINT,
    quantity SMALLINT NOT NULL DEFAULT 1,
    PRIMARY KEY (loadout_id, ordinal)
);

-- Added after the table shipped. Existing rows were all single purchases, which is what the default
-- gives them, so no backfill is needed.
ALTER TABLE loadout_items ADD COLUMN IF NOT EXISTS quantity SMALLINT NOT NULL DEFAULT 1;

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
-- One-time imports from older schemas
-- =====================================================
-- Old rows store THEATER IDS, which only mean something against the theater they were saved under,
-- so SQL alone cannot convert them to names - the running server has to say what each id is called.
-- The plugin does that: when this table holds an import that has not completed, it writes the loaded
-- theater's id -> name table into loadouts_import_theater_ids and calls the import function, in one
-- transaction.
--
-- Only these two tables live here, so the plugin's "anything to import?" check works on every
-- server. The request row and the import function itself are in a separate script that only a
-- server with old rows to bring across lists in its database-migrations.cfg - see
-- loadout_saver_slots_import_legacy.sql. Elsewhere this table stays empty and nothing is imported.

CREATE TABLE IF NOT EXISTS loadouts_slots_imports (
    source VARCHAR(64) PRIMARY KEY,
    requested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP,
    sets_imported INTEGER,
    sets_skipped INTEGER,
    items_dropped INTEGER
);

-- Scratch space for the import: the loaded theater's ids, by category (the same numbering as
-- theater_items.category). Emptied by the import when it completes.
CREATE TABLE IF NOT EXISTS loadouts_import_theater_ids (
    category SMALLINT NOT NULL,
    theater_id INTEGER NOT NULL,
    name VARCHAR(64) NOT NULL,
    PRIMARY KEY (category, theater_id)
);

-- =====================================================
-- Comments
-- =====================================================
-- The Discord bot can read the three tables below (discord_bot_grants.sql) and its tests require a
-- COMMENT on each of them and every column, so the description stays with the schema. The import
-- tables and the legacy `loadouts` table are not granted and need none.
--
-- Timestamps are filled by CURRENT_TIMESTAMP into timestamp without time zone, so they hold the
-- database server's local wall-clock time, not UTC.

COMMENT ON TABLE theater_items IS 'Every theater item name this server has saved in a loadout, with a stable local id. Rows are never removed. Join loadout_items.item_id to id.';
COMMENT ON COLUMN theater_items.id IS 'Local surrogate id, referenced by loadout_items.item_id. Not the theater''s own item id.';
COMMENT ON COLUMN theater_items.category IS 'Item kind: 0 weapon (guns, melee and grenades), 1 weapon upgrade (attachment, optic, ammo type), 2 explosive, 3 gear (armor, vest, sling, night vision).';
COMMENT ON COLUMN theater_items.name IS 'Theater item name, e.g. weapon_m4a1, optic_aimpoint, sec_heavy_armor.';
COMMENT ON COLUMN theater_items.first_seen_at IS 'When this server first saved the item (database local time, not UTC).';

COMMENT ON TABLE loadouts_slots IS 'Saved loadouts (LoadoutSaverSlots). A class loadout (name NULL) is one per player per class and is loaded on spawn; a named loadout is saved with !savelo <name> and loadable on any class. Items are in loadout_items.';
COMMENT ON COLUMN loadouts_slots.id IS 'Loadout id, referenced by loadout_items.loadout_id.';
COMMENT ON COLUMN loadouts_slots.steam_id IS 'Owner''s SteamID64.';
COMMENT ON COLUMN loadouts_slots.class_template IS 'Player template (class) it was saved on, e.g. template_rifleman_security_coop.';
COMMENT ON COLUMN loadouts_slots.name IS 'Name given with !savelo <name>, or NULL for the class loadout. Unique per player, case-insensitively.';
COMMENT ON COLUMN loadouts_slots.created_at IS 'First saved (database local time, not UTC).';
COMMENT ON COLUMN loadouts_slots.updated_at IS 'Last saved over (database local time, not UTC).';
COMMENT ON COLUMN loadouts_slots.last_seen_at IS 'Last loaded or touched by the plugin (database local time, not UTC).';
COMMENT ON COLUMN loadouts_slots.update_count IS 'How many times it has been saved.';

COMMENT ON TABLE loadout_items IS 'The items in a saved loadout, one row each, in buy order. Gear and weapons have parent_ordinal NULL; an upgrade points at the ordinal of the weapon it is installed on.';
COMMENT ON COLUMN loadout_items.loadout_id IS 'The loadout (loadouts_slots.id).';
COMMENT ON COLUMN loadout_items.ordinal IS 'Position in buy order, 0..n-1 within the loadout.';
COMMENT ON COLUMN loadout_items.item_id IS 'The item (theater_items.id).';
COMMENT ON COLUMN loadout_items.slot IS 'Weapon slot for weapons: 0 primary, 1 secondary, 2 melee, 3 explosive; higher numbers are theater-defined. NULL for gear and upgrades.';
COMMENT ON COLUMN loadout_items.parent_ordinal IS 'For an upgrade, the ordinal of the weapon it is installed on; NULL otherwise.';
COMMENT ON COLUMN loadout_items.quantity IS 'How many times the item is bought (e.g. several grenades), not rounds held. 1 for most items.';

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
