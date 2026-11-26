-- =====================================================
-- Stats v2 (issue #44), part 10: descriptions of the views (see stats_08). Most view columns share a
-- meaning, so they are described once in the map below and applied to every v_* view that has them.
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

COMMENT ON VIEW v_cutover IS 'When v2 recording began on this server (its first map run). Old history is used before it.';
COMMENT ON VIEW v_kills IS 'kills plus each side''s team and the kind of death. Use this, not kills, for counting.';
COMMENT ON VIEW v_killstreaks IS 'Best killstreak per player in v2 data: enemy kills between deaths, carried across rounds.';
COMMENT ON VIEW v_player_round_stats IS 'One row per player per round: the stats over a period come from summing it over at. Old rows (source old, before the cutover) have no round_id and NULL where the old stats had no such number. Old medic, team kill and fire support history are separate rows.';
COMMENT ON VIEW v_player_round_weapon_stats IS 'One row per player per weapon per round; old rows (source old) have no round_id.';
COMMENT ON VIEW v_old_pre_history IS 'Per player, the play recorded before any per-round history existed (old lifetime totals minus old history). Part of v_player_lifetime.';
COMMENT ON VIEW v_player_lifetime IS 'Lifetime totals per player, all time. Use this for leaderboards; K/D = kills / deaths.';
COMMENT ON VIEW v_player_weapon_lifetime IS 'Lifetime totals per player and weapon.';
COMMENT ON VIEW v_players IS 'Every known player with current name and first/last seen.';
COMMENT ON VIEW v_rounds IS 'Every round with its map: v2 rounds plus old results before the cutover (map, end time and winner only).';
COMMENT ON VIEW v_maps IS 'Per map: rounds, results, play time and when last played.';
COMMENT ON VIEW v_team_kills IS 'Every team kill: v2 plus old logged ones before the cutover.';
COMMENT ON VIEW v_bot_weapon_kills IS 'Kills of human players by bots, per bot name and weapon, all time.';

DO $$
DECLARE
    d jsonb := jsonb_build_object(
        'cutover_at', 'Start of v2 recording; infinity if none yet.',
        'round_id', 'rounds.round_id; NULL for old (pre-v2) rows.',
        'steam_id', 'SteamID64 (bigint).',
        'at', 'When the round ended (old rows: when recorded). Filter on this for a period.',
        'source', 'v2, or old for rows from the pre-v2 tables.',
        'kills', 'Kills of enemies.',
        'deaths', 'Deaths, any cause.',
        'suicides', 'Self-inflicted deaths.',
        'world_deaths', 'Deaths with no killer (falls, fire, ...). v2 only.',
        'team_kills', 'Teammates killed.',
        'team_killed', 'Times killed by a teammate.',
        'assists', 'Kill assists. v2 only.',
        'headshot_kills', 'Kills the game flagged as headshots. v2 only.',
        'headshot_hits', 'Hits on enemies'' heads (not kills).',
        'caps', 'Points captured while on the point.',
        'cache_kills', 'Caches destroyed or assisted. v2 only (old caps included caches).',
        'score', 'In-game score.',
        'wins', 'Rounds won by the players with this player on the Security team at the end.',
        'losses', 'Rounds lost by the players with this player on the Security team at the end. Draws count as neither.',
        'rounds_played', 'v2 rounds with any time on the Security team.',
        'play_seconds', 'Seconds on the Security team.',
        'medic_seconds', 'Seconds as a medic.',
        'revives', 'Revives completed.',
        'times_revived', 'Times revived by someone. v2 only.',
        'heals', 'Heals to full health given.',
        'hp_healed', 'Health points healed. v2 only.',
        'fire_support_calls', 'Fire support calls that went ahead.',
        'suppressions', 'Times the player suppressed an enemy.',
        'times_suppressed', 'Times suppressed. v2 only.',
        'shots', 'Rounds fired (or grenades thrown).',
        'shots_hit_enemy', 'Shots that hit an enemy. Accuracy = shots_hit_enemy / shots.',
        'shots_hit_friendly', 'Shots that hit a teammate.',
        'damage_enemy', 'Damage done to enemies. v2 only.',
        'damage_friendly', 'Damage done to teammates. v2 only.',
        'damage_taken', 'Damage taken. v2 only.',
        'best_killstreak', 'Most enemy kills between two deaths (a maximum; never sum it).'
    ) || jsonb_build_object(   -- one call takes at most 100 arguments
        'weapon_name', 'weapons.weapon_name.',
        'hits_head', 'Hits on enemies'' heads, per hit. v2 only.', 'hits_chest', 'Chest hits, per hit. v2 only.',
        'hits_stomach', 'Stomach hits, per hit. v2 only.', 'hits_arms', 'Arm hits, per hit. v2 only.',
        'hits_legs', 'Leg hits, per hit. v2 only.', 'reloads', 'Reloads. v2 only.',
        'deploys', 'Times switched to. v2 only.', 'seconds_drawn', 'Seconds in hand. v2 only.',
        'name', 'Current in-game name.', 'first_seen', 'First seen.', 'last_seen', 'Last seen.',
        'map_run_id', 'map_runs.map_run_id; NULL for old rows.', 'map_name', 'Map name.',
        'game_mode', 'Game mode; NULL for old rows.', 'round_number', 'Round within the map run; NULL for old rows.',
        'started_at', 'Round start; NULL for old rows.', 'live_at', 'When play started; NULL for old rows.',
        'ended_at', 'Round end.', 'winner', 'Winning team (security = the players); NULL for a draw.',
        'end_reason', 'objective, elimination, time_expired or draw; NULL for old rows.',
        'mvp_steam_id', 'Round MVP on the players'' side; NULL for old rows or a bot.',
        'rounds', 'Rounds that ended.', 'last_played_at', 'When last played.',
        'kill_id', 'kills.kill_id; NULL for old rows.', 'killed_at', 'When it happened.',
        'attacker_steam_id', 'Killer.', 'victim_steam_id', 'Victim.', 'forgiven', 'The victim forgave it.',
        'bot_name', 'Bot name (repeats; not one bot).',
        'attacker_team', 'Killer''s team at the time; NULL for world deaths or unknown.',
        'victim_team', 'Victim''s team at the time.',
        'during_live', 'The round was live (not preround or after the end).',
        'kind', 'enemy, team_kill, suicide or world.'
    );
    r record;
BEGIN
    FOR r IN
        SELECT c.relname, a.attname
        FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid
        WHERE c.relnamespace = current_schema()::regnamespace AND c.relkind = 'v'
          AND c.relname LIKE 'v\_%' AND a.attnum > 0 AND NOT a.attisdropped
    LOOP
        IF r.relname = 'v_kills' AND EXISTS (SELECT 1 FROM pg_attribute
                                             WHERE attrelid = 'kills'::regclass AND attname = r.attname) THEN
            -- v_kills repeats the kills columns; reuse their descriptions.
            EXECUTE format('COMMENT ON COLUMN v_kills.%I IS %L', r.attname,
                           col_description('kills'::regclass,
                                           (SELECT attnum FROM pg_attribute WHERE attrelid = 'kills'::regclass AND attname = r.attname)));
        ELSIF d ? r.attname THEN
            EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', r.relname, r.attname, d ->> r.attname);
        END IF;
    END LOOP;
END $$;

-- Where a shared description would mislead.
COMMENT ON COLUMN v_maps.wins IS 'Rounds the players won on this map.';
COMMENT ON COLUMN v_maps.losses IS 'Rounds the players lost on this map.';
COMMENT ON COLUMN v_maps.play_seconds IS 'Seconds played on this map, all time.';
COMMENT ON COLUMN v_bot_weapon_kills.kills IS 'Human players killed by this bot name with this weapon.';
COMMENT ON COLUMN v_team_kills.weapon_name IS 'Weapon used.';
