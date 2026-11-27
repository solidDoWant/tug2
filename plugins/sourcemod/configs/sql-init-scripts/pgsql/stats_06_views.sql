-- =====================================================
-- Stats v2 (issue #44), part 6: weapon, lifetime, player, match, team kill and bot views.
--
-- Lifetime totals = every per-round row (v_player_round_stats) + the play before any history existed.
-- That pre-history is each old lifetime total minus all of that player's old history. It stays exact
-- while the old and v2 writers both run, because the old plugins write a total and its history row in
-- the same transaction. Needs stats_01..05.
-- =====================================================

-- One row per player per weapon per round; old history rows (before the cutover) have no round_id.
CREATE OR REPLACE VIEW v_player_round_weapon_stats AS
WITH wk AS (SELECT * FROM player_round_weapon_results_current)
SELECT COALESCE(w.round_id, wk.round_id) AS round_id, COALESCE(w.steam_id, wk.steam_id) AS steam_id,
       COALESCE(w.weapon_name, wk.weapon_name) AS weapon_name,
       COALESCE(r.ended_at, r.started_at) AS at, 'v2'::text AS source,
       COALESCE(wk.kills, 0) AS kills,
       COALESCE(w.shots, 0) AS shots, COALESCE(w.shots_hit_enemy, 0) AS shots_hit_enemy,
       COALESCE(w.shots_hit_friendly, 0) AS shots_hit_friendly,
       COALESCE(wk.hits_head, 0) AS hits_head, COALESCE(wk.hits_chest, 0) AS hits_chest,
       COALESCE(wk.hits_stomach, 0) AS hits_stomach, COALESCE(wk.hits_arms, 0) AS hits_arms,
       COALESCE(wk.hits_legs, 0) AS hits_legs,
       COALESCE(wk.damage_enemy, 0) AS damage_enemy, COALESCE(wk.damage_friendly, 0) AS damage_friendly,
       COALESCE(w.reloads, 0) AS reloads, COALESCE(w.deploys, 0) AS deploys,
       COALESCE(w.seconds_drawn, 0) AS seconds_drawn
FROM player_round_weapons w
FULL JOIN wk ON wk.round_id = w.round_id AND wk.steam_id = w.steam_id AND wk.weapon_name = w.weapon_name
JOIN rounds r ON r.round_id = COALESCE(w.round_id, wk.round_id)
UNION ALL
SELECT NULL, o.steam_id::bigint, ws.weapon_name, o.recorded_at, 'old',
       w.kills, w.shots, w.enemy_hits, w.friendly_hits,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM old_player_round_weapons w
JOIN old_player_rounds o ON o.id = w.round_id
JOIN old_weapon_stats ws ON ws.weapon_id = w.weapon_id
CROSS JOIN v_cutover c
WHERE o.recorded_at < c.cutover_at AND o.steam_id ~ '^[0-9]+$';

-- Play before any history existed, per player (old totals minus all old history; see the header).
CREATE OR REPLACE VIEW v_old_pre_history AS
WITH h AS (
    SELECT steam_id, sum(kills) AS kills, sum(deaths) AS deaths, sum(suicides) AS suicides,
           sum(headshot_given) AS headshot_given, sum(suppressions) AS suppressions, sum(caps) AS caps,
           sum(score) AS score, sum(wins) AS wins, sum(losses) AS losses,
           sum(play_time_seconds) AS play_time_seconds
    FROM old_player_rounds GROUP BY steam_id
),
s AS (SELECT steam_id, sum(shots) AS shots, sum(enemy_hits) AS enemy_hits, sum(friendly_hits) AS friendly_hits
      FROM old_player_shots GROUP BY steam_id),
sh AS (SELECT steam_id, sum(shots) AS shots, sum(enemy_hits) AS enemy_hits, sum(friendly_hits) AS friendly_hits
       FROM old_player_rounds GROUP BY steam_id),
m AS (SELECT steamid AS steam_id, medic_time, heals, revives FROM old_medics),
mh AS (SELECT steam_id, sum(medic_time) AS medic_time, sum(heals) AS heals, sum(revives) AS revives
       FROM old_medic_rounds GROUP BY steam_id),
tg AS (SELECT attacker_steam_id AS steam_id, count(*) AS n FROM old_player_tk_logs GROUP BY 1),
tt AS (SELECT victim_steam_id AS steam_id, count(*) AS n FROM old_player_tk_logs GROUP BY 1),
fh AS (SELECT steam_id, count(*) AS n FROM old_fire_support_calls GROUP BY 1),
ids AS (
    SELECT steam_id FROM old_player_stats UNION SELECT steamid FROM old_medics
    UNION SELECT steam_id::text FROM old_player_tks UNION SELECT steamid FROM old_fire_support
)
SELECT ids.steam_id::bigint AS steam_id,
       COALESCE(p.kills, 0) - COALESCE(h.kills, 0) AS kills,
       COALESCE(p.deaths, 0) - COALESCE(h.deaths, 0) AS deaths,
       COALESCE(p.suicides, 0) - COALESCE(h.suicides, 0) AS suicides,
       COALESCE(p.headshot_given, 0) - COALESCE(h.headshot_given, 0) AS headshot_hits,
       COALESCE(p.suppressions, 0) - COALESCE(h.suppressions, 0) AS suppressions,
       COALESCE(p.caps, 0) - COALESCE(h.caps, 0) AS caps,
       COALESCE(p.score, 0) - COALESCE(h.score, 0) AS score,
       COALESCE(p.wins, 0) - COALESCE(h.wins, 0) AS wins,
       COALESCE(p.losses, 0) - COALESCE(h.losses, 0) AS losses,
       COALESCE(p.play_time_seconds, 0) - COALESCE(h.play_time_seconds, 0) AS play_seconds,
       COALESCE(s.shots, 0) - COALESCE(sh.shots, 0) AS shots,
       COALESCE(s.enemy_hits, 0) - COALESCE(sh.enemy_hits, 0) AS shots_hit_enemy,
       COALESCE(s.friendly_hits, 0) - COALESCE(sh.friendly_hits, 0) AS shots_hit_friendly,
       COALESCE(m.medic_time, 0) - COALESCE(mh.medic_time, 0) AS medic_seconds,
       COALESCE(m.heals, 0) - COALESCE(mh.heals, 0) AS heals,
       COALESCE(m.revives, 0) - COALESCE(mh.revives, 0) AS revives,
       COALESCE(t.tk_given, 0) - COALESCE(tg.n, 0) AS team_kills,
       COALESCE(t.tk_taken, 0) - COALESCE(tt.n, 0) AS team_killed,
       COALESCE(f.arty_thrown, 0) - COALESCE(fh.n, 0) AS fire_support_calls,
       p.killstreak AS best_killstreak
FROM ids
LEFT JOIN old_player_stats p ON p.steam_id = ids.steam_id
LEFT JOIN h ON h.steam_id = ids.steam_id
LEFT JOIN s ON s.steam_id = ids.steam_id
LEFT JOIN sh ON sh.steam_id = ids.steam_id
LEFT JOIN m ON m.steam_id = ids.steam_id
LEFT JOIN mh ON mh.steam_id = ids.steam_id
LEFT JOIN old_player_tks t ON t.steam_id::text = ids.steam_id
LEFT JOIN tg ON tg.steam_id::text = ids.steam_id
LEFT JOIN tt ON tt.steam_id::text = ids.steam_id
LEFT JOIN old_fire_support f ON f.steamid = ids.steam_id
LEFT JOIN fh ON fh.steam_id = ids.steam_id
WHERE ids.steam_id ~ '^[0-9]+$';

-- Lifetime totals per player: every round row plus the pre-history.
CREATE OR REPLACE VIEW v_player_lifetime AS
WITH r AS (
    SELECT steam_id,
           sum(kills) AS kills, sum(deaths) AS deaths, sum(suicides) AS suicides,
           sum(world_deaths) AS world_deaths, sum(team_kills) AS team_kills,
           sum(team_killed) AS team_killed, sum(assists) AS assists,
           sum(headshot_kills) AS headshot_kills, sum(headshot_hits) AS headshot_hits,
           sum(caps) AS caps, sum(cache_kills) AS cache_kills, sum(score) AS score,
           sum(wins) AS wins, sum(losses) AS losses,
           count(*) FILTER (WHERE source = 'v2' AND play_seconds > 0) AS rounds_played,
           sum(play_seconds) AS play_seconds, sum(medic_seconds) AS medic_seconds,
           sum(revives) AS revives, sum(times_revived) AS times_revived,
           sum(heals) AS heals, sum(hp_healed) AS hp_healed,
           sum(fire_support_calls) AS fire_support_calls,
           sum(suppressions) AS suppressions, sum(times_suppressed) AS times_suppressed,
           sum(shots) AS shots, sum(shots_hit_enemy) AS shots_hit_enemy,
           sum(shots_hit_friendly) AS shots_hit_friendly,
           sum(damage_enemy) AS damage_enemy, sum(damage_taken) AS damage_taken
    FROM v_player_round_stats GROUP BY steam_id
)
SELECT COALESCE(r.steam_id, o.steam_id) AS steam_id,
       COALESCE(r.kills, 0) + COALESCE(o.kills, 0) AS kills,
       COALESCE(r.deaths, 0) + COALESCE(o.deaths, 0) AS deaths,
       COALESCE(r.suicides, 0) + COALESCE(o.suicides, 0) AS suicides,
       COALESCE(r.world_deaths, 0) AS world_deaths,
       COALESCE(r.team_kills, 0) + COALESCE(o.team_kills, 0) AS team_kills,
       COALESCE(r.team_killed, 0) + COALESCE(o.team_killed, 0) AS team_killed,
       COALESCE(r.assists, 0) AS assists,
       COALESCE(r.headshot_kills, 0) AS headshot_kills,
       COALESCE(r.headshot_hits, 0) + COALESCE(o.headshot_hits, 0) AS headshot_hits,
       COALESCE(r.caps, 0) + COALESCE(o.caps, 0) AS caps,
       COALESCE(r.cache_kills, 0) AS cache_kills,
       COALESCE(r.score, 0) + COALESCE(o.score, 0) AS score,
       COALESCE(r.wins, 0) + COALESCE(o.wins, 0) AS wins,
       COALESCE(r.losses, 0) + COALESCE(o.losses, 0) AS losses,
       COALESCE(r.rounds_played, 0) AS rounds_played,
       COALESCE(r.play_seconds, 0) + COALESCE(o.play_seconds, 0) AS play_seconds,
       COALESCE(r.medic_seconds, 0) + COALESCE(o.medic_seconds, 0) AS medic_seconds,
       COALESCE(r.revives, 0) + COALESCE(o.revives, 0) AS revives,
       COALESCE(r.times_revived, 0) AS times_revived,
       COALESCE(r.heals, 0) + COALESCE(o.heals, 0) AS heals,
       COALESCE(r.hp_healed, 0) AS hp_healed,
       COALESCE(r.fire_support_calls, 0) + COALESCE(o.fire_support_calls, 0) AS fire_support_calls,
       COALESCE(r.suppressions, 0) + COALESCE(o.suppressions, 0) AS suppressions,
       COALESCE(r.times_suppressed, 0) AS times_suppressed,
       COALESCE(r.shots, 0) + COALESCE(o.shots, 0) AS shots,
       COALESCE(r.shots_hit_enemy, 0) + COALESCE(o.shots_hit_enemy, 0) AS shots_hit_enemy,
       COALESCE(r.shots_hit_friendly, 0) + COALESCE(o.shots_hit_friendly, 0) AS shots_hit_friendly,
       COALESCE(r.damage_enemy, 0) AS damage_enemy, COALESCE(r.damage_taken, 0) AS damage_taken,
       GREATEST(o.best_killstreak, ks.best_killstreak, 0) AS best_killstreak
FROM r
FULL JOIN v_old_pre_history o ON o.steam_id = r.steam_id
LEFT JOIN v_killstreaks ks ON ks.steam_id = COALESCE(r.steam_id, o.steam_id);
