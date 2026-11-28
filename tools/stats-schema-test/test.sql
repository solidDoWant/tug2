-- Seeds old and v2 stats the way the dual-writing plugins would, then checks the v2 views.
-- Run by run.sh as the test server's user. All names are fictional.
--
-- Timeline (database zone America/New_York; old columns hold local wall-clock time):
--   before 2026-11-20  only old lifetime totals ("pre-history")
--   2026-11-20         an old per-round history row
--   2026-11-25 12:00   first v2 map run = the cutover; old and v2 writers both run from here
--   2026-11-25 12:06   the round ends; the old plugins write their history for it too
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------- old data (insurgency-test schema)
INSERT INTO "insurgency-test".weapon_stats (weapon_name) VALUES ('m4a1'), ('ak74');
INSERT INTO "insurgency-test".map_stats (map_name) VALUES ('ministry');

-- Player A's lifetime totals include both history rows below.
INSERT INTO "insurgency-test".player_stats
    (steam_id, name, kills, deaths, suicides, headshot_given, suppressions, caps, killstreak, score,
     wins, losses, play_time_seconds, created_at, updated_at)
VALUES ('76561198000000001', 'Alpha Tester', 100, 10, 1, 20, 40, 5, 12, 500, 6, 3, 4000,
        '2026-01-01 08:00', '2026-11-25 12:10');

INSERT INTO "insurgency-test".player_rounds
    (steam_id, recorded_at, map_name, kills, deaths, suicides, headshot_given, suppressions, caps, score,
     wins, losses, killstreak, play_time_seconds, shots, enemy_hits, friendly_hits)
VALUES ('76561198000000001', '2026-11-20 10:00', 'ministry', 10, 2, 0, 3, 5, 1, 50, 1, 0, 4, 600, 200, 50, 1),
       ('76561198000000001', '2026-11-25 12:06', 'ministry', 3, 1, 0, 1, 2, 0, 20, 1, 0, 3, 300, 40, 10, 0);

INSERT INTO "insurgency-test".player_round_weapons (round_id, weapon_id, kills, shots, enemy_hits, friendly_hits)
SELECT r.id, w.weapon_id, v.k, v.s, v.e, v.f
FROM (VALUES ('2026-11-20 10:00'::timestamp, 10, 200, 50, 1), ('2026-11-25 12:06', 3, 40, 10, 0)) v(t, k, s, e, f)
JOIN "insurgency-test".player_rounds r ON r.recorded_at = v.t
JOIN "insurgency-test".weapon_stats w ON w.weapon_name = 'm4a1';

INSERT INTO "insurgency-test".player_kills (steam_id, weapon_id, kill_count)
SELECT '76561198000000001', weapon_id, 100 FROM "insurgency-test".weapon_stats WHERE weapon_name = 'm4a1';
INSERT INTO "insurgency-test".player_shots (steam_id, weapon_id, shots, enemy_hits, friendly_hits)
SELECT '76561198000000001', weapon_id, 1000, 300, 5 FROM "insurgency-test".weapon_stats WHERE weapon_name = 'm4a1';

INSERT INTO "insurgency-test".medics (steamId, medic_time, heals, revives) VALUES ('76561198000000001', 1000, 10, 4);
INSERT INTO "insurgency-test".medic_rounds (steam_id, recorded_at, medic_time, heals, revives)
VALUES ('76561198000000001', '2026-11-20 10:00', 100, 1, 1), ('76561198000000001', '2026-11-25 12:06', 300, 1, 1);

INSERT INTO "insurgency-test".player_tks (steam_id, tk_given, tk_taken) VALUES (76561198000000001, 3, 0), (76561198000000002, 0, 2);
INSERT INTO "insurgency-test".player_tk_logs (victim_steam_id, attacker_steam_id, weapon, created_at)
VALUES (76561198000000002, 76561198000000001, 'm4a1', '2026-11-20 10:00'),
       (76561198000000002, 76561198000000001, 'm4a1', '2026-11-25 12:04');

INSERT INTO "insurgency-test".fire_support (steamId, arty_thrown) VALUES ('76561198000000001', 5);
INSERT INTO "insurgency-test".fire_support_calls (steam_id, called_at)
VALUES ('76561198000000001', '2026-11-20 10:00'), ('76561198000000001', '2026-11-25 12:02');

INSERT INTO "insurgency-test".bot_kills (bot_name, weapon_id, kill_count, updated_at)
SELECT 'Rifleman Jones', weapon_id, 5, '2026-11-25 12:06' FROM "insurgency-test".weapon_stats WHERE weapon_name = 'ak74';

INSERT INTO "insurgency-test".maps (map_name, play_time, updated_at) VALUES ('ministry', '2 hours', '2026-11-25 12:06');
INSERT INTO "insurgency-test".win_loss_log (map_id, win, created_at)
SELECT map_id, w, t FROM "insurgency-test".map_stats,
       (VALUES (true, '2026-11-19 10:00'::timestamp), (false, '2026-11-20 10:00'), (true, '2026-11-25 12:06')) v(w, t);

