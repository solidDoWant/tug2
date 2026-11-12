-- Dummy data for local testing of stats-api. The keyed tables use
-- ON CONFLICT DO NOTHING so re-applying is safe; win_loss_log and player_tk_logs
-- are append-only logs with no unique key, so re-running adds more rows to them.

-- Players ------------------------------------------------------------------
INSERT INTO player_stats
    (steam_id, name, kills, deaths, suicides, headshot_given, headshot_taken, suppressions, caps, killstreak, score, wins, losses, play_time_seconds)
VALUES
    ('76561198000000001', 'TestPlayerAlpha', 1500, 800,  12, 420, 210, 95, 60, 18, 45000, 125, 75, 360000),
    ('76561198000000002', 'TestPlayerBravo', 980, 1020, 30, 180, 260, 40, 35,  9, 21000,  60, 90, 151200),
    ('76561198000000003', 'test_medic_100%', 250, 140,   3,  70,  40, 12, 88,  6, 12000,  40, 20,  54000),
    ('76561198000000004', NULL,             40, 310,  22,   5,  90,  2,  4,  2,   900,   5, 35,      0)
ON CONFLICT (steam_id) DO NOTHING;

-- Weapons ------------------------------------------------------------------
INSERT INTO weapon_stats (weapon_name)
VALUES ('m16a4'), ('ak47'), ('m1014'), ('m9'), ('knife'), ('m24')
ON CONFLICT (weapon_name) DO NOTHING;

-- Per-player weapon kills --------------------------------------------------
INSERT INTO player_kills (steam_id, weapon_id, kill_count)
SELECT v.steam_id, w.weapon_id, v.kill_count
FROM (VALUES
    ('76561198000000001', 'm16a4', 900),
    ('76561198000000001', 'ak47',  400),
    ('76561198000000001', 'knife',  60),
    ('76561198000000002', 'ak47',  700),
    ('76561198000000002', 'm9',    180),
    ('76561198000000003', 'm24',   200),
    ('76561198000000004', 'm1014',  40)
) AS v(steam_id, weapon_name, kill_count)
JOIN weapon_stats w ON w.weapon_name = v.weapon_name
ON CONFLICT (steam_id, weapon_id) DO NOTHING;

-- Per-player shots and hits --------------------------------------------------
INSERT INTO player_shots (steam_id, weapon_id, shots, enemy_hits, friendly_hits)
SELECT v.steam_id, w.weapon_id, v.shots, v.enemy_hits, v.friendly_hits
FROM (VALUES
    ('76561198000000001', 'm16a4', 4200, 1890, 12),
    ('76561198000000001', 'ak47',  1500,  610,  3),
    ('76561198000000002', 'ak47',  3100,  980, 25),
    ('76561198000000002', 'm1014',  300,  150,  0),
    ('76561198000000003', 'm24',    450,  260,  1)
) AS v(steam_id, weapon_name, shots, enemy_hits, friendly_hits)
JOIN weapon_stats w ON w.weapon_name = v.weapon_name
ON CONFLICT (steam_id, weapon_id) DO NOTHING;

-- Per-bot weapon kills -----------------------------------------------------
INSERT INTO bot_kills (bot_name, weapon_id, kill_count)
SELECT v.bot_name, w.weapon_id, v.kill_count
FROM (VALUES
    ('Bot Adams',  'ak47',  120),
    ('Bot Adams',  'm9',     30),
    ('Bot Baker',  'm16a4',  85),
    ('Bot Carter', 'm24',    50)
) AS v(bot_name, weapon_name, kill_count)
JOIN weapon_stats w ON w.weapon_name = v.weapon_name
ON CONFLICT (bot_name, weapon_id) DO NOTHING;

-- Maps ---------------------------------------------------------------------
INSERT INTO map_stats (map_name)
VALUES ('ministry'), ('sinjar'), ('buhriz'), ('peak')
ON CONFLICT (map_name) DO NOTHING;

-- Match results ------------------------------------------------------------
INSERT INTO win_loss_log (map_id, win)
SELECT m.map_id, v.win
FROM (VALUES
    ('ministry', TRUE),
    ('ministry', TRUE),
    ('ministry', FALSE),
    ('sinjar',   TRUE),
    ('sinjar',   FALSE),
    ('buhriz',   FALSE),
    ('buhriz',   FALSE),
    ('peak',     TRUE)
) AS v(map_name, win)
JOIN map_stats m ON m.map_name = v.map_name;

-- Medics (gg2_medic_tracker) -- medic_time is seconds spent as medic ---------
INSERT INTO medics (steamId, medic_time, heals, revives)
VALUES
    ('76561198000000003', 30000, 40, 95),
    ('76561198000000001', 14400, 22, 30),
    ('76561198000000002', 8200, 31, 12),
    ('76561198000000004', 1500, 0, 2)
ON CONFLICT (steamId) DO NOTHING;

-- Team kills (gg2_teamkill) -- steam_id is BIGINT here -----------------------
-- player_tks.kills is deliberately not seeded: nothing writes it in production
-- either, so it stays 0 here. Kill counts come from player_stats.
INSERT INTO player_tks (steam_id, tk_given, tk_taken, last_seen)
VALUES
    (76561198000000004, 30,  9, CURRENT_TIMESTAMP),
    (76561198000000001, 12,  4, CURRENT_TIMESTAMP),
    (76561198000000002,  7, 15, CURRENT_TIMESTAMP)
ON CONFLICT (steam_id) DO NOTHING;

