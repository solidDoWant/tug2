-- The per-round results cache (stats_03_results.sql). Run by run.sh after test.sql and plugin_sql.sql.
-- Adds rounds with random kills and deaths across map runs, then checks that:
--   - killstreaks built from per-round results equal the plain definition over every kill,
--   - caching every round changes no view's output,
--   - every cached row equals the live computation of its round.
-- All names are fictional.
\set ON_ERROR_STOP on
SELECT setseed(0.44);

-- Six rounds over two map runs, three players on security for the whole of each.
INSERT INTO players VALUES (76561198000000021), (76561198000000022), (76561198000000023) ON CONFLICT DO NOTHING;
INSERT INTO weapons VALUES ('m4a1') ON CONFLICT DO NOTHING;
CREATE TEMP TABLE sr AS
SELECT n, stats_round_id('2026-11-26 10:00:00-05', 'abc123', 'test-0.0.1',
                         CASE WHEN n <= 3 THEN '2026-11-26 10:05:00-05' ELSE '2026-11-26 11:05:00-05' END::timestamptz,
                         'sinjar', 'checkpoint', NULL, 3.5, ((n - 1) % 3 + 1)::smallint,
                         '2026-11-26 10:05:00-05'::timestamptz + (n - 1) * interval '20 minutes') AS round_id,
       '2026-11-26 10:05:00-05'::timestamptz + (n - 1) * interval '20 minutes' AS t0
FROM generate_series(1, 6) n;
UPDATE rounds r SET live_at = sr.t0, ended_at = sr.t0 + interval '15 minutes', winner = 'security', end_reason = 'objective'
FROM sr WHERE r.round_id = sr.round_id;
INSERT INTO player_spans (round_id, steam_id, started_at, ended_at, team, class_template)
SELECT sr.round_id, p.steam_id, sr.t0, sr.t0 + interval '15 minutes', 'security', 'template_rifleman_security'
FROM sr, (VALUES (76561198000000021), (76561198000000022), (76561198000000023)) p(steam_id);

-- Each player: 0-40 events per round at whole seconds (so kills and deaths sometimes share an
-- instant), each an enemy kill (70%), a death to a bot, a suicide or a team kill by another player.
INSERT INTO kills (round_id, killed_at, victim_steam_id, victim_bot_name, victim_team, attacker_steam_id,
                   attacker_bot_name, attacker_team, weapon_name, headshot, domination, revenge, savior,
                   offensive, defensive, damagebits, customkill)
SELECT e.round_id, e.t,
       CASE WHEN e.r < 0.7 THEN NULL ELSE e.steam_id END,
       CASE WHEN e.r < 0.7 THEN 'Bot ' || (e.i % 7) END, CASE WHEN e.r < 0.7 THEN 'insurgents' ELSE 'security' END::team,
       CASE WHEN e.r < 0.7 THEN e.steam_id WHEN e.r < 0.8 THEN e.steam_id
            WHEN e.r < 0.85 THEN 76561198000000021 + (e.steam_id - 76561198000000020) % 3 END,
       CASE WHEN e.r >= 0.85 THEN 'Bot ' || (e.i % 7) END, CASE WHEN e.r >= 0.85 THEN 'insurgents' ELSE 'security' END::team,
       'm4a1', e.r < 0.2, false, false, false, false, false, 2, 0
FROM (SELECT sr.round_id, p.steam_id, g.i, random() AS r,
             sr.t0 + (floor(random() * 600) || ' seconds')::interval AS t
      FROM sr, (VALUES (76561198000000021), (76561198000000022), (76561198000000023)) p(steam_id),
           LATERAL generate_series(1, (random() * 40)::int) g(i)) e;

-- The plain definition: enemy kills between two deaths, over every kill in time order.
CREATE TEMP VIEW ref_killstreaks AS
WITH ev AS (
    SELECT attacker_steam_id AS steam_id, killed_at AS t, 1 AS is_kill
    FROM v_kills WHERE kind = 'enemy' AND attacker_steam_id IS NOT NULL
    UNION ALL
    SELECT victim_steam_id, killed_at, 0 FROM kills WHERE victim_steam_id IS NOT NULL
), g AS (
    SELECT steam_id, is_kill,
           sum(1 - is_kill) OVER (PARTITION BY steam_id ORDER BY t, is_kill DESC ROWS UNBOUNDED PRECEDING) AS life
    FROM ev
)
SELECT steam_id, max(n)::int AS best_killstreak
FROM (SELECT steam_id, life, sum(is_kill) AS n FROM g GROUP BY steam_id, life) x
GROUP BY steam_id;

