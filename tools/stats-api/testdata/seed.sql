-- Dummy data for local testing of stats-api. The keyed tables use
-- ON CONFLICT DO NOTHING so re-applying is safe; win_loss_log is an append-only
-- match log with no unique key, so re-running adds more match rows to it.

-- Players ------------------------------------------------------------------
INSERT INTO player_stats
    (steam_id, kills, deaths, suicides, headshot_given, headshot_taken, suppressions, caps, killstreak, score, wins, losses)
VALUES
    ('76561198000000001', 1500, 800,  12, 420, 210, 95, 60, 18, 45000, 125, 75),
    ('76561198000000002',  980, 1020, 30, 180, 260, 40, 35,  9, 21000,  60, 90),
    ('76561198000000003',  250, 140,   3,  70,  40, 12, 88,  6, 12000,  40, 20),
    ('76561198000000004',   40, 310,  22,   5,  90,  2,  4,  2,   900,   5, 35)
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

-- Per-bot weapon kills -----------------------------------------------------
INSERT INTO bot_kills (bot_name, weapon_id, kill_count)
SELECT v.bot_name, w.weapon_id, v.kill_count
FROM (VALUES
    ('Bot Adams',  'ak47',  120),
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
INSERT INTO medics (steamId, medic_time)
VALUES
    ('76561198000000003', 30000),
    ('76561198000000001', 14400),
    ('76561198000000002', 8200),
    ('76561198000000004', 1500)
ON CONFLICT (steamId) DO NOTHING;

-- Team kills (gg2_teamkill) -- steam_id is BIGINT here -----------------------
INSERT INTO player_tks (steam_id, kills, tk_given, tk_taken, last_seen)
VALUES
    (76561198000000004,   40, 30,  9, CURRENT_TIMESTAMP),
    (76561198000000001, 1500, 12,  4, CURRENT_TIMESTAMP),
    (76561198000000002,  980,  7, 15, CURRENT_TIMESTAMP)
ON CONFLICT (steam_id) DO NOTHING;