-- Team kill log (gg2_teamkill) -- per-incident rows behind tk_forgiven and
-- /teamkills/weapons. Deliberately fewer rows than player_tks.tk_given, as on
-- production where the totals predate the log.
-- The two older rows fall outside a 30-day window.
INSERT INTO player_tk_logs (attacker_steam_id, victim_steam_id, weapon, forgiven, created_at)
VALUES
    (76561198000000004, 76561198000000002, 'weapon_m1014', FALSE, CURRENT_TIMESTAMP - INTERVAL '2 days'),
    (76561198000000004, 76561198000000002, 'weapon_m1014', TRUE,  CURRENT_TIMESTAMP - INTERVAL '1 day'),
    (76561198000000004, 76561198000000001, 'grenade_m67',  FALSE, CURRENT_TIMESTAMP - INTERVAL '60 days'),
    (76561198000000001, 76561198000000002, 'weapon_m16a4', TRUE,  CURRENT_TIMESTAMP - INTERVAL '3 days'),
    (76561198000000002, 76561198000000004, 'grenade_m67',  TRUE,  CURRENT_TIMESTAMP - INTERVAL '90 days'),
    (76561198000000002, 76561198000000001, NULL,           FALSE, CURRENT_TIMESTAMP - INTERVAL '5 days');

-- Map playtime (map_logger) -- 'district' has playtime but no logged rounds,
-- and 'peak' has rounds (above) but no playtime, to exercise the full join.
INSERT INTO maps (map_name, play_time, last_start)
VALUES
    ('ministry', '5 hours 30 minutes'::INTERVAL, CURRENT_TIMESTAMP - INTERVAL '2 hours'),
    ('sinjar',   '2 hours'::INTERVAL,            CURRENT_TIMESTAMP - INTERVAL '1 day'),
    ('buhriz',   '45 minutes'::INTERVAL,         CURRENT_TIMESTAMP - INTERVAL '3 days'),
    ('district', '20 minutes'::INTERVAL,         CURRENT_TIMESTAMP)
ON CONFLICT (map_name) DO NOTHING;

-- Fire support (FireSupport) -- last_used is a Unix timestamp; 0 means unset.
INSERT INTO fire_support (steamId, arty_thrown, last_used)
VALUES
    ('76561198000000003', 42, EXTRACT(EPOCH FROM NOW())::INTEGER),
    ('76561198000000001', 17, EXTRACT(EPOCH FROM NOW() - INTERVAL '5 days')::INTEGER),
    ('76561198000000002',  3, 0)
ON CONFLICT (steamId) DO NOTHING;

-- Per-round history (issue #10) -- what each player added, with when. Rows
-- 40 days old fall outside a 30-day window. Not re-run safe (no unique key).
WITH r AS (
    INSERT INTO player_rounds (steam_id, recorded_at, map_name, kills, deaths, headshot_given, caps, score, wins, losses, killstreak, play_time_seconds, shots, enemy_hits, friendly_hits)
    VALUES
        ('76561198000000001', CURRENT_TIMESTAMP - INTERVAL '1 day',   'ministry', 40, 3, 10, 2, 1200, 1, 0, 15, 1500, 300, 140, 1),
        ('76561198000000001', CURRENT_TIMESTAMP - INTERVAL '40 days', 'sinjar',   90, 1, 20, 1, 2000, 0, 1, 33, 1800, 500, 200, 0),
        ('76561198000000002', CURRENT_TIMESTAMP - INTERVAL '2 days',  'ministry', 55, 9,  8, 0, 1500, 1, 0,  7, 1700, 600, 180, 4),
        ('76561198000000003', CURRENT_TIMESTAMP - INTERVAL '3 days',  'buhriz',   12, 2,  3, 4,  900, 0, 1,  5, 1300, 100,  60, 0)
    RETURNING id, steam_id, recorded_at
)
INSERT INTO player_round_weapons (round_id, weapon_id, kills, shots, enemy_hits, friendly_hits)
SELECT r.id, w.weapon_id, v.kills, v.shots, v.enemy_hits, v.friendly_hits
FROM r
JOIN (VALUES
    ('76561198000000001', 1,  'm16a4', 40, 300, 140, 1),
    ('76561198000000001', 40, 'm16a4', 90, 500, 200, 0),
    ('76561198000000002', 2,  'ak47',  50, 600, 180, 4),
    ('76561198000000002', 2,  'm9',     5,   0,   0, 0),
    ('76561198000000003', 3,  'm24',   12, 100,  60, 0)
) AS v(steam_id, days_ago, weapon_name, kills, shots, enemy_hits, friendly_hits)
  ON v.steam_id = r.steam_id AND r.recorded_at::date = (CURRENT_TIMESTAMP - make_interval(days => v.days_ago))::date
JOIN weapon_stats w ON w.weapon_name = v.weapon_name;

INSERT INTO medic_rounds (steam_id, recorded_at, medic_time, heals, revives)
VALUES
    ('76561198000000003', CURRENT_TIMESTAMP - INTERVAL '1 day',   1200, 3, 7),
    ('76561198000000002', CURRENT_TIMESTAMP - INTERVAL '2 days',  1800, 6, 2),
    ('76561198000000001', CURRENT_TIMESTAMP - INTERVAL '45 days', 3000, 9, 9);

INSERT INTO fire_support_calls (steam_id, called_at)
VALUES
    ('76561198000000003', CURRENT_TIMESTAMP - INTERVAL '1 day'),
    ('76561198000000003', CURRENT_TIMESTAMP - INTERVAL '2 days'),
    ('76561198000000001', CURRENT_TIMESTAMP - INTERVAL '3 days'),
    ('76561198000000001', CURRENT_TIMESTAMP - INTERVAL '50 days');
