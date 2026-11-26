package main

import (
	"context"
	"strings"
)

// playerStatColumns are the per-player totals PlayerStats carries, named as in
// v_player_lifetime and v_player_round_stats.
var playerStatColumns = []string{
	"kills", "deaths", "assists", "score", "wins", "losses", "play_seconds", "medic_seconds",
	"suicides", "world_deaths", "team_kills", "team_killed", "headshot_kills", "headshot_hits",
	"caps", "cache_kills", "revives", "times_revived", "heals", "hp_healed", "fire_support_calls",
	"suppressions", "times_suppressed", "shots", "shots_hit_enemy", "shots_hit_friendly",
	"damage_enemy", "damage_taken",
}

// playerTotals is a query with one row per player: steam_id (bigint), every
// playerStatColumns column, rounds_played and best_killstreak.
//
// For all time it reads v_player_lifetime. For a window it sums
// v_player_round_stats over `at`, the view's documented way to get a period;
// rounds_played is counted as v_player_lifetime counts it, and
// best_killstreak is NULL (streaks are lifetime only). A sum over rows that
// all lack a stat (old history the old plugins never recorded) stays NULL.
//
// filter, if not empty, is a condition on steam_id applied before grouping.
func playerTotals(w *Window, args *[]any, filter string) string {
	cols := make([]string, len(playerStatColumns))
	if w == nil {
		for i, c := range playerStatColumns {
			cols[i] = c + "::bigint AS " + c
		}
		q := `SELECT steam_id, ` + strings.Join(cols, ", ") + `,
			rounds_played::bigint AS rounds_played, best_killstreak::bigint AS best_killstreak
			FROM v_player_lifetime`
		if filter != "" {
			q += ` WHERE ` + filter
		}
		return q
	}
	in := w.bind(args)
	for i, c := range playerStatColumns {
		cols[i] = "sum(" + c + ")::bigint AS " + c
	}
	q := `SELECT steam_id, ` + strings.Join(cols, ", ") + `,
		count(*) FILTER (WHERE source = 'v2' AND play_seconds > 0) AS rounds_played,
		NULL::bigint AS best_killstreak
		FROM v_player_round_stats WHERE ` + in("at")
	if filter != "" {
		q += ` AND ` + filter
	}
	return q + ` GROUP BY steam_id`
}

// playerQuery selects PlayerStats rows: every player in v_players joined to
// their totals. With onlyActive, players without totals (in the window) are
// left out; otherwise they get zeros (and a lifetime streak of 0).
func playerQuery(w *Window, args *[]any, filter string, onlyActive bool) string {
	cols := make([]string, len(playerStatColumns))
	for i, c := range playerStatColumns {
		cols[i] = "CASE WHEN t.steam_id IS NULL THEN 0 ELSE t." + c + " END AS " + c
	}
	streak := "COALESCE(t.best_killstreak, 0)"
	if w != nil {
		streak = "NULL::bigint"
	}
	join := "LEFT JOIN"
	if onlyActive {
		join = "JOIN"
	}
	where := ""
	if filter != "" {
		where = "WHERE p." + filter
	}
	return `SELECT *,
			CASE WHEN deaths > 0 THEN round(kills::numeric / deaths, 2) ELSE kills END::float8 AS kd,
			` + rate("shots_hit_enemy", "shots", 1) + ` AS accuracy
		FROM (
			SELECT p.steam_id::text AS steam_id, p.name, ` + strings.Join(cols, ", ") + `,
			       COALESCE(t.rounds_played, 0) AS rounds_played, ` + streak + ` AS best_killstreak,
			       p.first_seen, p.last_seen
			FROM v_players p
			` + join + ` (` + playerTotals(w, args, filter) + `) t ON t.steam_id = p.steam_id
			` + where + `
		) x`
}

// minAccuracyShots is how many shots a player needs before sort=accuracy
// ranks them: below it a handful of lucky shots would top the board.
const minAccuracyShots = "500"