CREATE TEMP TABLE snap (v text, row text);
CREATE FUNCTION pg_temp.take(p_tag text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
    FOREACH v IN ARRAY ARRAY['v_player_round_stats', 'v_player_round_weapon_stats', 'v_player_lifetime',
                             'v_player_weapon_lifetime', 'v_killstreaks'] LOOP
        EXECUTE format('INSERT INTO snap SELECT %L, t::text FROM %I t', p_tag || ':' || v, v);
    END LOOP;
END $$;

DO $$
DECLARE bad text;
BEGIN
    ASSERT (SELECT count(*) FROM kills WHERE round_id IN (SELECT round_id FROM sr)) > 100, 'random kills made';
    SELECT string_agg(format('%s: %s vs %s', steam_id, a, b), '; ') INTO bad
    FROM (SELECT steam_id, k.best_killstreak a, r.best_killstreak b
          FROM v_killstreaks k FULL JOIN ref_killstreaks r USING (steam_id)) x
    WHERE a IS DISTINCT FROM b;
    ASSERT bad IS NULL, 'killstreaks (live) differ from the plain definition: ' || bad;
END $$;

-- Everything live, then everything cached.
SELECT pg_temp.take('live');
SELECT count(stats_refresh_round(round_id)) FROM rounds;
SELECT pg_temp.take('cached');

DO $$
DECLARE n bigint; bad text;
BEGIN
    ASSERT (SELECT count(*) FROM round_results_done) = (SELECT count(*) FROM rounds), 'every round cached';
    ASSERT (SELECT count(*) FROM player_round_results) > 0, 'cached rows';
    SELECT count(*) INTO n FROM (
        (SELECT split_part(v, ':', 2), row FROM snap WHERE v LIKE 'live:%'
         EXCEPT ALL SELECT split_part(v, ':', 2), row FROM snap WHERE v LIKE 'cached:%')
        UNION ALL
        (SELECT split_part(v, ':', 2), row FROM snap WHERE v LIKE 'cached:%'
         EXCEPT ALL SELECT split_part(v, ':', 2), row FROM snap WHERE v LIKE 'live:%')) d;
    ASSERT n = 0, format('%s view rows changed when the rounds were cached', n);
    SELECT count(*) INTO n FROM (
        (TABLE player_round_results EXCEPT ALL SELECT * FROM stats_round_results(ARRAY(SELECT round_id FROM rounds)))
        UNION ALL
        (SELECT * FROM stats_round_results(ARRAY(SELECT round_id FROM rounds)) EXCEPT ALL TABLE player_round_results)) d;
    ASSERT n = 0, format('%s cached rows differ from the live computation', n);
    SELECT count(*) INTO n FROM (
        (TABLE player_round_weapon_results EXCEPT ALL SELECT * FROM stats_round_weapon_results(ARRAY(SELECT round_id FROM rounds)))
        UNION ALL
        (SELECT * FROM stats_round_weapon_results(ARRAY(SELECT round_id FROM rounds)) EXCEPT ALL TABLE player_round_weapon_results)) d;
    ASSERT n = 0, format('%s cached weapon rows differ from the live computation', n);
    SELECT string_agg(format('%s: %s vs %s', steam_id, a, b), '; ') INTO bad
    FROM (SELECT steam_id, k.best_killstreak a, r.best_killstreak b
          FROM v_killstreaks k FULL JOIN ref_killstreaks r USING (steam_id)) x
    WHERE a IS DISTINCT FROM b;
    ASSERT bad IS NULL, 'killstreaks (cached) differ from the plain definition: ' || bad;
END $$;

-- A cached round that gains rows is out of date until refreshed; a refresh brings it back in line.
INSERT INTO kills (round_id, killed_at, victim_bot_name, victim_team, attacker_steam_id, attacker_team, weapon_name, headshot,
                   domination, revenge, savior, offensive, defensive, damagebits, customkill)
SELECT round_id, t0 + interval '1 minute', 'Bot 9', 'insurgents', 76561198000000021, 'security', 'm4a1', false,
       false, false, false, false, false, 2, 0 FROM sr WHERE n = 2;
SELECT stats_refresh_round(round_id) FROM sr WHERE n = 2;
DO $$ BEGIN
    ASSERT (SELECT count(*) FROM (
        (TABLE player_round_results EXCEPT ALL SELECT * FROM stats_round_results(ARRAY(SELECT round_id FROM rounds)))
        UNION ALL
        (SELECT * FROM stats_round_results(ARRAY(SELECT round_id FROM rounds)) EXCEPT ALL TABLE player_round_results)) d) = 0,
        'a refreshed round matches the live computation';
END $$;

-- Mark two rounds as computed by an older definition: the next boot (run.sh re-applies
-- stats_03_results.sql) must recompute them.
UPDATE round_results_done SET def_hash = 'old' WHERE round_id IN (SELECT round_id FROM sr WHERE n IN (1, 4));
