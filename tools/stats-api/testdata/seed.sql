-- Dummy data for local testing of stats-api and its integration test: old (pre-v2) stats the way
-- the old plugins wrote them, then stats v2 rows the way gg2_stats2 writes them. Applied once, by
-- testdata/init-db.sh, after the schema. All names are fictional.
--
-- Timeline (UTC):
--   2025-12-10         an old logged team kill
--   2026-01-01         old players created; before 2026-11 only old lifetime totals exist
--   2026-11-20 15:00   old per-round history rows
--   2026-11-25 17:00   first v2 map run = the cutover; old and v2 writers both run from here
--   2026-11-25 17:15   round 1 ends (the old plugins write their history for it too)
--   2026-11-25 17:30   round 2 ends; map run 1 is over at 17:40
--   2026-11-26 00:00   map run 2 starts; its round 1 is still in progress
--
-- Old tables hold local wall-clock time in the database's zone (the plugins' CURRENT_TIMESTAMP),
-- so old times are written as a UTC instant cast to the session zone, as the plugins would.
--
-- Players: ...001 Alpha (old + v2), ...002 Bravo (old + v2), ...003 Charlie_100% (old only),
-- ...004 Delta Newcomer (v2 only).

-- ---------------------------------------------------------------- old data
-- The old tables live in the user's own schema if there is one, else public (see stats_04_old.sql).
DO $$ BEGIN
    PERFORM set_config('search_path', CASE WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = current_user)
                                           THEN quote_ident(current_user) ELSE 'public' END, true);
END $$;

INSERT INTO weapon_stats (weapon_name) VALUES ('m4a1'), ('ak74'), ('m9');
INSERT INTO map_stats (map_name) VALUES ('ministry'), ('buhriz');

INSERT INTO player_stats
    (steam_id, name, kills, deaths, suicides, headshot_given, suppressions, caps, killstreak, score,
     wins, losses, play_time_seconds, created_at, updated_at)
VALUES
    ('76561198000000001', 'Alpha Tester', 100, 10, 1, 20, 40, 5, 12, 500, 6, 3, 4000,
     '2026-01-01 13:00Z'::timestamptz::timestamp, '2026-11-25 17:35Z'::timestamptz::timestamp),
    ('76561198000000002', 'Bravo Tester', 50, 30, 2, 5, 10, 2, 6, 200, 3, 4, 3000,
     '2026-01-01 13:00Z'::timestamptz::timestamp, '2026-11-25 17:31Z'::timestamptz::timestamp),
    ('76561198000000003', 'Charlie_100%', 20, 40, 3, 2, 1, 1, 3, 80, 1, 5, 1200,
     '2026-02-01 13:00Z'::timestamptz::timestamp, '2026-10-01 12:00Z'::timestamptz::timestamp);

-- Per-round history: two rows before the cutover and one dual-written for v2 round 1.
INSERT INTO player_rounds
    (steam_id, recorded_at, map_name, kills, deaths, suicides, headshot_given, suppressions, caps, score,
     wins, losses, killstreak, play_time_seconds, shots, enemy_hits, friendly_hits)
VALUES
    ('76561198000000001', '2026-11-20 15:00Z'::timestamptz::timestamp, 'ministry', 10, 2, 0, 3, 5, 1, 50, 1, 0, 4, 600, 200, 50, 1),
    ('76561198000000002', '2026-11-20 15:00Z'::timestamptz::timestamp, 'ministry', 4, 3, 0, 1, 2, 0, 20, 1, 0, 2, 600, 100, 20, 0),
    ('76561198000000001', '2026-11-25 17:15Z'::timestamptz::timestamp, 'ministry', 2, 1, 0, 1, 3, 1, 50, 1, 0, 2, 900, 600, 150, 2);

INSERT INTO player_round_weapons (round_id, weapon_id, kills, shots, enemy_hits, friendly_hits)
SELECT r.id, w.weapon_id, v.k, v.s, v.e, v.f
FROM (VALUES ('76561198000000001', '2026-11-20 15:00Z'::timestamptz, 'm4a1', 10, 200, 50, 1),
             ('76561198000000002', '2026-11-20 15:00Z', 'ak74', 4, 100, 20, 0),
             ('76561198000000001', '2026-11-25 17:15Z', 'm4a1', 2, 600, 150, 2)) v(sid, t, wn, k, s, e, f)