// playerSorts maps the /players sort values to ORDER BY clauses over
// PlayerStats columns, guarding against SQL injection via the query string.
var playerSorts = map[string]string{
	"score":          "score DESC NULLS LAST",
	"kills":          "kills DESC NULLS LAST",
	"deaths":         "deaths DESC NULLS LAST",
	"kd":             "kd DESC NULLS LAST",
	"assists":        "assists DESC NULLS LAST",
	"wins":           "wins DESC NULLS LAST",
	"play_time":      "play_seconds DESC NULLS LAST",
	"accuracy":       "(COALESCE(shots, 0) >= " + minAccuracyShots + ") DESC, " + ratio("shots_hit_enemy", "shots"),
	"revives":        "revives DESC NULLS LAST",
	"heals":          "heals DESC NULLS LAST",
	"caps":           "caps DESC NULLS LAST",
	"headshot_kills": "headshot_kills DESC NULLS LAST",
	"killstreak":     "best_killstreak DESC NULLS LAST",
	"last_seen":      "last_seen DESC NULLS LAST",
}

// ListPlayers returns a page of players ordered by sort (descending) and the
// total matching. A non-empty name keeps only players whose current name
// contains it, case-insensitively; LIKE wildcards in it are matched literally.
// With a window, only players with stats in it are listed, ranked by those.
func (s *Store) ListPlayers(ctx context.Context, w *Window, sort, name string, limit, offset int) ([]PlayerStats, int, error) {
	order, ok := playerSorts[sort]
	if !ok {
		order = playerSorts["score"]
	}
	var args []any
	from := playerQuery(w, &args, "", w != nil)
	if name != "" {
		from += ` WHERE name ILIKE ` + arg(&args, "%"+likeEscaper.Replace(name)+"%")
	}
	return page[PlayerStats](ctx, s, from, args, order+", steam_id", limit, offset)
}

// GetPlayer returns one player: lifetime stats, or with a window their stats
// in it (zeros if they didn't play then), and their name history. A player
// not in v_players is ErrNotFound.
func (s *Store) GetPlayer(ctx context.Context, w *Window, steamID int64) (*PlayerDetail, error) {
	args := []any{steamID}
	stats, err := one[PlayerStats](ctx, s, playerQuery(w, &args, "steam_id = $1", false), args...)
	if err != nil {
		return nil, err
	}
	// name_changes has a row at every connect too; keep only actual changes.
	names, err := all[NameChange](ctx, s, `
		SELECT name, changed_at FROM (
			SELECT name, changed_at, lag(name) OVER (ORDER BY changed_at) AS prev
			FROM name_changes WHERE steam_id = $1
		) n
		WHERE prev IS DISTINCT FROM name
		ORDER BY changed_at DESC`, steamID)
	if err != nil {
		return nil, err
	}
	return &PlayerDetail{PlayerStats: *stats, NameHistory: names, Window: w.info()}, nil
}

// playerWeaponColumns are the per player and weapon totals, named as in
// v_player_weapon_lifetime and v_player_round_weapon_stats.
var playerWeaponColumns = []string{
	"kills", "shots", "shots_hit_enemy", "shots_hit_friendly", "hits_head", "hits_chest",
	"hits_stomach", "hits_arms", "hits_legs", "damage_enemy", "damage_friendly", "reloads",
	"deploys", "seconds_drawn",
}

// weaponTotals is a query with one row per player and weapon: steam_id,
// weapon_name and every playerWeaponColumns column. For all time it reads
// v_player_weapon_lifetime; for a window it sums v_player_round_weapon_stats
// over `at` (NULL where only old rows, which lack the stat, are in it).
// filter, if not empty, is a condition on steam_id or weapon_name.
func weaponTotals(w *Window, args *[]any, filter string) string {
	cols := make([]string, len(playerWeaponColumns))
	if w == nil {
		for i, c := range playerWeaponColumns {
			cols[i] = c + "::bigint AS " + c
		}
		q := `SELECT steam_id, weapon_name, ` + strings.Join(cols, ", ") + ` FROM v_player_weapon_lifetime`
		if filter != "" {
			q += ` WHERE ` + filter
		}
		return q
	}
	in := w.bind(args)
	for i, c := range playerWeaponColumns {
		cols[i] = "sum(" + c + ")::bigint AS " + c
	}
	q := `SELECT steam_id, weapon_name, ` + strings.Join(cols, ", ") + `
		FROM v_player_round_weapon_stats WHERE ` + in("at")
	if filter != "" {
		q += ` AND ` + filter
	}
	return q + ` GROUP BY steam_id, weapon_name`
}

