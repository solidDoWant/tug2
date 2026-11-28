package main

import (
	"context"
	"sort"

	"github.com/jackc/pgx/v5"
)

// mapQuery selects MapStats rows from v_maps.
const mapQuery = `
	SELECT map_name, rounds::bigint AS rounds, wins::bigint AS wins, losses::bigint AS losses,
	       CASE WHEN wins + losses > 0 THEN round(100.0 * wins / (wins + losses), 2)::float8 END AS win_rate,
	       play_seconds::bigint AS play_seconds, last_played_at
	FROM v_maps`

// mapSorts maps the /maps sort values to ORDER BY clauses.
var mapSorts = map[string]string{
	"rounds":      "rounds DESC",
	"play_time":   "play_seconds DESC",
	"last_played": "last_played_at DESC NULLS LAST",
	"win_rate":    "win_rate DESC NULLS LAST, rounds DESC",
}

// ListMaps returns a page of maps from v_maps, ordered by sort (descending).
func (s *Store) ListMaps(ctx context.Context, sort string, limit, offset int) ([]MapStats, int, error) {
	order, ok := mapSorts[sort]
	if !ok {
		order = mapSorts["rounds"]
	}
	return page[MapStats](ctx, s, mapQuery, nil, order+", map_name", limit, offset)
}

// maxRecentRuns is how many map runs GetMap returns.
const maxRecentRuns = 20

// GetMap returns one map's v_maps row, its last map runs, and up to
// positions recent v2 kills on it with a recorded position.
func (s *Store) GetMap(ctx context.Context, mapName string, positions int) (*MapDetail, error) {
	stats, err := one[MapStats](ctx, s, mapQuery+` WHERE map_name = $1`, mapName)
	if err != nil {
		return nil, err
	}
	runs, err := all[MapRunBrief](ctx, s, `
		SELECT m.map_run_id, m.started_at, m.game_mode,
		       (SELECT count(*) FROM rounds r WHERE r.map_run_id = m.map_run_id AND r.ended_at IS NOT NULL) AS rounds,
		       m.game_over_at, m.load_seconds::float8 AS load_seconds
		FROM map_runs m WHERE m.map_name = $1
		ORDER BY m.started_at DESC LIMIT $2`, mapName, maxRecentRuns)
	if err != nil {
		return nil, err
	}
	kills, err := all[KillPosition](ctx, s, `
		SELECT k.killed_at, k.kind, k.victim_x::float8 AS victim_x, k.victim_y::float8 AS victim_y,
		       k.victim_z::float8 AS victim_z, k.attacker_x::float8 AS attacker_x,
		       k.attacker_y::float8 AS attacker_y, k.attacker_z::float8 AS attacker_z,
		       k.weapon_name, k.headshot
		FROM v_kills k
		WHERE k.round_id IN (SELECT r.round_id FROM rounds r JOIN map_runs m USING (map_run_id) WHERE m.map_name = $1)
		  AND num_nonnulls(k.victim_x, k.attacker_x) > 0
		ORDER BY k.killed_at DESC, k.kill_id DESC LIMIT $2`, mapName, positions)
	if err != nil {
		return nil, err
	}
	return &MapDetail{MapStats: *stats, RecentRuns: runs, KillPositions: kills}, nil
}

// mapRunQuery selects MapRun rows: each map run with its build and its
// round results (from v_rounds).
const mapRunQuery = `
	SELECT m.map_run_id, m.map_name, m.game_mode, m.theater, m.started_at, m.game_over_at,
	       m.load_seconds::float8 AS load_seconds, b.git_commit, sb.image_version,
	       COALESCE(r.rounds, 0) AS rounds, COALESCE(r.wins, 0) AS wins, COALESCE(r.losses, 0) AS losses
	FROM map_runs m
	JOIN server_boots b USING (booted_at)
	JOIN server_builds sb ON sb.git_commit = b.git_commit
	LEFT JOIN (
		SELECT map_run_id, count(*) FILTER (WHERE ended_at IS NOT NULL) AS rounds,
		       count(*) FILTER (WHERE winner = 'security') AS wins,
		       count(*) FILTER (WHERE winner IS NOT NULL AND winner <> 'security') AS losses
		FROM v_rounds WHERE map_run_id IS NOT NULL GROUP BY map_run_id
	) r USING (map_run_id)`

// ListMapRuns returns a page of map runs, newest first.
func (s *Store) ListMapRuns(ctx context.Context, limit, offset int) ([]MapRun, int, error) {
	return page[MapRun](ctx, s, mapRunQuery, nil, "started_at DESC, map_run_id DESC", limit, offset)
}

// roundQuery selects Round rows from v_rounds (v2 rounds only).
const roundQuery = `
	SELECT r.round_id, r.map_run_id, r.map_name, r.game_mode, r.round_number::bigint AS round_number,
	       r.started_at, r.live_at, r.ended_at, r.winner::text AS winner, r.end_reason::text AS end_reason,
	       r.mvp_steam_id::text AS mvp_steam_id, p.name AS mvp_name
	FROM v_rounds r
	LEFT JOIN v_players p ON p.steam_id = r.mvp_steam_id
	WHERE r.source = 'v2'`