JOIN player_rounds r ON r.steam_id = v.sid AND r.recorded_at = v.t::timestamp
JOIN weapon_stats w ON w.weapon_name = v.wn;

-- Lifetime per weapon (they include all the history above).
INSERT INTO player_kills (steam_id, weapon_id, kill_count)
SELECT v.sid, w.weapon_id, v.n
FROM (VALUES ('76561198000000001', 'm4a1', 90), ('76561198000000001', 'm9', 10),
             ('76561198000000002', 'ak74', 50), ('76561198000000003', 'ak74', 20)) v(sid, wn, n)
JOIN weapon_stats w ON w.weapon_name = v.wn;
INSERT INTO player_shots (steam_id, weapon_id, shots, enemy_hits, friendly_hits)
SELECT v.sid, w.weapon_id, v.s, v.e, v.f
FROM (VALUES ('76561198000000001', 'm4a1', 1500, 400, 5), ('76561198000000002', 'ak74', 800, 200, 2),
             ('76561198000000003', 'ak74', 300, 60, 0)) v(sid, wn, s, e, f)
JOIN weapon_stats w ON w.weapon_name = v.wn;

INSERT INTO medics (steamId, medic_time, heals, revives)
VALUES ('76561198000000001', 1000, 10, 4), ('76561198000000002', 100, 1, 0);
INSERT INTO medic_rounds (steam_id, recorded_at, medic_time, heals, revives)
VALUES ('76561198000000001', '2026-11-20 15:00Z'::timestamptz::timestamp, 100, 1, 1);

INSERT INTO player_tks (steam_id, tk_given, tk_taken) VALUES (76561198000000001, 3, 0), (76561198000000002, 0, 3);
INSERT INTO player_tk_logs (victim_steam_id, attacker_steam_id, weapon, forgiven, created_at) VALUES
    (76561198000000002, 76561198000000001, 'knife', false, '2025-12-10 20:00Z'::timestamptz::timestamp),
    (76561198000000002, 76561198000000001, 'm4a1', true, '2026-11-20 15:00Z'::timestamptz::timestamp),
    (76561198000000002, 76561198000000001, 'm4a1', true, '2026-11-25 17:06Z'::timestamptz::timestamp);

INSERT INTO fire_support (steamId, arty_thrown) VALUES ('76561198000000001', 5);
INSERT INTO fire_support_calls (steam_id, called_at)
VALUES ('76561198000000001', '2026-11-20 15:00Z'::timestamptz::timestamp),
       ('76561198000000001', '2026-11-25 17:03Z'::timestamptz::timestamp);

INSERT INTO bot_kills (bot_name, weapon_id, kill_count, updated_at)
SELECT v.bot, w.weapon_id, v.n, v.t::timestamp
FROM (VALUES ('Rifleman Jones', 'ak74', 5, '2026-11-25 17:06Z'::timestamptz),
             ('Old Sniper', 'm9', 7, '2026-10-01 12:00Z')) v(bot, wn, n, t)
JOIN weapon_stats w ON w.weapon_name = v.wn;

INSERT INTO maps (map_name, play_time, last_start, updated_at) VALUES
    ('ministry', '2 hours', '2026-11-25 17:00Z'::timestamptz::timestamp, '2026-11-25 17:15Z'::timestamptz::timestamp),
    ('buhriz', '1 hour', '2026-11-01 12:00Z'::timestamptz::timestamp, '2026-11-01 13:00Z'::timestamptz::timestamp);
INSERT INTO win_loss_log (map_id, win, created_at)
SELECT m.map_id, v.w, v.t::timestamp FROM map_stats m
JOIN (VALUES ('ministry', true, '2026-11-19 15:00Z'::timestamptz), ('ministry', false, '2026-11-20 15:00Z'),
             ('ministry', true, '2026-11-25 17:15Z'), ('buhriz', true, '2026-11-01 13:00Z')) v(mn, w, t)
     ON v.mn = m.map_name;

-- ---------------------------------------------------------------- v2 data
DO $$ BEGIN
    PERFORM set_config('search_path', (SELECT quote_ident(nspname) FROM pg_namespace
        WHERE nspname LIKE 'stats\_%' AND nspowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)), true);
END $$;

