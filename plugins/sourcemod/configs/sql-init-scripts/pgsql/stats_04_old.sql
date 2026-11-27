-- =====================================================
-- Stats v2 (issue #44), part 4: old_* views over this server's old stats tables.
--
-- The old tables stay as they are, in the same schema, and stay the only copy of everything
-- recorded before v2. The v2 views read them only through these pass-through views.
--
-- The old tables store `timestamp without time zone` holding the database's local wall-clock time
-- (filled by CURRENT_TIMESTAMP in the plugins' sessions). Here they become timestamptz, converted
-- with the zone this migration runs in - the same session default the plugins write with. The
-- zone is captured into the view definitions when they are created, so a reader whose session uses
-- another zone (the stats API reads in UTC) still converts correctly.
--
-- Must run after the old schema files and after stats_01_schema.sql. Replaced on every run, so a
-- column added at the end of an old table appears here at the next boot.
-- =====================================================

DO $$
DECLARE
    -- The old tables are in this server's own schema, beside the v2 ones.
    old_schema text := current_schema();
    -- The zone the old plugins' CURRENT_TIMESTAMP was written in. The migrator never sets TimeZone,
    -- so this is the database default, as it is for the plugins.
    zone text := current_setting('TimeZone');
    t text;
    src text;
    cols text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'player_stats', 'player_kills', 'player_shots', 'player_rounds', 'player_round_weapons',
        'weapon_stats', 'bot_kills', 'map_stats', 'win_loss_log', 'maps', 'medics', 'medic_rounds',
        'fire_support', 'fire_support_calls', 'player_tks', 'player_tk_logs'
    ] LOOP
        -- Four old tables gave their names to stats v2 (stats_00_legacy_rename.sql).
        src := CASE WHEN t IN ('maps', 'player_rounds', 'player_round_weapons', 'fire_support_calls')
                    THEN 'legacy_' || t ELSE t END;
        SELECT string_agg(
                   CASE WHEN data_type = 'timestamp without time zone'
                        THEN format('%I AT TIME ZONE %L AS %I', column_name, zone, column_name)
                        ELSE format('%I', column_name) END,
                   ', ' ORDER BY ordinal_position)
          INTO cols
          FROM information_schema.columns
         WHERE table_schema = old_schema AND table_name = src;

        IF cols IS NULL THEN
            RAISE EXCEPTION 'old table %.% not found: run the old stats migrations first', old_schema, src;
        END IF;

        -- CREATE OR REPLACE, never DROP: the v2 views depend on these.
        EXECUTE format('CREATE OR REPLACE VIEW %I AS SELECT %s FROM %I.%I', 'old_' || t, cols, old_schema, src);
    END LOOP;
END $$;
