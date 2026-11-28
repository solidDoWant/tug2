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
    -- Stats v2 (stats_01..03), with every v_* view. The old stats tables are not granted: the v_*
    -- views include their history, one source of truth for the model. The old_* views are plumbing
    -- and never granted either.
    v2 text[] := ARRAY[
        'maps', 'game_modes', 'theaters', 'weapon_types', 'weapons', 'bot_classes', 'items', 'players', 'sessions',
        'name_changes', 'server_builds', 'server_boots', 'map_runs', 'rounds', 'survival_levels',
        'counterattacks', 'player_rounds', 'player_round_weapons', 'player_spans', 'spawns',
        'spawn_items', 'kills', 'hits', 'team_kill_forgives', 'revives', 'revive_helpers', 'heals',
        'heal_holds', 'fire_support_calls', 'objective_events', 'objective_participants'
    ];
    r record;
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'discord-bot') THEN
        RAISE NOTICE 'role discord-bot does not exist; skipping its grants';
        RETURN;
    END IF;
    allowed := allowed || v2;

    EXECUTE format('GRANT USAGE ON SCHEMA %I TO "discord-bot"', current_schema());
    FOR r IN SELECT c.relname, c.relkind FROM pg_class c
             WHERE c.relnamespace = current_schema()::regnamespace AND c.relkind IN ('r', 'v', 'm', 'p') LOOP
        IF r.relname = ANY (allowed) OR (r.relkind = 'v' AND r.relname LIKE 'v\_%') THEN
            EXECUTE format('GRANT SELECT ON %I.%I TO "discord-bot"', current_schema(), r.relname);
        ELSE
            EXECUTE format('REVOKE ALL ON %I.%I FROM "discord-bot"', current_schema(), r.relname);
        END IF;
    END LOOP;
END
$$;
