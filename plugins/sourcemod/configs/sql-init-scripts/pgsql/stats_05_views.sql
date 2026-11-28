-- =====================================================
-- Stats v2 (issue #44), part 5: per-kill and per-player-round views.
--
-- These views are the one place the stats API and the Discord bot read totals from, never the raw
-- tables. Per-round results come from player_round_results_current (stats_03_results.sql): each
-- finished round's result as cached, the rest computed live, by the same definition.
--
-- The cutover is the first v2 map run (v_cutover). Before it, per-round numbers come from the old
-- tables' history; from it on, only from v2 rows, so the weeks both are written count once.
-- Needs stats_01..04.
-- =====================================================

CREATE OR REPLACE VIEW v_cutover AS
SELECT COALESCE(min(started_at), 'infinity'::timestamptz) AS cutover_at FROM map_runs;

-- kills, plus the bots' class names, whether the round was live, and what kind of death it was.
CREATE OR REPLACE VIEW v_kills AS
SELECT k.*,
       vc.class_template AS victim_bot_class, ac.class_template AS attacker_bot_class,
       (r.live_at IS NOT NULL AND k.killed_at >= r.live_at
            AND (r.ended_at IS NULL OR k.killed_at <= r.ended_at)) AS during_live,
       stats_kill_kind(k.attacker_steam_id, k.attacker_bot_name, k.victim_steam_id, k.attacker_team, k.victim_team) AS kind
FROM kills k
JOIN rounds r USING (round_id)
LEFT JOIN bot_classes vc ON vc.bot_class_id = k.victim_bot_class_id
LEFT JOIN bot_classes ac ON ac.bot_class_id = k.attacker_bot_class_id;

-- hits that did not kill (the killing blow is in v_kills), plus the bots' class names, whether the round
-- was live, and the hit's kind as for a kill ('team_kill' is a hit on a teammate).
CREATE OR REPLACE VIEW v_hits AS
SELECT h.*,
       vc.class_template AS victim_bot_class, ac.class_template AS attacker_bot_class,
       (r.live_at IS NOT NULL AND h.hit_at >= r.live_at
            AND (r.ended_at IS NULL OR h.hit_at <= r.ended_at)) AS during_live,
       stats_kill_kind(h.attacker_steam_id, h.attacker_bot_name, h.victim_steam_id, h.attacker_team, h.victim_team) AS kind
FROM hits h
JOIN rounds r USING (round_id)
LEFT JOIN bot_classes vc ON vc.bot_class_id = h.victim_bot_class_id
LEFT JOIN bot_classes ac ON ac.bot_class_id = h.attacker_bot_class_id;

-- Per-round results (stats_03_results.sql): cached rows plus the rounds not cached, computed live: exact at any moment.
CREATE OR REPLACE VIEW player_round_results_current AS
SELECT * FROM player_round_results
UNION ALL
SELECT * FROM stats_round_results(ARRAY(
    SELECT r.round_id FROM rounds r WHERE NOT EXISTS (SELECT 1 FROM round_results_done d WHERE d.round_id = r.round_id)));

CREATE OR REPLACE VIEW player_round_weapon_results_current AS
SELECT * FROM player_round_weapon_results
UNION ALL
SELECT * FROM stats_round_weapon_results(ARRAY(
    SELECT r.round_id FROM rounds r WHERE NOT EXISTS (SELECT 1 FROM round_results_done d WHERE d.round_id = r.round_id)));

-- Best killstreak per player from v2 data: enemy kills between two deaths, carried across rounds and
-- maps as the old plugin did. Built from each round's first, best and last streak
-- (player_round_results): a streak still open at a round's end carries into the player's next round,
-- and the first death there ends it.
CREATE OR REPLACE VIEW v_killstreaks AS
WITH g AS (
    SELECT steam_id, round_id, at, died, kills_before_first_death AS first_n,
           best_streak_inside AS inside_n, kills_after_last_death AS last_n,
           -- what a round passes on to the next: its last streak, or all of its kills if no death
           CASE WHEN died THEN kills_after_last_death ELSE kills_before_first_death END AS out_n,
           -- streak groups: a round with a death starts a new one
           sum(died::int) OVER (PARTITION BY steam_id ORDER BY at, round_id) AS grp
    FROM player_round_results_current
),
gt AS (SELECT steam_id, grp, sum(out_n) AS total FROM g GROUP BY 1, 2),
c AS (
    SELECT g.*,
           CASE WHEN g.died THEN COALESCE(p.total, 0)   -- everything since the previous group's death
                ELSE COALESCE(sum(g.out_n) OVER (PARTITION BY g.steam_id, g.grp ORDER BY g.at, g.round_id
                                                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
           END AS carried
    FROM g LEFT JOIN gt p ON p.steam_id = g.steam_id AND p.grp = g.grp - 1
)
SELECT steam_id, max(GREATEST(inside_n, carried + first_n, last_n))::int AS best_killstreak
FROM c GROUP BY steam_id;

-- One row per player per round. v2 rounds have a round_id; old history rows (before the cutover)
-- have none, and old medic, team kill and fire support history arrive as rows of their own.
-- Columns the old data never had are NULL there, not 0.
CREATE OR REPLACE VIEW v_player_round_stats AS
SELECT round_id, steam_id, at, 'v2'::text AS source,
       kills, deaths, suicides, world_deaths, team_kills, team_killed, assists, headshot_kills,
       headshot_hits, caps, cache_kills, score, wins, losses, play_seconds, medic_seconds,
       revives, times_revived, heals, hp_healed, fire_support_calls, suppressions, times_suppressed,
       shots, shots_hit_enemy, shots_hit_friendly, damage_enemy, damage_taken
FROM player_round_results_current
UNION ALL
SELECT NULL, o.steam_id::bigint, o.recorded_at, 'old',
       o.kills, o.deaths, o.suicides, NULL, NULL, NULL, NULL, NULL, o.headshot_given,
       o.caps, NULL, o.score, o.wins, o.losses, o.play_time_seconds, NULL,
       NULL, NULL, NULL, NULL, NULL, o.suppressions, NULL,
       o.shots, o.enemy_hits, o.friendly_hits, NULL, NULL
FROM old_player_rounds o, v_cutover c
WHERE o.recorded_at < c.cutover_at AND o.steam_id ~ '^[0-9]+$'
UNION ALL
SELECT NULL, m.steam_id::bigint, m.recorded_at, 'old',
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       m.medic_time, m.revives, NULL, m.heals, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM old_medic_rounds m, v_cutover c
WHERE m.recorded_at < c.cutover_at AND m.steam_id ~ '^[0-9]+$'
UNION ALL
SELECT NULL, x.steam_id, x.created_at, 'old',
       NULL, NULL, NULL, NULL, x.tk, x.tkd, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM (SELECT attacker_steam_id AS steam_id, created_at, 1 AS tk, 0 AS tkd FROM old_player_tk_logs
      UNION ALL SELECT victim_steam_id, created_at, 0, 1 FROM old_player_tk_logs) x, v_cutover c
WHERE x.created_at < c.cutover_at
UNION ALL
SELECT NULL, f.steam_id::bigint, f.called_at, 'old',
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM old_fire_support_calls f, v_cutover c
WHERE f.called_at < c.cutover_at AND f.steam_id ~ '^[0-9]+$';