INSERT INTO server_builds VALUES ('abc1234', '1.2.3');
INSERT INTO server_boots VALUES ('2026-11-25 16:50Z', 'abc1234');
INSERT INTO maps VALUES ('ministry'), ('sinjar');
INSERT INTO game_modes VALUES ('checkpoint'), ('push');
INSERT INTO theaters VALUES ('default');
INSERT INTO map_runs (map_run_id, booted_at, started_at, map_name, game_mode, theater, load_seconds, game_over_at) VALUES
    (1, '2026-11-25 16:50Z', '2026-11-25 17:00Z', 'ministry', 'checkpoint', 'default', 3.5, '2026-11-25 17:40Z'),
    (2, '2026-11-25 16:50Z', '2026-11-26 00:00Z', 'sinjar', 'push', NULL, 4.25, NULL);
INSERT INTO players VALUES (76561198000000001), (76561198000000002), (76561198000000004);
INSERT INTO rounds (round_id, map_run_id, round_number, started_at, live_at, ended_at, winner, end_reason, mvp_steam_id) VALUES
    (1, 1, 1, '2026-11-25 17:00Z', '2026-11-25 17:00:30Z', '2026-11-25 17:15Z', 'security', 'objective', 76561198000000001),
    (2, 1, 2, '2026-11-25 17:16Z', '2026-11-25 17:16:30Z', '2026-11-25 17:30Z', 'insurgents', 'elimination', NULL),
    (3, 2, 1, '2026-11-26 00:00Z', '2026-11-26 00:00:30Z', NULL, NULL, NULL, NULL);

INSERT INTO sessions (steam_id, connected_at, disconnected_at, disconnect_reason) VALUES
    (76561198000000001, '2026-11-25 16:55Z', '2026-11-25 17:35Z', 'Disconnect by user.'),
    (76561198000000001, '2026-11-25 23:58Z', NULL, NULL),
    (76561198000000002, '2026-11-25 16:58Z', '2026-11-25 17:31Z', 'Disconnect by user.'),
    (76561198000000004, '2026-11-25 16:59Z', '2026-11-25 17:29Z', 'timed out');
INSERT INTO name_changes (steam_id, connected_at, changed_at, name) VALUES
    (76561198000000001, '2026-11-25 16:55Z', '2026-11-25 16:55Z', 'Alpha Tester'),
    (76561198000000001, '2026-11-25 16:55Z', '2026-11-25 17:20Z', 'Alpha Renamed'),
    (76561198000000001, '2026-11-25 23:58Z', '2026-11-25 23:58Z', 'Alpha Renamed'),
    (76561198000000002, '2026-11-25 16:58Z', '2026-11-25 16:58Z', 'Bravo Tester'),
    (76561198000000004, '2026-11-25 16:59Z', '2026-11-25 16:59Z', 'Delta Newcomer');

INSERT INTO weapon_types VALUES ('rifle'), ('explosive');
INSERT INTO weapons VALUES ('m4a1', 'rifle'), ('ak74', 'rifle'), ('grenade_m67', 'explosive'), ('c4', 'explosive');

INSERT INTO player_spans (round_id, steam_id, started_at, ended_at, team, squad, squad_slot, class_template) VALUES
    (1, 76561198000000001, '2026-11-25 17:00Z', '2026-11-25 17:05Z', 'security', 0, 1, 'template_rifleman_security'),
    (1, 76561198000000001, '2026-11-25 17:05Z', '2026-11-25 17:15Z', 'security', 0, 1, 'template_medic_security'),
    (1, 76561198000000002, '2026-11-25 17:00Z', '2026-11-25 17:15Z', 'security', 0, 2, 'template_rifleman_security'),
    (1, 76561198000000004, '2026-11-25 17:00Z', '2026-11-25 17:15Z', 'security', 1, 0, 'template_rifleman_security'),
    (2, 76561198000000001, '2026-11-25 17:16Z', '2026-11-25 17:30Z', 'security', 0, 1, 'template_medic_security'),
    (2, 76561198000000002, '2026-11-25 17:16Z', '2026-11-25 17:30Z', 'security', 0, 2, 'template_rifleman_security'),
    (2, 76561198000000004, '2026-11-25 17:16Z', '2026-11-25 17:28Z', 'security', 1, 0, 'template_rifleman_security'),
    (3, 76561198000000001, '2026-11-26 00:00Z', '2026-11-26 00:10Z', 'security', 0, 1, 'template_rifleman_security');

INSERT INTO spawns (spawn_id, round_id, steam_id, spawned_at) VALUES (1, 1, 76561198000000001, '2026-11-25 17:00:05Z');
INSERT INTO spawn_items VALUES (1, 'weapon_m4a1'), (1, 'kevlar_heavy');