-- ---------------------------------------------------------------- v2 data (same schema)
-- The round key, then the same call a second later (a plugin reload): it must find the same round.
SELECT stats_round_id('2026-11-25 11:00:00-05', 'abc123', 'test-0.0.1', '2026-11-25 12:00:00-05', 'ministry',
                      'checkpoint', NULL, 3.5, 1::smallint, '2026-11-25 12:00:00-05') AS round_id \gset
DO $$ BEGIN
    ASSERT (SELECT stats_round_id('2026-11-25 11:00:01-05', 'abc123', 'test-0.0.1', '2026-11-25 12:00:01-05',
            'ministry', 'checkpoint', NULL, 3.5, 1::smallint, '2026-11-25 12:00:01-05'))
           = (SELECT max(round_id) FROM rounds), 'reload must find the same round';
    ASSERT (SELECT count(*) FROM server_boots) = 1 AND (SELECT count(*) FROM map_runs) = 1, 'one boot, one run';
END $$;
UPDATE rounds SET live_at = '2026-11-25 12:00:30-05', ended_at = '2026-11-25 12:06:00-05',
                  winner = 'security', end_reason = 'objective', mvp_steam_id = NULL
WHERE round_id = :round_id;

INSERT INTO players VALUES (76561198000000001), (76561198000000002);
INSERT INTO sessions (steam_id, connected_at, disconnected_at) VALUES
    (76561198000000001, '2026-11-25 11:59-05', '2026-11-25 12:07-05'),
    (76561198000000002, '2026-11-25 11:59-05', NULL);
INSERT INTO name_changes VALUES (76561198000000001, '2026-11-25 11:59-05', '2026-11-25 11:59-05', 'Alpha Renamed');

INSERT INTO player_spans (round_id, steam_id, started_at, ended_at, team, class_template) VALUES
    (:round_id, 76561198000000001, '2026-11-25 12:01-05', '2026-11-25 12:06-05', 'security', 'template_medic_security'),
    (:round_id, 76561198000000002, '2026-11-25 12:00-05', '2026-11-25 12:06-05', 'security', 'template_rifleman_security');

INSERT INTO weapons (weapon_name) VALUES ('m4a1'), ('ak74');
INSERT INTO kills (round_id, killed_at, victim_steam_id, victim_bot_name, victim_team, attacker_steam_id,
                   attacker_bot_name, attacker_team, weapon_name, headshot, domination, revenge, savior,
                   offensive, defensive, damagebits, customkill) VALUES
    (:round_id, '2026-11-25 12:02-05', NULL, 'Rifleman Jones', 'insurgents', 76561198000000001, NULL, 'security', 'm4a1', true, false, false, false, false, false, 2, 0),
    (:round_id, '2026-11-25 12:02:10-05', NULL, 'Rifleman Smith', 'insurgents', 76561198000000001, NULL, 'security', 'm4a1', false, false, false, false, false, false, 2, 0),
    (:round_id, '2026-11-25 12:02:20-05', NULL, 'Rifleman Brown', 'insurgents', 76561198000000001, NULL, 'security', 'm4a1', false, false, false, false, false, false, 2, 0),
    (:round_id, '2026-11-25 12:03-05', 76561198000000001, NULL, 'security', NULL, 'Rifleman Jones', 'insurgents', 'ak74', false, false, false, false, false, false, 2, 0),
    (:round_id, '2026-11-25 12:04-05', 76561198000000002, NULL, 'security', 76561198000000001, NULL, 'security', 'm4a1', false, false, false, false, false, false, 2, 0);

INSERT INTO v2_player_rounds (round_id, steam_id, score, suppressions) VALUES (:round_id, 76561198000000001, 20, 2);
INSERT INTO v2_player_round_weapons (round_id, steam_id, weapon_name, shots, shots_hit_enemy, hits_head)
VALUES (:round_id, 76561198000000001, 'm4a1', 40, 10, 1);
INSERT INTO revives (round_id, started_at, revived_at, reviver_steam_id, revived_steam_id, method)
VALUES (:round_id, '2026-11-25 12:04:10-05', '2026-11-25 12:04:20-05', 76561198000000001, 76561198000000002, 'defib');
INSERT INTO heals (round_id, started_at, ended_at, healer_steam_id, patient_steam_id, hp_healed, to_full)
VALUES (:round_id, '2026-11-25 12:05-05', '2026-11-25 12:05:20-05', 76561198000000001, 76561198000000002, 60, true);
INSERT INTO v2_fire_support_calls (round_id, called_at, steam_id, support_type)
VALUES (:round_id, '2026-11-25 12:02-05', 76561198000000001, 'artillery');

