-- =====================================================
-- Stats v2 (issue #44), part 12 (phase 4): the old stats tables become read-only.
--
-- Their writers (gg2_mstats2, gg2_medic_tracker, map_logger, gg2_connection_tracker, and the stats
-- parts of FireSupport and gg2_teamkill) are retired; gg2_stats2 records everything into the stats_*
-- schema. The old tables stay: they are the only copy of everything recorded before stats v2, and the
-- v2 views read them (stats_04_old.sql). Taking write access away from their owner means nothing can
-- add to them by mistake, while SELECT (for the views) and the old schema files' idempotent DDL keep
-- working. connection_log (IP addresses) is locked too; it is dropped by hand once its rows are in
-- punitive-persistence (retire_connection_log.sql).
--
-- Runs in the old schema: the user's own if it has one, else public (where the old plugins wrote).
-- =====================================================

DO $$
DECLARE
    old_schema text := CASE WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = current_user)
                            THEN current_user ELSE 'public' END;
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'player_stats', 'player_kills', 'player_shots', 'player_rounds', 'player_round_weapons',
        'weapon_stats', 'bot_kills', 'map_stats', 'win_loss_log', 'maps', 'medics', 'medic_rounds',
        'fire_support', 'fire_support_calls', 'player_tks', 'player_tk_logs', 'connection_log'
    ] LOOP
        IF to_regclass(format('%I.%I', old_schema, t)) IS NOT NULL THEN
            EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON %I.%I FROM %I', old_schema, t, current_user);
        END IF;
    END LOOP;
END $$;