INSERT INTO kills (kill_id, round_id, killed_at, victim_steam_id, victim_bot_name, victim_bot_team, victim_bot_class,
                   victim_x, victim_y, victim_z, attacker_steam_id, attacker_bot_name, attacker_bot_team,
                   attacker_bot_class, attacker_x, attacker_y, attacker_z, assister_steam_id, weapon_name, hitgroup,
                   headshot, domination, revenge, savior, offensive, defensive, damagebits, customkill,
                   attacker_stance, attacker_aim) VALUES
    (1, 1, '2026-11-25 17:02Z', NULL, 'Rifleman Jones', 'insurgents', 'template_rifleman_insurgent', 100, 200, 10,
     76561198000000001, NULL, NULL, NULL, 150, 260, 10, NULL, 'm4a1', 'head', true, false, false, false, true, false, 2, 0, 'crouched', 'sights'),
    (2, 1, '2026-11-25 17:03Z', NULL, 'Rifleman Smith', 'insurgents', 'template_rifleman_insurgent', 110, 210, 10,
     76561198000000001, NULL, NULL, NULL, 150, 260, 10, NULL, 'm4a1', 'chest', false, false, false, false, true, false, 2, 0, 'standing', 'hip'),
    (3, 1, '2026-11-25 17:04Z', NULL, 'Rifleman Brown', 'insurgents', 'template_rifleman_insurgent', 120, 220, 12,
     76561198000000004, NULL, NULL, NULL, 160, 270, 12, 76561198000000001, 'ak74', 'stomach', false, false, false, false, false, true, 2, 0, 'prone', 'sights'),
    (4, 1, '2026-11-25 17:05Z', 76561198000000001, NULL, NULL, NULL, 150, 260, 10,
     NULL, 'Rifleman Jones', 'insurgents', 'template_rifleman_insurgent', 90, 190, 10, NULL, 'ak74', 'chest', false, false, false, false, false, false, 2, 0, NULL, NULL),
    (5, 1, '2026-11-25 17:06Z', 76561198000000002, NULL, NULL, NULL, 155, 265, 10,
     76561198000000001, NULL, NULL, NULL, 150, 260, 10, NULL, 'm4a1', 'right_leg', false, false, false, false, false, false, 2, 0, 'standing', 'hip'),
    (6, 1, '2026-11-25 17:08Z', 76561198000000002, NULL, NULL, NULL, 155, 265, 10,
     76561198000000002, NULL, NULL, NULL, 155, 265, 10, NULL, 'grenade_m67', 'generic', false, false, false, false, false, false, 64, 0, 'standing', 'hip'),
    (7, 1, '2026-11-25 17:09Z', 76561198000000004, NULL, NULL, NULL, 170, 280, -50,
     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, false, false, false, false, false, false, 32, 0, NULL, NULL),
    (8, 2, '2026-11-25 17:20Z', NULL, 'Rifleman Jones', 'insurgents', 'template_rifleman_insurgent', 300, 400, 0,
     76561198000000002, NULL, NULL, NULL, 320, 420, 0, NULL, 'ak74', 'head', true, false, false, false, true, false, 2, 0, 'standing', 'sights'),
    (9, 2, '2026-11-25 17:25Z', 76561198000000004, NULL, NULL, NULL, 330, 430, 0,
     NULL, 'Rifleman Smith', 'insurgents', 'template_rifleman_insurgent', 350, 450, 0, NULL, 'ak74', 'chest', false, false, false, false, false, false, 2, 0, NULL, NULL),
    (10, 3, '2026-11-26 00:06Z', NULL, 'Rifleman Lee', 'insurgents', 'template_rifleman_insurgent', 500, 600, 5,
     76561198000000001, NULL, NULL, NULL, 520, 620, 5, NULL, 'm4a1', 'chest', false, false, false, false, true, false, 2, 0, 'standing', 'sights');
INSERT INTO team_kill_forgives VALUES (5, '2026-11-25 17:06:10Z');

INSERT INTO player_rounds (round_id, steam_id, score, capture_ticks, suppressions, times_suppressed, damage_taken) VALUES
    (1, 76561198000000001, 50, 4, 3, 1, 80), (1, 76561198000000002, 20, 4, 1, 0, 100),
    (1, 76561198000000004, 15, 0, 0, 2, 100), (2, 76561198000000001, 30, 0, 2, 0, 0),
    (2, 76561198000000002, 25, 0, 0, 1, 0), (2, 76561198000000004, 5, 0, 0, 0, 100),
    (3, 76561198000000001, 10, 0, 0, 0, 0);
