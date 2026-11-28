-- Read access for the Discord bot (tools/discord-bot), which reads a read replica as the
-- "discord-bot" role: query_stats runs SQL written by an LLM against the stats database, and
-- get_saved_loadouts reads the loadoutsaver database. The role is created by the infra repo; this
-- grants it SELECT on the tables below, in this server's own schema, and revokes it from every
-- other table there.
--
-- One list for every database the bot reads, so there is one place to see what it can read. Each
-- database lists this file last in its own block of database-migrations.cfg ("insurgency-stats"
-- and "loadoutsaver"); a name that is not a table in that database matches nothing.
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
    allowed text[] := ARRAY[
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
        'player_tk_logs',
        'player_drag_mode',
        'player_fy_opt_out',
        'players_smoke_cache',
        'smoke_warning_seen',
        'gg2_messages_rotating_player',
        'gg2_messages_rotating_admin',
        'gg2_messages_join_player',
        -- loadoutsaver database (LoadoutSaverSlots). Not `loadouts`, the legacy table, whose items
        -- are theater ids that only the theater they were saved under can name.
        'loadouts_slots',
        'loadout_items',
        'theater_items'
    ];
    t text;
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'discord-bot') THEN
        RAISE NOTICE 'role discord-bot does not exist; skipping its grants';
        RETURN;
    END IF;

    EXECUTE format('GRANT USAGE ON SCHEMA %I TO "discord-bot"', current_schema());
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = current_schema() LOOP
        IF t = ANY (allowed) THEN
            EXECUTE format('GRANT SELECT ON %I.%I TO "discord-bot"', current_schema(), t);
        ELSE
            EXECUTE format('REVOKE ALL ON %I.%I FROM "discord-bot"', current_schema(), t);
        END IF;
    END LOOP;
END
$$;
