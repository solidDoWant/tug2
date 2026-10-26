-- =====================================================
-- LoadoutSaverSlots - one-time import of LoadoutSaver's `loadouts` table
-- =====================================================
-- For a server switching from LoadoutSaver to LoadoutSaverSlots, so nobody loses the loadouts they
-- already had. List this AFTER loadout_saver_slots.sql in database-migrations.cfg: it needs that
-- script's tables.
--
-- Only list it on a server whose `loadouts` rows were saved against the theater it runs NOW. The
-- old rows hold theater ids, and the import names them using whatever theater is loaded when it
-- runs - an id saved under a different theater would come back as a different item.
--
-- HOW IT RUNS
--
-- This script only files the request and defines the function. The import itself happens when
-- LoadoutSaverSlots has read the theater: it stages the loaded theater's id -> name table in
-- loadouts_import_theater_ids and calls import_legacy_loadouts(), in one transaction. So a failed
-- import changes nothing and is retried on the next map.
--
-- It runs once. completed_at is set by the import, and the request is filed with ON CONFLICT DO
-- NOTHING, so later runs of this script never re-open it. `loadouts` is only read, never changed, so
-- it stays as a record and a way back to LoadoutSaver.
--
-- WHAT A ROW BECOMES
--
-- `loadouts` stored one row per set, with the items as ";"-separated ids:
--   gear              "gear;gear;..."
--   primary_weapon    "weapon;upgrade;upgrade..."   GetPlayerWeaponSlot(client, 0)
--   secondary_weapon  "weapon;upgrade;upgrade..."   slot 1
--   explosive         "weapon;upgrade;upgrade..."   slot 3
-- Each becomes a loadouts_slots set (same steam_id, class, name and timestamps) with one
-- loadout_items row per item, in the order the plugin itself writes them: gear first, then each
-- weapon followed by its own upgrades. Upgrades point at their weapon through parent_ordinal.
--
-- Ordinals are numbered as items are WRITTEN, not by their position in the old string, so they stay
-- 0..n-1 with no gaps even when something is dropped. ApplyLoadout matches parent_ordinal against a
-- weapon's position in the ORDER BY ordinal result, so a gap would attach upgrades to the wrong
-- weapon.
--
-- An id the theater does not define is dropped and counted. A weapon that is dropped takes its
-- upgrades with it, since they have nothing to attach to.
--
-- CONFLICTS
--
-- The plugin is running before and during the import, so a player may already have saved over a
-- class, or used a name, in the new table. Their newer set wins and the old one is skipped. A named
-- set is also skipped if the player is already at the named-loadout cap, because the cap trigger
-- would otherwise abort the whole import on one player.

INSERT INTO loadouts_slots_imports (source) VALUES ('loadouts') ON CONFLICT (source) DO NOTHING;

CREATE OR REPLACE FUNCTION import_legacy_loadouts() RETURNS INTEGER AS $$
DECLARE
    cap CONSTANT INTEGER := 15;    -- keep in step with enforce_named_loadout_slots_cap
    request RECORD;
    legacy RECORD;
    weapon_column RECORD;
    set_id BIGINT;
    next_ordinal INTEGER;
    weapon_ordinal INTEGER;
    tokens TEXT[];
    token TEXT;
    pos INTEGER;
    item BIGINT;
    imported INTEGER := 0;
    skipped INTEGER := 0;
    dropped INTEGER := 0;