INSERT INTO player_round_weapons (round_id, steam_id, weapon_name, shots, shots_hit_enemy, shots_hit_friendly,
                                  hits_head, hits_chest, hits_stomach, hits_arms, hits_legs, damage_enemy,
                                  damage_friendly, reloads, deploys, seconds_drawn) VALUES
    (1, 76561198000000001, 'm4a1', 600, 150, 2, 10, 60, 30, 30, 20, 3000, 40, 20, 3, 800),
    (1, 76561198000000004, 'ak74', 100, 30, 0, 2, 15, 5, 5, 3, 600, 0, 4, 1, 850),
    (2, 76561198000000001, 'm4a1', 300, 60, 0, 5, 30, 10, 10, 5, 1200, 0, 10, 1, 700),
    (2, 76561198000000002, 'ak74', 200, 50, 1, 6, 20, 10, 10, 4, 1000, 25, 8, 1, 800),
    (3, 76561198000000001, 'm4a1', 50, 10, 0, 1, 5, 2, 1, 1, 200, 0, 2, 1, 500);

INSERT INTO revives (revive_id, round_id, started_at, revived_at, reviver_steam_id, revived_steam_id, method) VALUES
    (1, 1, '2026-11-25 17:06:20Z', '2026-11-25 17:06:30Z', 76561198000000001, 76561198000000002, 'defib'),
    (2, 2, '2026-11-25 17:25:10Z', '2026-11-25 17:25:18Z', 76561198000000001, 76561198000000004, 'knife');
INSERT INTO revive_helpers VALUES (1, 76561198000000004);
INSERT INTO heals (heal_id, round_id, started_at, ended_at, healer_steam_id, patient_steam_id, hp_healed, to_full) VALUES
    (1, 1, '2026-11-25 17:07Z', '2026-11-25 17:07:20Z', 76561198000000001, 76561198000000002, 60, true),
    (2, 2, '2026-11-25 17:26Z', '2026-11-25 17:26:05Z', 76561198000000001, 76561198000000004, 20, false);
INSERT INTO heal_holds VALUES (1, '2026-11-25 17:07Z', '2026-11-25 17:07:20Z', 'full_health'),
                              (2, '2026-11-25 17:26Z', '2026-11-25 17:26:05Z', 'keys_released');

INSERT INTO fire_support_calls (call_id, round_id, called_at, steam_id, support_type, target_x, target_y, target_z,
                                failure_reason, refunded_at) VALUES
    (1, 1, '2026-11-25 17:03Z', 76561198000000001, 'artillery', 400, 500, 0, NULL, NULL),
    (2, 1, '2026-11-25 17:04Z', 76561198000000001, 'artillery', NULL, NULL, NULL, 'player_cooldown', '2026-11-25 17:04:01Z'),
    (3, 1, '2026-11-25 17:10Z', 76561198000000002, 'smoke', 410, 510, 0, NULL, NULL);

INSERT INTO objective_events (objective_event_id, round_id, at, kind, control_point, cp_name, team, weapon_name) VALUES
    (1, 1, '2026-11-25 17:10Z', 'captured', 0, 'A', 'security', NULL),
    (2, 1, '2026-11-25 17:12Z', 'cache_destroyed', 1, 'B', 'security', 'c4'),
    (3, 2, '2026-11-25 17:22Z', 'captured', 0, 'A', 'insurgents', NULL);
INSERT INTO objective_participants VALUES
    (1, 76561198000000001, 'capper'), (1, 76561198000000002, 'capper'), (1, 76561198000000004, 'assister'),
    (2, 76561198000000004, 'attacker');
INSERT INTO counterattacks VALUES (1, 0, '2026-11-25 17:10:30Z', '2026-11-25 17:12Z', false);
INSERT INTO survival_levels VALUES (1, 1, '2026-11-25 17:08Z');

-- Explicit ids above: move the sequences past them.
SELECT setval(pg_get_serial_sequence(t, c), 1000)
FROM (VALUES ('map_runs', 'map_run_id'), ('rounds', 'round_id'), ('kills', 'kill_id'), ('revives', 'revive_id'),
             ('heals', 'heal_id'), ('fire_support_calls', 'call_id'), ('objective_events', 'objective_event_id'),
             ('spawns', 'spawn_id')) s(t, c);
