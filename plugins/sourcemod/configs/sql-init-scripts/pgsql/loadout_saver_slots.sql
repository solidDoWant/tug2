-- =====================================================
-- Insurgency Loadout Saver (all slots) - PostgreSQL Database Schema
-- =====================================================
-- Used by LoadoutSaverSlots.sp. A separate table from `loadouts`, not a migration of it: the two
-- plugins register the same commands and never run together, but the servers do run different
-- ones, so the original table has to keep working untouched for whichever server still uses it.
-- That also makes rolling back free - swap the plugin, the old rows are exactly as they were.
--
-- A row is either:
--   * a class loadout  (name IS NULL)     - one per player per class, loaded automatically on
--                                           spawn and by a bare !loadlo
--   * a named loadout  (name IS NOT NULL) - saved with !savelo <name>, loadable on any class.
--                                           class_template records the class it was saved on.
--
-- WHAT CHANGED FROM `loadouts`
--
-- The four fixed item columns (gear, primary_weapon, secondary_weapon, explosive) could only ever
-- hold three weapons, in three hardcoded slots. They are replaced by a single `weapons` column
-- that names the slot of every item it stores, so a theater can invent as many slots as it likes
-- and a player can carry two things in one bucket.
--
-- FORMAT
--
--   gear      "id;id;id"                          - gear definition indices, one per equipped slot
--   weapons   "slot:def,upg,upg;slot:def,upg"     - ";" between items, "," within one item
--
-- The first field of an item is its slot, the second its weapon definition index, and the rest are
-- that weapon's upgrades. Items are stored in ascending slot order, which is what makes a stock
-- loadout come back as primary, secondary, explosive - the order the game is used to.
--
--   '0:5,12,13;1:8,15;3:20'   primary with two upgrades, secondary with one, an explosive
--   '0:5;3:20;3:21'           two items sharing slot 3, which the old schema could not express

CREATE TABLE IF NOT EXISTS loadouts_slots (
    steam_id BIGINT NOT NULL,
    class_template VARCHAR(128) NOT NULL,
    name VARCHAR(64),
    gear TEXT,
    weapons TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_count INTEGER DEFAULT 0
);

-- =====================================================
-- Indexes
-- =====================================================
-- Uniqueness differs between the two kinds of row, so it is enforced by two partial indexes rather
-- than a single primary key - the same shape `loadouts` ended up with.

-- One class loadout per player per class.
CREATE UNIQUE INDEX IF NOT EXISTS idx_loadouts_slots_class_unique
    ON loadouts_slots (steam_id, class_template) WHERE name IS NULL;

-- One named loadout per player per name, compared case-insensitively so "Rifle" and "rifle" cannot
-- both exist.
CREATE UNIQUE INDEX IF NOT EXISTS idx_loadouts_slots_name_unique
    ON loadouts_slots (steam_id, lower(name)) WHERE name IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_loadouts_slots_steam_id ON loadouts_slots(steam_id);
CREATE INDEX IF NOT EXISTS idx_loadouts_slots_last_seen ON loadouts_slots(last_seen_at);

-- =====================================================
-- Named Loadout Cap
-- =====================================================
-- Backstop for anything that does not go through the plugin, which enforces the cap inside the
-- same statement that does the insert. Keep the value in step with sm_loadout_max_named - the
-- trigger is the hard ceiling, so raising the convar above it just moves the failure from a polite
-- chat message to a rejected query.

CREATE OR REPLACE FUNCTION enforce_named_loadout_slots_cap() RETURNS TRIGGER AS $$
DECLARE
    cap CONSTANT INTEGER := 15;
    named_count INTEGER;
BEGIN
    -- Class loadouts are unlimited and never counted.
    IF NEW.name IS NULL THEN
        RETURN NEW;
    END IF;

    -- A row that was already named still occupies the slot it always did, whatever else is being
    -- changed about it. This is the common case: every save overwrite, and the last_seen_at touch
    -- that runs for all of a player's rows when they connect.
    IF TG_OP = 'UPDATE' AND OLD.name IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- Replacing a name the player already owns is not a new slot. A BEFORE INSERT trigger fires
    -- before ON CONFLICT resolves, so an overwrite at the cap would otherwise be rejected here even
    -- though it consumes nothing.
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

-- Also covers UPDATE, so a row cannot be turned from a class loadout into a named one past the
-- cap. DROP + CREATE rather than CREATE OR REPLACE TRIGGER, which needs PostgreSQL 14+.
DROP TRIGGER IF EXISTS trg_named_loadout_slots_cap ON loadouts_slots;
CREATE TRIGGER trg_named_loadout_slots_cap
    BEFORE INSERT OR UPDATE ON loadouts_slots
    FOR EACH ROW EXECUTE FUNCTION enforce_named_loadout_slots_cap();

-- =====================================================
-- One-time import from `loadouts`
-- =====================================================
-- So nobody loses the loadouts they already had when a server switches plugins. Every old row
-- converts exactly: its three item columns were, by definition, slots 0, 1 and 3, and its ";"
-- separator within an item becomes ",".
--
-- Runs only while loadouts_slots is empty. That makes it a genuine one-shot rather than something
-- that resurrects rows a player has since deleted, and it is why this is a DO block instead of an
-- INSERT ... ON CONFLICT DO NOTHING. The guard on the source table keeps a fresh database, where
-- `loadouts` has never existed, from erroring.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = current_schema() AND table_name = 'loadouts') THEN
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM loadouts_slots) THEN
        RETURN;
    END IF;

    INSERT INTO loadouts_slots
        (steam_id, class_template, name, gear, weapons, created_at, updated_at, last_seen_at, update_count)
    SELECT
        steam_id, class_template, name, gear,
        -- concat_ws drops NULL arms, so a loadout with no secondary produces "0:...;3:..." rather
        -- than an empty field in the middle.
        nullif(concat_ws(';',
            CASE WHEN coalesce(primary_weapon,   '') <> '' THEN '0:' || replace(primary_weapon,   ';', ',') END,
            CASE WHEN coalesce(secondary_weapon, '') <> '' THEN '1:' || replace(secondary_weapon, ';', ',') END,
            CASE WHEN coalesce(explosive,        '') <> '' THEN '3:' || replace(explosive,        ';', ',') END
        ), ''),
        created_at, updated_at, last_seen_at, update_count
    FROM loadouts;

    RAISE NOTICE 'loadouts_slots: imported % row(s) from loadouts', (SELECT COUNT(*) FROM loadouts_slots);
END $$;

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all loadouts for a player
-- SELECT * FROM loadouts_slots WHERE steam_id = 76561197960287930;

-- A player's named loadouts, and how close they are to the cap
-- SELECT name, class_template AS saved_on_class, weapons, updated_at
-- FROM loadouts_slots WHERE steam_id = 76561197960287930 AND name IS NOT NULL ORDER BY lower(name);

-- Loadouts that use a slot the old plugin could not store (anything outside 0, 1 and 3)
-- SELECT steam_id, class_template, name, weapons FROM loadouts_slots
-- WHERE weapons ~ '(^|;)(?!0:|1:|3:)[0-9]+:';

-- Delete old loadouts (not seen in 30 days)
-- DELETE FROM loadouts_slots WHERE last_seen_at < NOW() - INTERVAL '30 days';