BEGIN
    -- Locked so two callers cannot both import. The second waits, then sees completed_at.
    SELECT * INTO request FROM loadouts_slots_imports WHERE source = 'loadouts' FOR UPDATE;
    IF NOT FOUND OR request.completed_at IS NOT NULL THEN
        RETURN 0;
    END IF;

    -- A database that never ran LoadoutSaver has nothing to import.
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = current_schema() AND table_name = 'loadouts') THEN
        UPDATE loadouts_slots_imports
        SET completed_at = CURRENT_TIMESTAMP, sets_imported = 0, sets_skipped = 0, items_dropped = 0
        WHERE source = 'loadouts';
        RETURN 0;
    END IF;

    -- Without the theater table every id would be dropped, and the import would complete having
    -- destroyed nothing but brought nothing across either. Refuse instead, so it is retried.
    IF NOT EXISTS (SELECT 1 FROM loadouts_import_theater_ids) THEN
        RAISE EXCEPTION 'import_legacy_loadouts: loadouts_import_theater_ids is empty - the plugin stages it before calling';
    END IF;

    FOR legacy IN
        SELECT * FROM loadouts ORDER BY steam_id, created_at, class_template, name
    LOOP
        set_id := NULL;

        IF legacy.name IS NULL THEN
            INSERT INTO loadouts_slots
                (steam_id, class_template, name, created_at, updated_at, last_seen_at, update_count)
            VALUES
                (legacy.steam_id, legacy.class_template, NULL, legacy.created_at, legacy.updated_at,
                 legacy.last_seen_at, coalesce(legacy.update_count, 0))
            ON CONFLICT (steam_id, class_template) WHERE name IS NULL DO NOTHING
            RETURNING id INTO set_id;
        ELSIF (SELECT COUNT(*) FROM loadouts_slots
               WHERE steam_id = legacy.steam_id AND name IS NOT NULL) < cap THEN
            INSERT INTO loadouts_slots
                (steam_id, class_template, name, created_at, updated_at, last_seen_at, update_count)
            VALUES
                (legacy.steam_id, legacy.class_template, legacy.name, legacy.created_at, legacy.updated_at,
                 legacy.last_seen_at, coalesce(legacy.update_count, 0))
            ON CONFLICT (steam_id, lower(name)) WHERE name IS NOT NULL DO NOTHING
            RETURNING id INTO set_id;
        END IF;

        IF set_id IS NULL THEN
            skipped := skipped + 1;
            CONTINUE;
        END IF;

        next_ordinal := 0;

        -- Gear first, as the plugin saves it: gear is applied before weapons because weapon slot
        -- capacity comes from the gear being worn.
        FOREACH token IN ARRAY coalesce(string_to_array(legacy.gear, ';'), ARRAY[]::TEXT[])
        LOOP
            CONTINUE WHEN token !~ '^[0-9]+$';
            item := legacy_loadout_item(3, token::INTEGER);
            IF item IS NULL THEN
                dropped := dropped + 1;
                CONTINUE;
            END IF;
            INSERT INTO loadout_items (loadout_id, ordinal, item_id, slot, parent_ordinal, quantity)
            VALUES (set_id, next_ordinal, item, NULL, NULL, 1);
            next_ordinal := next_ordinal + 1;
        END LOOP;

        -- Then each weapon followed by its upgrades, primary, secondary, explosive - the order the
        -- legacy plugin bought them in.
        FOR weapon_column IN
            SELECT * FROM (VALUES (1, legacy.primary_weapon, 0), (2, legacy.secondary_weapon, 1), (3, legacy.explosive, 3))
                AS c(n, contents, slot)
            ORDER BY n
        LOOP
            tokens := array_remove(coalesce(string_to_array(weapon_column.contents, ';'), ARRAY[]::TEXT[]), '');
            CONTINUE WHEN cardinality(tokens) = 0;

            item := NULL;
            IF tokens[1] ~ '^[0-9]+$' THEN
                item := legacy_loadout_item(0, tokens[1]::INTEGER);
            END IF;
            IF item IS NULL THEN
                dropped := dropped + cardinality(tokens);
                CONTINUE;
            END IF;

            weapon_ordinal := next_ordinal;
            INSERT INTO loadout_items (loadout_id, ordinal, item_id, slot, parent_ordinal, quantity)
            VALUES (set_id, next_ordinal, item, weapon_column.slot, NULL, 1);
            next_ordinal := next_ordinal + 1;

            FOR pos IN 2 .. cardinality(tokens)
            LOOP
                item := NULL;
                IF tokens[pos] ~ '^[0-9]+$' THEN
                    item := legacy_loadout_item(1, tokens[pos]::INTEGER);
                END IF;
                IF item IS NULL THEN
                    dropped := dropped + 1;
                    CONTINUE;
                END IF;
                INSERT INTO loadout_items (loadout_id, ordinal, item_id, slot, parent_ordinal, quantity)
                VALUES (set_id, next_ordinal, item, NULL, weapon_ordinal, 1);
                next_ordinal := next_ordinal + 1;
            END LOOP;
        END LOOP;

        imported := imported + 1;
    END LOOP;

    UPDATE loadouts_slots_imports
    SET completed_at = CURRENT_TIMESTAMP, sets_imported = imported, sets_skipped = skipped,
        items_dropped = dropped
    WHERE source = 'loadouts';

    DELETE FROM loadouts_import_theater_ids;

    RAISE NOTICE 'import_legacy_loadouts: % set(s) imported, % skipped, % item(s) dropped',
        imported, skipped, dropped;
    RETURN imported;
END;
$$ LANGUAGE plpgsql;

-- The theater_items row for a staged theater id, created if this server has never recorded that
-- name. NULL when the loaded theater does not define the id.
CREATE OR REPLACE FUNCTION legacy_loadout_item(item_category INTEGER, item_theater_id INTEGER)
RETURNS BIGINT AS $$
DECLARE
    item_name VARCHAR(64);
    item BIGINT;
BEGIN
    SELECT s.name INTO item_name FROM loadouts_import_theater_ids s
    WHERE s.category = item_category AND s.theater_id = item_theater_id;
    IF item_name IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO theater_items (category, name) VALUES (item_category, item_name)
    ON CONFLICT (category, name) DO NOTHING;

    SELECT t.id INTO item FROM theater_items t
    WHERE t.category = item_category AND t.name = item_name;
    RETURN item;
END;
$$ LANGUAGE plpgsql;

-- What the import did
-- SELECT * FROM loadouts_slots_imports;

-- Re-run it from scratch - only after deleting what it imported, or every set conflicts and is skipped
-- UPDATE loadouts_slots_imports SET completed_at = NULL WHERE source = 'loadouts';
