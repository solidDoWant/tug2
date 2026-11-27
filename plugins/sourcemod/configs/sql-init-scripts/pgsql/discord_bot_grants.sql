-- Read access for the Discord bot's query_stats tool (tools/discord-bot), which runs SQL written
-- by an LLM against a read replica as the "discord-bot" role. The role is created by the infra
-- repo; this grants it SELECT on the tables (and stats v2 views) below, in this server's own
-- schema, and revokes it from every other table and view there.
--
-- Only list tables with nothing private in them. Never add connection_log: it holds players' IP
-- addresses. The bot describes the tables it can read to the model from their COMMENTs, so give a
-- table added here a COMMENT on it and on every column, in the plugin script that creates it.
-- tools/discord-bot tests check both (TestGrantedTablesHaveComments, TestSchemaFromMigrations).
--
-- Runs as the table owner on every plugin load (DatabaseMigrator), so a new or re-created table
-- is granted in the rollout that creates it. Kept in its own migration so a failure here can't
-- roll back any table creation. A role or table that doesn't exist yet is skipped.
DO $$
DECLARE
    -- Not stats: granted on every server.
    allowed text[] := ARRAY[
        'player_drag_mode',
        'player_fy_opt_out',
        'players_smoke_cache',
        'smoke_warning_seen',
        'gg2_messages_rotating_player',
        'gg2_messages_rotating_admin',
        'gg2_messages_join_player'
    ];
    -- The old stats tables: granted until stats v2 (issue #44) is recorded on this server.
    old_stats text[] := ARRAY[
        'player_stats',
        'player_kills',
        'player_shots',
        'player_rounds',
        'player_round_weapons',
        'weapon_stats',
        'bot_kills',
        'map_stats',
        'win_loss_log',
        'maps',
        'medics',
        'medic_rounds',
        'fire_support',
        'fire_support_calls',
        'player_tks',
        'player_tk_logs'
    ];
    -- Stats v2 (stats_01..03): granted, with every v_* view, once its tables exist here. The v_*
    -- views already include the old tables' history, so those are then revoked: one source of
    -- truth for the model. The old_* views are plumbing and never granted.
    v2 text[] := ARRAY[
        'v2_maps', 'game_modes', 'theaters', 'weapon_types', 'weapons', 'bot_classes', 'items', 'players', 'sessions',
        'name_changes', 'server_builds', 'server_boots', 'map_runs', 'rounds', 'survival_levels',
        'counterattacks', 'v2_player_rounds', 'v2_player_round_weapons', 'player_spans', 'spawns',
        'spawn_items', 'kills', 'team_kill_forgives', 'revives', 'revive_helpers', 'heals',
        'heal_holds', 'v2_fire_support_calls', 'objective_events', 'objective_participants'
    ];
    have_v2 boolean := to_regproc('stats_round_id') IS NOT NULL;
    r record;
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'discord-bot') THEN
        RAISE NOTICE 'role discord-bot does not exist; skipping its grants';
        RETURN;
    END IF;
    allowed := allowed || CASE WHEN have_v2 THEN v2 ELSE old_stats END;

    EXECUTE format('GRANT USAGE ON SCHEMA %I TO "discord-bot"', current_schema());
    FOR r IN SELECT c.relname, c.relkind FROM pg_class c
             WHERE c.relnamespace = current_schema()::regnamespace AND c.relkind IN ('r', 'v', 'm', 'p') LOOP
        IF r.relname = ANY (allowed) OR (have_v2 AND r.relkind = 'v' AND r.relname LIKE 'v\_%') THEN
            EXECUTE format('GRANT SELECT ON %I.%I TO "discord-bot"', current_schema(), r.relname);
        ELSE
            EXECUTE format('REVOKE ALL ON %I.%I FROM "discord-bot"', current_schema(), r.relname);
        END IF;
    END LOOP;
END
$$;