-- ---------------------------------------------------------------- checks
DO $$
DECLARE l record; w record; p record; m record;
BEGIN
    -- Dual writing recorded the same play in both systems, so lifetime must equal the old totals.
    SELECT * INTO l FROM v_player_lifetime WHERE steam_id = 76561198000000001;
    ASSERT l.kills = 100, format('kills %s', l.kills);
    ASSERT l.deaths = 10, format('deaths %s', l.deaths);
    ASSERT l.score = 500, format('score %s', l.score);
    ASSERT l.wins = 6 AND l.losses = 3, format('wins %s losses %s', l.wins, l.losses);
    ASSERT l.play_seconds = 4000, format('play %s', l.play_seconds);
    ASSERT l.headshot_hits = 20, format('headshot hits %s', l.headshot_hits);
    ASSERT l.suppressions = 40, format('suppressions %s', l.suppressions);
    ASSERT l.caps = 5, format('caps %s', l.caps);
    ASSERT l.shots = 1000, format('shots %s', l.shots);
    ASSERT l.medic_seconds = 1000, format('medic %s', l.medic_seconds);
    ASSERT l.heals = 10 AND l.revives = 4, format('heals %s revives %s', l.heals, l.revives);
    ASSERT l.team_kills = 3, format('team kills %s', l.team_kills);
    ASSERT l.fire_support_calls = 5, format('fire support %s', l.fire_support_calls);
    ASSERT l.best_killstreak = 12, format('killstreak %s', l.best_killstreak);
    ASSERT l.headshot_kills = 1 AND l.rounds_played = 1, 'v2-only columns';

    ASSERT (SELECT team_killed FROM v_player_lifetime WHERE steam_id = 76561198000000002) = 2, 'B team killed';

    SELECT * INTO w FROM v_player_weapon_lifetime WHERE steam_id = 76561198000000001 AND weapon_name = 'm4a1';
    ASSERT w.kills = 100 AND w.shots = 1000, format('weapon kills %s shots %s', w.kills, w.shots);

    -- Old local wall-clock times come out as the right instants.
    SELECT * INTO p FROM v_players WHERE steam_id = 76561198000000001;
    ASSERT p.name = 'Alpha Renamed', p.name;
    ASSERT p.first_seen = '2026-01-01 13:00+00', format('first seen %s', p.first_seen);
    ASSERT p.last_seen = '2026-11-25 17:10+00', format('last seen %s', p.last_seen);

    -- Kinds: three enemy kills, one death to a bot, one team kill.
    ASSERT (SELECT count(*) FROM v_kills WHERE kind = 'enemy') = 4, 'enemy kills (3 by A, 1 by a bot)';
    ASSERT (SELECT count(*) FROM v_kills WHERE kind = 'team_kill') = 1, 'team kill';

    -- Bot kills: the old total already holds the v2 kill that happened before its last update.
    ASSERT (SELECT kills FROM v_bot_weapon_kills WHERE bot_name = 'Rifleman Jones' AND weapon_name = 'ak74') = 5,
           'bot kills';

    -- Maps: old pre-cutover rounds plus the v2 round; the dual-written old round is not counted twice.
    SELECT * INTO m FROM v_maps WHERE map_name = 'ministry';
    ASSERT m.rounds = 3 AND m.wins = 2 AND m.losses = 1, format('map rounds %s/%s/%s', m.rounds, m.wins, m.losses);
    ASSERT m.play_seconds = 7200, format('map play %s', m.play_seconds);

    -- Team kill history: one old (before the cutover) and one v2.
    ASSERT (SELECT count(*) FROM v_team_kills) = 2, 'team kill rows';

    -- Windows: the old row after the cutover is excluded, the one before is included.
    ASSERT (SELECT sum(kills) FROM v_player_round_stats WHERE steam_id = 76561198000000001
            AND at >= '2026-11-25 00:00-05') = 3, 'window from the cutover day';
END $$;

-- Constraints reject what they should.
DO $$ BEGIN
    BEGIN
        INSERT INTO kills (round_id, killed_at, victim_steam_id, victim_bot_name, headshot, domination, revenge,
                           savior, offensive, defensive, damagebits, customkill)
        VALUES ((SELECT max(round_id) FROM rounds), now(), 76561198000000001, 'Rifleman Jones', false, false,
                false, false, false, false, 0, 0);
        RAISE EXCEPTION 'two victims accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO v2_player_round_weapons (round_id, steam_id, weapon_name, shots)
        VALUES ((SELECT max(round_id) FROM rounds), 76561198000000001, 'ak74', -1);
        RAISE EXCEPTION 'negative counter accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END $$;

-- The Discord bot shows these descriptions to the model writing SQL: every v2 table, view and
-- column needs one. (old_* views are internal plumbing the bot is never granted; run.sh passes the
-- tables the old schema files made as :old_tables.)
CREATE TEMP TABLE old_tables AS SELECT unnest(string_to_array(:'old_tables', ',')) AS relname;
DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(c.relname || COALESCE('.' || a.attname, ''), ', ') INTO missing
    FROM pg_class c
    LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                            AND col_description(c.oid, a.attnum) IS NULL
    WHERE c.relnamespace = current_schema()::regnamespace AND c.relkind IN ('r', 'v')
      AND c.relname NOT LIKE 'old\_%' AND c.relname NOT IN (SELECT relname FROM old_tables)
      AND (obj_description(c.oid, 'pg_class') IS NULL OR a.attname IS NOT NULL);
    ASSERT missing IS NULL, 'undocumented: ' || missing;
END $$;
