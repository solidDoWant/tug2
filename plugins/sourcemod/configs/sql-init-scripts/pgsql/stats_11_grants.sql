-- =====================================================
-- Stats v2 (issue #44), part 11: read access for the Discord bot's SQL tool (tools/discord-bot).
--
-- The bot may read every v2 table and stats view in this server's stats_* schema. The old_* views are
-- left out: they are plumbing over the old tables, and the stats views already include what they hold.
-- The views run with their owner's rights, so the bot needs no access to the old tables at all. IP
-- addresses are not in this database (player_connections lives in punitive-persistence).
--
-- Runs as the schema's owner on every boot, last, so new tables and views are covered. Skipped if the
-- discord-bot role does not exist (a local or test database).
-- =====================================================

DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM pg_namespace
    WHERE nspname LIKE 'stats\_%' AND nspowner = (SELECT oid FROM pg_roles WHERE rolname = current_user);
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected exactly one stats_* schema owned by %, found %', current_user, n;
    END IF;
    PERFORM set_config('search_path', (SELECT quote_ident(nspname) FROM pg_namespace
        WHERE nspname LIKE 'stats\_%' AND nspowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)), true);
END $$;

DO $$
DECLARE r record;
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'discord-bot') THEN
        RAISE NOTICE 'role discord-bot does not exist; skipping its grants';
        RETURN;
    END IF;
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO "discord-bot"', current_schema());
    FOR r IN
        SELECT c.relname, c.relkind FROM pg_class c
        WHERE c.relnamespace = current_schema()::regnamespace AND c.relkind IN ('r', 'v')
    LOOP
        IF r.relname LIKE 'old\_%' THEN
            EXECUTE format('REVOKE ALL ON %I.%I FROM "discord-bot"', current_schema(), r.relname);
        ELSE
            EXECUTE format('GRANT SELECT ON %I.%I TO "discord-bot"', current_schema(), r.relname);
        END IF;
    END LOOP;
END $$;