// GetMapRun returns one map run with its rounds and a scoreboard summed from
// v_player_round_stats over them.
func (s *Store) GetMapRun(ctx context.Context, id int64) (*MapRunDetail, error) {
	run, err := one[MapRun](ctx, s, mapRunQuery+` WHERE m.map_run_id = $1`, id)
	if err != nil {
		return nil, err
	}
	rounds, err := all[Round](ctx, s, roundQuery+` AND r.map_run_id = $1 ORDER BY r.round_number`, id)
	if err != nil {
		return nil, err
	}
	board, err := all[ScoreboardEntry](ctx, s, `
		SELECT t.steam_id::text AS steam_id, p.name, t.kills, t.deaths, t.assists, t.score, t.revives,
		       t.heals, t.caps, t.play_seconds
		FROM (
			SELECT steam_id, sum(kills)::bigint AS kills, sum(deaths)::bigint AS deaths,
			       sum(assists)::bigint AS assists, sum(score)::bigint AS score,
			       sum(revives)::bigint AS revives, sum(heals)::bigint AS heals, sum(caps)::bigint AS caps,
			       sum(play_seconds)::bigint AS play_seconds
			FROM v_player_round_stats
			WHERE round_id IN (SELECT round_id FROM rounds WHERE map_run_id = $1)
			GROUP BY steam_id
		) t
		LEFT JOIN v_players p ON p.steam_id = t.steam_id
		ORDER BY t.score DESC, t.kills DESC, t.steam_id`, id)
	if err != nil {
		return nil, err
	}
	return &MapRunDetail{Run: *run, Rounds: rounds, Scoreboard: board}, nil
}

// GetRound returns one v2 round and its timeline: kills, objectives,
// counterattack starts and ends, revives and survival levels, by time.
func (s *Store) GetRound(ctx context.Context, id int64) (*RoundDetail, error) {
	round, err := one[Round](ctx, s, roundQuery+` AND r.round_id = $1`, id)
	if err != nil {
		return nil, err
	}

	// One query per event type, each in time order; the merge below is stable.
	queries := []string{
		`SELECT k.killed_at AS at, 'kill' AS type, k.kind,
		        k.attacker_steam_id::text AS attacker_steam_id, k.attacker_bot_name,
		        COALESCE(pa.name, k.attacker_bot_name) AS attacker_name,
		        k.victim_steam_id::text AS victim_steam_id, k.victim_bot_name,
		        COALESCE(pv.name, k.victim_bot_name) AS victim_name,
		        k.weapon_name, k.headshot
		 FROM v_kills k
		 LEFT JOIN v_players pa ON pa.steam_id = k.attacker_steam_id
		 LEFT JOIN v_players pv ON pv.steam_id = k.victim_steam_id
		 WHERE k.round_id = $1 ORDER BY k.killed_at, k.kill_id`,
		`SELECT e.at, 'objective' AS type, e.kind::text AS kind, e.control_point::bigint AS control_point,
		        e.cp_name, e.team::text AS team, e.weapon_name,
		        (SELECT json_agg(json_build_object('steam_id', op.steam_id::text, 'name', p.name, 'role', op.role)
		                         ORDER BY op.role, op.steam_id)
		         FROM objective_participants op LEFT JOIN v_players p ON p.steam_id = op.steam_id
		         WHERE op.objective_event_id = e.objective_event_id) AS participants
		 FROM objective_events e WHERE e.round_id = $1 ORDER BY e.at, e.objective_event_id`,
		`SELECT started_at AS at, 'counterattack_start' AS type, control_point::bigint AS control_point, finale
		 FROM counterattacks WHERE round_id = $1
		 UNION ALL
		 SELECT ended_at, 'counterattack_end', control_point::bigint, finale
		 FROM counterattacks WHERE round_id = $1 AND ended_at IS NOT NULL
		 ORDER BY at`,
		`SELECT r.revived_at AS at, 'revive' AS type, r.method::text AS method,
		        r.reviver_steam_id::text AS reviver_steam_id, pr.name AS reviver_name,
		        r.revived_steam_id::text AS revived_steam_id, pd.name AS revived_name
		 FROM revives r
		 LEFT JOIN v_players pr ON pr.steam_id = r.reviver_steam_id
		 LEFT JOIN v_players pd ON pd.steam_id = r.revived_steam_id
		 WHERE r.round_id = $1 ORDER BY r.revived_at, r.revive_id`,
		`SELECT reached_at AS at, 'survival_level' AS type, level::bigint AS level
		 FROM survival_levels WHERE round_id = $1 ORDER BY reached_at`,
	}
	timeline := []TimelineEvent{}
	for _, q := range queries {
		rows, err := s.pool.Query(ctx, q, id)
		if err != nil {
			return nil, err
		}
		events, err := pgx.CollectRows(rows, pgx.RowToStructByNameLax[TimelineEvent])
		if err != nil {
			return nil, err
		}
		timeline = append(timeline, events...)
	}
	sort.SliceStable(timeline, func(i, j int) bool { return timeline[i].At.Before(timeline[j].At) })
	return &RoundDetail{Round: *round, Timeline: timeline}, nil
}