// GetPlayerWeapons returns a player's per-weapon breakdown, for all time or in
// a window, most kills first. Weapons with no kills, shots or time drawn are
// left out. It is a naturally bounded sub-resource, so it is not paginated.
func (s *Store) GetPlayerWeapons(ctx context.Context, w *Window, steamID int64) ([]PlayerWeapon, error) {
	args := []any{steamID}
	cols := make([]string, len(playerWeaponColumns))
	for i, c := range playerWeaponColumns {
		cols[i] = "t." + c
	}
	query := `SELECT t.weapon_name, wt.weapon_type, ` + strings.Join(cols, ", ") + `,
			` + rate("t.shots_hit_enemy", "t.shots", 1) + ` AS accuracy
		FROM (` + weaponTotals(w, &args, "steam_id = $1") + `) t
		LEFT JOIN weapons wt ON wt.weapon_name = t.weapon_name
		WHERE t.kills <> 0 OR t.shots <> 0 OR COALESCE(t.seconds_drawn, 0) <> 0
		ORDER BY t.kills DESC, t.shots DESC, t.weapon_name`
	return all[PlayerWeapon](ctx, s, query, args...)
}

// GetPlayerClasses returns a player's time, enemy kills and deaths per class
// template (v2 only). Time is summed from player_spans; a kill or death counts
// for the class of the player's span open at that moment, found the way
// v_kills finds a player's team. With a window, spans are filtered on their
// start and kills on their time.
func (s *Store) GetPlayerClasses(ctx context.Context, w *Window, steamID int64) ([]PlayerClass, error) {
	args := []any{steamID}
	spanFilter, killFilter := "", ""
	if w != nil {
		in := w.bind(&args)
		spanFilter = " AND " + in("started_at")
		killFilter = " AND " + in("k.killed_at")
	}
	query := `
		SELECT class_template, sum(seconds)::bigint AS seconds, sum(kills)::bigint AS kills,
		       sum(deaths)::bigint AS deaths
		FROM (
			SELECT class_template, extract(epoch FROM ended_at - started_at) AS seconds, 0 AS kills, 0 AS deaths
			FROM player_spans WHERE steam_id = $1` + spanFilter + `
			UNION ALL
			SELECT s.class_template, 0,
			       (k.attacker_steam_id = $1 AND k.kind = 'enemy')::int,
			       (k.victim_steam_id = $1)::int
			FROM v_kills k
			LEFT JOIN LATERAL (
				SELECT ps.class_template FROM player_spans ps
				WHERE ps.round_id = k.round_id AND ps.steam_id = $1 AND ps.started_at <= k.killed_at
				ORDER BY ps.started_at DESC LIMIT 1) s ON true
			WHERE (k.attacker_steam_id = $1 OR k.victim_steam_id = $1)` + killFilter + `
		) x
		GROUP BY class_template
		HAVING sum(seconds) > 0 OR sum(kills) > 0 OR sum(deaths) > 0
		ORDER BY seconds DESC, kills DESC, class_template`
	return all[PlayerClass](ctx, s, query, args...)
}

// GetPlayerRounds returns a page of a player's v_player_round_stats rows,
// newest first, with each v2 round's map and result. Old (pre-v2) rows have
// no round and NULL for what they did not record.
func (s *Store) GetPlayerRounds(ctx context.Context, w *Window, steamID int64, limit, offset int) ([]PlayerRound, int, error) {
	args := []any{steamID}
	filter := ""
	if w != nil {
		filter = " AND " + w.bind(&args)("s.at")
	}
	cols := []string{"kills", "deaths", "suicides", "world_deaths", "team_kills", "team_killed",
		"assists", "headshot_kills", "headshot_hits", "caps", "cache_kills", "score", "wins", "losses",
		"play_seconds", "medic_seconds", "revives", "times_revived", "heals", "hp_healed",
		"fire_support_calls", "suppressions", "times_suppressed", "shots", "shots_hit_enemy",
		"shots_hit_friendly", "damage_enemy", "damage_taken"}
	for i, c := range cols {
		cols[i] = "s." + c + "::bigint AS " + c
	}
	from := `
		SELECT s.round_id, s.source, s.at, r.map_name, r.game_mode, r.ended_at,
		       r.winner::text AS winner, r.end_reason::text AS end_reason,
		       CASE WHEN s.round_id IS NOT NULL THEN r.mvp_steam_id IS NOT DISTINCT FROM s.steam_id END AS was_mvp,
		       ` + strings.Join(cols, ", ") + `
		FROM v_player_round_stats s
		LEFT JOIN v_rounds r ON r.round_id = s.round_id
		WHERE s.steam_id = $1` + filter
	return page[PlayerRound](ctx, s, from, args, "at DESC, round_id DESC NULLS LAST, source", limit, offset)
}
