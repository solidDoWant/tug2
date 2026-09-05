-- =====================================================
-- Insurgency Loadout Saver - PostgreSQL Database Schema
-- =====================================================
-- A row is either:
--   * a class loadout  (name IS NULL)     - one per player per class, loaded automatically on
--                                           spawn and by a bare !loadlo
--   * a named loadout  (name IS NOT NULL) - saved with !savelo <name>, loadable on any class.
--                                           class_template records the class it was saved on.
-- Uniqueness differs between the two, so it is enforced by two partial indexes rather than a
-- single primary key: one class loadout per (player, class), one named loadout per (player,
-- name), the latter case-insensitive so "Rifle" and "rifle" cannot both exist.

CREATE TABLE IF NOT EXISTS loadouts (
    steam_id BIGINT NOT NULL,
    class_template VARCHAR(128) NOT NULL,
    name VARCHAR(64),
    gear TEXT,
    primary_weapon TEXT,
    secondary_weapon TEXT,
    explosive TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_count INTEGER DEFAULT 0
);

-- =====================================================
-- Migrations
-- =====================================================

-- Named loadouts. Existing rows get name = NULL, so every loadout saved before this change stays
-- a class loadout and behaves exactly as it did.
ALTER TABLE loadouts ADD COLUMN IF NOT EXISTS name VARCHAR(64);

-- The old primary key was (steam_id, class_template), which cannot hold two named loadouts saved
-- while playing the same class. Replaced by the partial unique indexes below; dropping the
-- constraint also drops the index that backed it.
ALTER TABLE loadouts DROP CONSTRAINT IF EXISTS loadouts_pkey;

-- =====================================================
-- Named Loadout Cap
-- =====================================================

-- The plugin already refuses to insert past the cap, inside the same statement that does the
-- insert. This trigger is the backstop for anything that does not go through the plugin: a bad
-- query, a future plugin change, an admin pasting SQL. Keep the value in step with the plugin's
-- sm_loadout_max_named convar - the trigger is the hard ceiling, so raising the convar above it
-- just moves the failure from a polite chat message to a rejected query.
CREATE OR REPLACE FUNCTION enforce_named_loadout_cap() RETURNS TRIGGER AS $$
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

    -- Replacing a name the player already owns is not a new slot. This matters because a BEFORE
    -- INSERT trigger fires before ON CONFLICT resolves, so an overwrite at the cap would
    -- otherwise be rejected here even though it consumes nothing.
    IF EXISTS (SELECT 1 FROM loadouts
               WHERE steam_id = NEW.steam_id AND name IS NOT NULL
                 AND lower(name) = lower(NEW.name)) THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(*) INTO named_count FROM loadouts
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
DROP TRIGGER IF EXISTS trg_named_loadout_cap ON loadouts;
CREATE TRIGGER trg_named_loadout_cap
    BEFORE INSERT OR UPDATE ON loadouts
    FOR EACH ROW EXECUTE FUNCTION enforce_named_loadout_cap();

-- =====================================================
-- Indexes for Performance
-- =====================================================

-- One class loadout per player per class (what the old primary key enforced).
CREATE UNIQUE INDEX IF NOT EXISTS idx_loadouts_class_unique
    ON loadouts (steam_id, class_template) WHERE name IS NULL;

-- One named loadout per player per name, compared case-insensitively.
CREATE UNIQUE INDEX IF NOT EXISTS idx_loadouts_name_unique
    ON loadouts (steam_id, lower(name)) WHERE name IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_loadouts_steam_id ON loadouts(steam_id);
CREATE INDEX IF NOT EXISTS idx_loadouts_last_seen ON loadouts(last_seen_at);

-- =====================================================
-- Example Data (Semicolon-Separated IDs Format)
-- =====================================================

-- Example loadout entry:
-- INSERT INTO loadouts (steam_id, class_template, gear, primary_weapon, secondary_weapon, explosive) VALUES (
--   76561197960287930,
--   'template_rifleman_security_coop',
--   '39;47',              -- gear IDs
--   '5;12;13;14',         -- primary weapon ID + upgrade IDs
--   '8;15',               -- secondary weapon ID + upgrade IDs
--   '20'                  -- explosive weapon ID + upgrade IDs
-- );

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all loadouts for a player
-- SELECT * FROM loadouts WHERE steam_id = 76561197960287930;

-- View a player's named loadouts, and how close they are to the cap
-- SELECT name, class_template AS saved_on_class, updated_at
-- FROM loadouts WHERE steam_id = 76561197960287930 AND name IS NOT NULL ORDER BY lower(name);

-- Players at or near the named-loadout cap
-- SELECT steam_id, COUNT(*) AS named_loadouts
-- FROM loadouts WHERE name IS NOT NULL
-- GROUP BY steam_id ORDER BY named_loadouts DESC LIMIT 20;

-- Delete old loadouts (not seen in 30 days)
-- DELETE FROM loadouts WHERE last_seen_at < NOW() - INTERVAL '30 days';

-- Count total loadouts per player
-- SELECT steam_id, COUNT(*) as loadout_count 
-- FROM loadouts 
-- GROUP BY steam_id 
-- ORDER BY loadout_count DESC;

-- View most recently updated loadouts
-- SELECT steam_id, class_template, updated_at, update_count
-- FROM loadouts
-- ORDER BY updated_at DESC
-- LIMIT 10;
