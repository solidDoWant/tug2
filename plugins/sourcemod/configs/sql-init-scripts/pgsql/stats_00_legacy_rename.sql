-- =====================================================
-- Stats v2 (issue #44), part 0 (phase 4): the v2 tables take their final names.
--
-- While the old stats plugins still wrote, four v2 tables carried a v2_ prefix because the old ones
-- had the names. With the old writers retired, the old tables become legacy_* (still read through
-- the old_* views, stats_04_old.sql) and the v2 ones drop the prefix. Views, foreign keys and
-- indexes follow a renamed table, so nothing else changes; index and constraint names keep their
-- old spelling.
--
-- Runs first, before the old schema files (which now create the legacy_* names) and the stats_*
-- files (which use the final names). A no-op once done, and on a new database.
-- =====================================================

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['maps', 'player_rounds', 'player_round_weapons', 'fire_support_calls'] LOOP
        IF to_regclass(quote_ident('v2_' || t)) IS NOT NULL THEN
            IF to_regclass(quote_ident(t)) IS NOT NULL THEN
                EXECUTE format('ALTER TABLE %I RENAME TO %I', t, 'legacy_' || t);
            END IF;
            EXECUTE format('ALTER TABLE %I RENAME TO %I', 'v2_' || t, t);
        END IF;
    END LOOP;
END $$;
