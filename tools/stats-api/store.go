package main

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrNotFound is returned by the store when a requested record does not exist.
var ErrNotFound = errors.New("not found")

// Store wraps the database connection pool and exposes read-only queries
// against the insurgency-stats database (gg2_mstats2 and sibling plugin tables).
type Store struct {
	pool *pgxpool.Pool
}

// NewStore connects to PostgreSQL and verifies the connection is reachable.
//
// databaseURL is passed straight to pgx, which understands both connection
// strings and — when the string is empty — the standard libpq environment
// variables. That means host, credentials, TLS mode (including verify-full and
// mutual TLS), and pool sizing (pool_max_conns) are all configured through pgx's
// native inputs rather than anything bespoke here. That includes
// statement_timeout, which can be set as a connection-string parameter
// (DATABASE_URL=...?statement_timeout=5000, in milliseconds) or via
// PGOPTIONS=-c statement_timeout=5000 — pgx forwards both as session startup
// parameters.
//
// The config is parsed explicitly (rather than via pgxpool.New) so enableTLSReload
// can rewire the TLS handshake to reload certificates from disk: pgx otherwise
// reads sslrootcert/sslcert/sslkey once and reuses them for the pool's lifetime,
// which means a cert-manager/CNPG-style rotation is invisible until a restart.
func NewStore(ctx context.Context, databaseURL string) (*Store, error) {
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, err
	}

	enableTLSReload(&config.ConnConfig.Config, databaseURL)

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, err
	}

	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}

	return &Store{pool: pool}, nil
}

// Close releases the underlying connection pool.
func (s *Store) Close() {
	s.pool.Close()
}

// Ping checks database connectivity, used by the readiness probe.
func (s *Store) Ping(ctx context.Context) error {
	return s.pool.Ping(ctx)
}

// Stat returns a snapshot of the connection-pool statistics, read lazily by the
// metrics collector at scrape time. Returning the pgxpool snapshot rather than
// the pool itself keeps the pool encapsulated in the store.
func (s *Store) Stat() *pgxpool.Stat {
	return s.pool.Stat()
}

// count runs a scalar COUNT query so list endpoints can report a total
// alongside the current page.
func (s *Store) count(ctx context.Context, query string, args ...any) (int, error) {
	var total int
	if err := s.pool.QueryRow(ctx, query, args...).Scan(&total); err != nil {
		return 0, err
	}
	return total, nil
}

// playerShotTotals sums each player's player_shots rows over their weapons.
const playerShotTotals = `(SELECT steam_id, SUM(shots) AS shots, SUM(enemy_hits) AS enemy_hits,
		SUM(friendly_hits) AS friendly_hits FROM player_shots GROUP BY steam_id)`

// minAccuracyShots is how many shots a player needs before sort=accuracy
// ranks them: below it a handful of lucky shots would top the board.
const minAccuracyShots = "500"

// hitRateSQL is hits / shots as a percentage to one decimal place, or NULL
// with no shots.
func hitRateSQL(hits, shots string) string {
	return "CASE WHEN " + shots + " > 0 THEN round(100.0 * " + hits + " / " + shots + ", 1)::float8 END"
}

// validSortColumns maps the sort values accepted on the API to SQL expressions
// over playerSource's columns, guarding against SQL injection via the query
// string.
var validSortColumns = map[string]string{
	"kills":      "kills",
	"deaths":     "deaths",
	"score":      "score",
	"wins":       "wins",
	"killstreak": "killstreak",
	"caps":       "caps",
	"play_time":  "play_time_seconds",
	"accuracy":   "COALESCE(CASE WHEN shots >= " + minAccuracyShots + " THEN enemy_hits::numeric / shots END, -1)",
	"updated_at": "updated_at",
	"kd":         "(CASE WHEN deaths > 0 THEN kills::numeric / deaths ELSE kills END)",
}

// playerSource is a query with one row per player and the PlayerStats
// columns, plus "active": whether the player has stats in the window (always
// true for all time). For all time it reads the lifetime totals; for a window
// it sums the player's player_rounds rows in it (killstreak is the best in
// it), giving zeros to players with none. name, created_at and updated_at
// always come from player_stats.
func playerSource(w *Window, args *[]any) string {
	if w == nil {
		return `
		SELECT p.steam_id, p.name, p.kills, p.deaths, p.suicides, p.headshot_given, p.headshot_taken,
		       p.suppressions, p.caps, p.killstreak, p.score, p.wins, p.losses, p.play_time_seconds,
		       COALESCE(sh.shots, 0) AS shots, COALESCE(sh.enemy_hits, 0) AS enemy_hits,
		       COALESCE(sh.friendly_hits, 0) AS friendly_hits, p.created_at, p.updated_at, TRUE AS active
		FROM player_stats p
		LEFT JOIN ` + playerShotTotals + ` sh USING (steam_id)`
	}
	in := w.bind(args)
	return `
		SELECT p.steam_id, p.name, COALESCE(r.kills, 0) AS kills, COALESCE(r.deaths, 0) AS deaths,
		       COALESCE(r.suicides, 0) AS suicides, COALESCE(r.headshot_given, 0) AS headshot_given,
		       COALESCE(r.headshot_taken, 0) AS headshot_taken, COALESCE(r.suppressions, 0) AS suppressions,
		       COALESCE(r.caps, 0) AS caps, COALESCE(r.killstreak, 0) AS killstreak, COALESCE(r.score, 0) AS score,
		       COALESCE(r.wins, 0) AS wins, COALESCE(r.losses, 0) AS losses,
		       COALESCE(r.play_time_seconds, 0) AS play_time_seconds, COALESCE(r.shots, 0) AS shots,
		       COALESCE(r.enemy_hits, 0) AS enemy_hits, COALESCE(r.friendly_hits, 0) AS friendly_hits,
		       p.created_at, p.updated_at, r.steam_id IS NOT NULL AS active
		FROM player_stats p
		LEFT JOIN (
			SELECT steam_id, SUM(kills) AS kills, SUM(deaths) AS deaths, SUM(suicides) AS suicides,
			       SUM(headshot_given) AS headshot_given, SUM(headshot_taken) AS headshot_taken,
			       SUM(suppressions) AS suppressions, SUM(caps) AS caps, MAX(killstreak) AS killstreak,
			       SUM(score) AS score, SUM(wins) AS wins, SUM(losses) AS losses,
			       SUM(play_time_seconds) AS play_time_seconds, SUM(shots) AS shots,
			       SUM(enemy_hits) AS enemy_hits, SUM(friendly_hits) AS friendly_hits
			FROM player_rounds
			WHERE ` + in("recorded_at") + `
			GROUP BY steam_id
		) r USING (steam_id)`
}

// playerColumns selects PlayerStats from a playerSource, in scanPlayers order.
const playerColumns = `steam_id, name, kills, deaths, suicides, headshot_given, headshot_taken,
		suppressions, caps, killstreak, score, wins, losses, play_time_seconds,
		shots, enemy_hits, friendly_hits, ` + "" + `CASE WHEN shots > 0 THEN round(100.0 * enemy_hits / shots, 1)::float8 END,
		created_at, updated_at`

// ListPlayers returns a page of players ordered by the given column (descending)
// along with the total number of matching players. A non-empty name keeps only
// players whose recorded name contains it, case-insensitively; LIKE wildcards
// in it are matched literally. With a window, only players with stats in it
// are listed, ranked by those.
func (s *Store) ListPlayers(ctx context.Context, w *Window, sort, name string, limit, offset int) ([]PlayerStats, int, error) {
	column, ok := validSortColumns[sort]
	if !ok {
		column = "score"
	}

	// $1 is NULL when no name filter is given, which matches every row.
	var pattern *string
	if name != "" {
		p := "%" + likeEscaper.Replace(name) + "%"
		pattern = &p
	}

	args := []any{pattern}
	source := `WITH src AS (` + playerSource(w, &args) + `)`
	filter := `WHERE active AND ($1::text IS NULL OR name ILIKE $1)`

	total, err := s.count(ctx, source+` SELECT COUNT(*) FROM src `+filter, args...)
	if err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	// #nosec G201 -- column is whitelisted via validSortColumns above.
	query := source + `
		SELECT ` + playerColumns + `
		FROM src ` + filter + `
		ORDER BY ` + column + ` DESC, steam_id
		LIMIT $` + strconv.Itoa(len(args)-1) + ` OFFSET $` + strconv.Itoa(len(args))

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	players, err := scanPlayers(rows)
	if err != nil {
		return nil, 0, err
	}
	return players, total, nil
}

// likeEscaper escapes the LIKE metacharacters (with the default backslash
// escape) so user input is matched literally inside a %...% pattern.
var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// GetPlayer returns a single player by Steam ID: lifetime stats, or with a
// window their stats in it (zeros if they didn't play then).
func (s *Store) GetPlayer(ctx context.Context, w *Window, steamID string) (*PlayerStats, error) {
	args := []any{steamID}
	query := `WITH src AS (` + playerSource(w, &args) + `)
		SELECT ` + playerColumns + ` FROM src WHERE steam_id = $1`

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	players, err := scanPlayers(rows)
	if err != nil {
		return nil, err
	}
	if len(players) == 0 {
		return nil, ErrNotFound
	}

	return &players[0], nil
}

// GetPlayerWeapons returns the per-weapon breakdown for a single player: kills,
// and rounds fired and hit, for all time or in a window. It is a naturally
// bounded sub-resource, so it is not paginated.
func (s *Store) GetPlayerWeapons(ctx context.Context, w *Window, steamID string) ([]PlayerWeapon, error) {
	args := []any{steamID}
	source := `
		SELECT weapon_id, COALESCE(pk.kill_count, 0) AS kills, COALESCE(ps.shots, 0) AS shots,
		       COALESCE(ps.enemy_hits, 0) AS enemy_hits, COALESCE(ps.friendly_hits, 0) AS friendly_hits
		FROM (SELECT weapon_id, kill_count FROM player_kills WHERE steam_id = $1) pk
		FULL JOIN (SELECT weapon_id, shots, enemy_hits, friendly_hits FROM player_shots WHERE steam_id = $1) ps
		     USING (weapon_id)`
	if w != nil {
		in := w.bind(&args)
		source = `
		SELECT prw.weapon_id, SUM(prw.kills) AS kills, SUM(prw.shots) AS shots,
		       SUM(prw.enemy_hits) AS enemy_hits, SUM(prw.friendly_hits) AS friendly_hits
		FROM player_round_weapons prw
		JOIN player_rounds r ON r.id = prw.round_id
		WHERE r.steam_id = $1 AND ` + in("r.recorded_at") + `
		GROUP BY prw.weapon_id`
	}
	query := `WITH src AS (` + source + `)
		SELECT w.weapon_name, src.kills, src.shots, src.enemy_hits, src.friendly_hits,
		       ` + hitRateSQL("src.enemy_hits", "src.shots") + `
		FROM src JOIN weapon_stats w USING (weapon_id)
		ORDER BY src.kills DESC, src.shots DESC, w.weapon_name`

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	weapons := []PlayerWeapon{}
	for rows.Next() {
		var weapon PlayerWeapon
		if err := rows.Scan(&weapon.WeaponName, &weapon.KillCount, &weapon.Shots,
			&weapon.EnemyHits, &weapon.FriendlyHits, &weapon.EnemyHitRate); err != nil {
			return nil, err
		}
		weapons = append(weapons, weapon)
	}

	return weapons, rows.Err()
}

// validWeaponSortColumns maps the sort values accepted on /weapons to output
// column aliases of the ListWeapons query, guarding against SQL injection.
var validWeaponSortColumns = map[string]string{
	"kills":    "total_kills",
	"shots":    "total_shots",
	"accuracy": "COALESCE(CASE WHEN total_shots >= " + minWeaponAccuracyShots + " THEN enemy_hits::numeric / total_shots END, -1)",
}

// minWeaponAccuracyShots is how many shots, across all players, a weapon needs
// before sort=accuracy ranks it.
const minWeaponAccuracyShots = "1000"

// ListWeapons returns a page of weapons with their totals across all players,
// for all time or in a window: kills (player_kills), rounds fired and hit
// (player_shots), or for a window the same from player_round_weapons. A weapon
// with any of them appears.
func (s *Store) ListWeapons(ctx context.Context, w *Window, sort string, limit, offset int) ([]WeaponTotals, int, error) {
	column, ok := validWeaponSortColumns[sort]
	if !ok {
		column = "total_kills"
	}

	var args []any
	totals := `
		WITH kills AS (
			SELECT weapon_id, SUM(kill_count) AS total_kills, COUNT(DISTINCT steam_id) AS unique_players
			FROM player_kills GROUP BY weapon_id
		), shots AS (
			SELECT weapon_id, SUM(shots) AS total_shots, SUM(enemy_hits) AS enemy_hits,
			       SUM(friendly_hits) AS friendly_hits
			FROM player_shots GROUP BY weapon_id
		), totals AS (
			SELECT w.weapon_name, COALESCE(k.total_kills, 0) AS total_kills,
			       COALESCE(k.unique_players, 0) AS unique_players,
			       COALESCE(sh.total_shots, 0) AS total_shots, COALESCE(sh.enemy_hits, 0) AS enemy_hits,
			       COALESCE(sh.friendly_hits, 0) AS friendly_hits
			FROM kills k
			FULL JOIN shots sh USING (weapon_id)
			JOIN weapon_stats w USING (weapon_id)
		)`
	if w != nil {
		in := w.bind(&args)
		totals = `
		WITH totals AS (
			SELECT w.weapon_name, SUM(prw.kills) AS total_kills,
			       COUNT(DISTINCT r.steam_id) FILTER (WHERE prw.kills > 0) AS unique_players,
			       SUM(prw.shots) AS total_shots, SUM(prw.enemy_hits) AS enemy_hits,
			       SUM(prw.friendly_hits) AS friendly_hits
			FROM player_round_weapons prw
			JOIN player_rounds r ON r.id = prw.round_id
			JOIN weapon_stats w ON w.weapon_id = prw.weapon_id
			WHERE ` + in("r.recorded_at") + `
			GROUP BY w.weapon_name
		)`
	}

	total, err := s.count(ctx, totals+` SELECT COUNT(*) FROM totals`, args...)
	if err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	// #nosec G201 -- column is whitelisted via validWeaponSortColumns above.
	query := totals + `
		SELECT weapon_name, total_kills, unique_players, total_shots, enemy_hits, friendly_hits,
		       ` + hitRateSQL("enemy_hits", "total_shots") + `
		FROM totals
		ORDER BY ` + column + ` DESC, weapon_name
		LIMIT $` + strconv.Itoa(len(args)-1) + ` OFFSET $` + strconv.Itoa(len(args))

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	weapons := []WeaponTotals{}
	for rows.Next() {
		var weapon WeaponTotals
		if err := rows.Scan(&weapon.WeaponName, &weapon.TotalKills, &weapon.UniquePlayers,
			&weapon.TotalShots, &weapon.EnemyHits, &weapon.FriendlyHits, &weapon.EnemyHitRate); err != nil {
			return nil, 0, err
		}
		weapons = append(weapons, weapon)
	}
	return weapons, total, rows.Err()
}

// GetWeaponAccuracy ranks the players with at least minShots recorded shots
// with one weapon, for all time or in a window, by enemy hit rate. An unknown
// weapon is ErrNotFound; a known one nobody qualifies for is an empty page.
func (s *Store) GetWeaponAccuracy(ctx context.Context, w *Window, weaponName string, minShots, limit, offset int) ([]WeaponAccuracy, int, error) {
	var weaponID int
	err := s.pool.QueryRow(ctx, `SELECT weapon_id FROM weapon_stats WHERE weapon_name = $1`, weaponName).Scan(&weaponID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, 0, ErrNotFound
	}
	if err != nil {
		return nil, 0, err
	}

	args := []any{weaponID, minShots}
	source := `SELECT steam_id, shots, enemy_hits, friendly_hits FROM player_shots WHERE weapon_id = $1`
	if w != nil {
		in := w.bind(&args)
		source = `
		SELECT r.steam_id, SUM(prw.shots) AS shots, SUM(prw.enemy_hits) AS enemy_hits,
		       SUM(prw.friendly_hits) AS friendly_hits
		FROM player_round_weapons prw
		JOIN player_rounds r ON r.id = prw.round_id
		WHERE prw.weapon_id = $1 AND ` + in("r.recorded_at") + `
		GROUP BY r.steam_id`
	}
	source = `WITH ps AS (` + source + `)`

	total, err := s.count(ctx, source+` SELECT COUNT(*) FROM ps WHERE shots >= $2`, args...)
	if err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	rows, err := s.pool.Query(ctx, source+`
		SELECT ps.steam_id, p.name, ps.shots, ps.enemy_hits, ps.friendly_hits,
		       round(100.0 * ps.enemy_hits / ps.shots, 1)::float8
		FROM ps
		LEFT JOIN player_stats p USING (steam_id)
		WHERE ps.shots >= $2
		ORDER BY ps.enemy_hits::numeric / ps.shots DESC, ps.shots DESC, ps.steam_id
		LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	players := []WeaponAccuracy{}
	for rows.Next() {
		var a WeaponAccuracy
		if err := rows.Scan(&a.SteamID, &a.Name, &a.Shots, &a.EnemyHits, &a.FriendlyHits, &a.EnemyHitRate); err != nil {
			return nil, 0, err
		}
		players = append(players, a)
	}
	return players, total, rows.Err()
}

// validMapSortColumns maps the sort values accepted on /maps to output column
// aliases of the ListMaps query, guarding against SQL injection.
var validMapSortColumns = map[string]string{
	"rounds":      "total_rounds",
	"play_time":   "play_time_seconds",
	"last_played": "last_played_at",
}

// ListMaps returns a page of per-map summaries plus the total number of maps
// known to either source.
//
// Win/loss counts come from gg2_mstats2 (win_loss_log keyed by map_stats) and
// playtime from map_logger (maps). Both plugins key maps by GetCurrentMap(), so
// the names join directly. It is a FULL OUTER JOIN because each source can hold
// maps the other lacks: map_logger records a map at map start, before any round
// result exists, and win_loss_log predates map_logger on older data.
func (s *Store) ListMaps(ctx context.Context, sort string, limit, offset int) ([]MapStats, int, error) {
	column, ok := validMapSortColumns[sort]
	if !ok {
		column = "total_rounds"
	}

	// #nosec G201 -- column is whitelisted via validMapSortColumns above.
	query := `
		WITH rounds AS (
			SELECT m.map_name,
			       COUNT(*) FILTER (WHERE wll.win) AS wins,
			       COUNT(*) FILTER (WHERE NOT wll.win) AS losses,
			       COUNT(*) AS total_rounds
			FROM win_loss_log wll
			JOIN map_stats m ON m.map_id = wll.map_id
			GROUP BY m.map_name
		)
		SELECT COALESCE(r.map_name, mp.map_name) AS name,
		       COALESCE(r.wins, 0) AS wins,
		       COALESCE(r.losses, 0) AS losses,
		       COALESCE(r.total_rounds, 0) AS total_rounds,
		       ROUND(100.0 * r.wins / NULLIF(r.total_rounds, 0), 2) AS win_rate,
		       COALESCE(EXTRACT(EPOCH FROM mp.play_time), 0)::bigint AS play_time_seconds,
		       mp.last_start AS last_played_at
		FROM rounds r
		FULL OUTER JOIN maps mp ON mp.map_name = r.map_name
		ORDER BY ` + column + ` DESC NULLS LAST, name
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	maps := []MapStats{}
	for rows.Next() {
		var mapStats MapStats
		if err := rows.Scan(&mapStats.MapName, &mapStats.Wins, &mapStats.Losses,
			&mapStats.TotalRounds, &mapStats.WinRate, &mapStats.PlayTimeSeconds,
			&mapStats.LastPlayedAt); err != nil {
			return nil, 0, err
		}
		maps = append(maps, mapStats)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `
		SELECT COUNT(*) FROM (
			SELECT m.map_name FROM win_loss_log wll JOIN map_stats m ON m.map_id = wll.map_id
			UNION
			SELECT map_name FROM maps
		) AS known_maps`)
	if err != nil {
		return nil, 0, err
	}

	return maps, total, nil
}

// ListMatches returns a page of the most recent match results plus the total
// number of logged matches.
func (s *Store) ListMatches(ctx context.Context, limit, offset int) ([]MatchResult, int, error) {
	query := `
		SELECT m.map_name, wll.win, wll.created_at
		FROM win_loss_log wll
		JOIN map_stats m ON m.map_id = wll.map_id
		ORDER BY wll.created_at DESC
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	matches := []MatchResult{}
	for rows.Next() {
		var match MatchResult
		if err := rows.Scan(&match.MapName, &match.Win, &match.PlayedAt); err != nil {
			return nil, 0, err
		}
		matches = append(matches, match)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(*) FROM win_loss_log`)
	if err != nil {
		return nil, 0, err
	}

	return matches, total, nil
}

// ListBots returns a page of bots ranked by total kills, plus the total number
// of bots. Data comes from the bot_kills table in the gg2_mstats2 schema.
func (s *Store) ListBots(ctx context.Context, limit, offset int) ([]BotStats, int, error) {
	query := `
		SELECT bot_name, SUM(kill_count) AS total_kills
		FROM bot_kills
		GROUP BY bot_name
		ORDER BY total_kills DESC
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	bots := []BotStats{}
	for rows.Next() {
		var bot BotStats
		if err := rows.Scan(&bot.BotName, &bot.TotalKills); err != nil {
			return nil, 0, err
		}
		bots = append(bots, bot)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(DISTINCT bot_name) FROM bot_kills`)
	if err != nil {
		return nil, 0, err
	}

	return bots, total, nil
}

// GetBotWeapons returns the per-weapon kill breakdown for a single bot. Like
// GetPlayerWeapons it is a naturally bounded sub-resource, so it is not
// paginated, and an unknown bot yields an empty list rather than a 404.
func (s *Store) GetBotWeapons(ctx context.Context, botName string) ([]WeaponKills, error) {
	query := `
		SELECT w.weapon_name, bk.kill_count
		FROM bot_kills bk
		JOIN weapon_stats w ON w.weapon_id = bk.weapon_id
		WHERE bk.bot_name = $1
		ORDER BY bk.kill_count DESC, w.weapon_name`

	rows, err := s.pool.Query(ctx, query, botName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	weapons := []WeaponKills{}
	for rows.Next() {
		var weapon WeaponKills
		if err := rows.Scan(&weapon.WeaponName, &weapon.KillCount); err != nil {
			return nil, err
		}
		weapons = append(weapons, weapon)
	}

	return weapons, rows.Err()
}

// validMedicSortColumns maps the sort values accepted on /medics to columns
// of the ListMedics source.
var validMedicSortColumns = map[string]string{
	"time":    "medic_time",
	"heals":   "heals",
	"revives": "revives",
}

// ListMedics returns a page of players ranked by medic time (or heals or
// revives), for all time from medics or in a window from medic_rounds, plus
// how many players the board has. Banned medics are excluded.
func (s *Store) ListMedics(ctx context.Context, w *Window, sort string, limit, offset int) ([]MedicStats, int, error) {
	column, ok := validMedicSortColumns[sort]
	if !ok {
		column = "medic_time"
	}

	var args []any
	source := `SELECT steamId AS steam_id, medic_time, heals, revives FROM medics WHERE banned = FALSE`
	if w != nil {
		in := w.bind(&args)
		source = `
		SELECT mr.steam_id, SUM(mr.medic_time) AS medic_time, SUM(mr.heals) AS heals, SUM(mr.revives) AS revives
		FROM medic_rounds mr
		LEFT JOIN medics m ON m.steamId = mr.steam_id
		WHERE ` + in("mr.recorded_at") + ` AND m.banned IS NOT TRUE
		GROUP BY mr.steam_id`
	}
	source = `WITH src AS (` + source + `)`

	total, err := s.count(ctx, source+` SELECT COUNT(*) FROM src`, args...)
	if err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	// #nosec G201 -- column is whitelisted via validMedicSortColumns above.
	rows, err := s.pool.Query(ctx, source+`
		SELECT src.steam_id, ps.name, src.medic_time, src.heals, src.revives
		FROM src
		LEFT JOIN player_stats ps ON ps.steam_id = src.steam_id
		ORDER BY src.`+column+` DESC, src.steam_id
		LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	medics := []MedicStats{}
	for rows.Next() {
		var medic MedicStats
		if err := rows.Scan(&medic.SteamID, &medic.Name, &medic.MedicTime, &medic.Heals, &medic.Revives); err != nil {
			return nil, 0, err
		}
		medics = append(medics, medic)
	}
	return medics, total, rows.Err()
}

// ListTeamKills returns a page of players ranked by team kills given, plus the
// total number of players on the board.
//
// For all time the counts come from player_tks (the gg2_teamkill totals). For a
// window they are counted from player_tk_logs, which has one row per team kill
// with its time: given as the attacker, taken as the victim. Kills, for the
// kill/teamkill ratio, are from player_stats for all time and player_rounds for
// a window. The joins are LEFT JOINs so a player with team kills but no stats
// row still appears, with 0 kills.
//
// TKForgiven counts the player's forgiven entries in player_tk_logs (where they
// are the attacker); a player with no log rows gets 0.
//
// SteamIDs in the gg2_teamkill tables are BIGINTs; they are cast to text
// because a SteamID64 exceeds JavaScript's safe-integer range and would lose
// precision as a JSON number. That cast is also what joins them to
// player_stats.steam_id, which is text.
func (s *Store) ListTeamKills(ctx context.Context, w *Window, limit, offset int) ([]TeamKillStats, int, error) {
	var args []any
	source := `
		SELECT pt.steam_id, pt.tk_given, pt.tk_taken, COALESCE(f.forgiven, 0) AS forgiven,
		       COALESCE(ps.kills, 0) AS kills
		FROM player_tks pt
		LEFT JOIN player_stats ps ON ps.steam_id = pt.steam_id::text
		LEFT JOIN (
			SELECT attacker_steam_id, COUNT(*) FILTER (WHERE forgiven) AS forgiven
			FROM player_tk_logs
			GROUP BY attacker_steam_id
		) f ON f.attacker_steam_id = pt.steam_id`
	if w != nil {
		in := w.bind(&args)
		source = `
		SELECT COALESCE(g.steam_id, t.steam_id) AS steam_id, COALESCE(g.given, 0) AS tk_given,
		       COALESCE(t.taken, 0) AS tk_taken, COALESCE(g.forgiven, 0) AS forgiven, COALESCE(k.kills, 0) AS kills
		FROM (
			SELECT attacker_steam_id AS steam_id, COUNT(*) AS given, COUNT(*) FILTER (WHERE forgiven) AS forgiven
			FROM player_tk_logs WHERE ` + in("created_at") + ` GROUP BY attacker_steam_id
		) g
		FULL JOIN (
			SELECT victim_steam_id AS steam_id, COUNT(*) AS taken
			FROM player_tk_logs WHERE ` + in("created_at") + ` GROUP BY victim_steam_id
		) t ON t.steam_id = g.steam_id
		LEFT JOIN (
			SELECT steam_id, SUM(kills) AS kills
			FROM player_rounds WHERE ` + in("recorded_at") + ` GROUP BY steam_id
		) k ON k.steam_id = COALESCE(g.steam_id, t.steam_id)::text`
	}
	source = `WITH src AS (` + source + `)`

	total, err := s.count(ctx, source+` SELECT COUNT(*) FROM src`, args...)
	if err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	rows, err := s.pool.Query(ctx, source+`
		SELECT src.steam_id::text, ps.name, src.kills, src.tk_given, src.tk_taken, src.forgiven, pt.last_seen
		FROM src
		LEFT JOIN player_stats ps ON ps.steam_id = src.steam_id::text
		LEFT JOIN player_tks pt ON pt.steam_id = src.steam_id
		ORDER BY src.tk_given DESC, src.steam_id
		LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	teamKills := []TeamKillStats{}
	for rows.Next() {
		var tk TeamKillStats
		if err := rows.Scan(&tk.SteamID, &tk.Name, &tk.Kills, &tk.TKGiven, &tk.TKTaken, &tk.TKForgiven, &tk.LastSeen); err != nil {
			return nil, 0, err
		}
		teamKills = append(teamKills, tk)
	}
	return teamKills, total, rows.Err()
}

// ListTeamKillWeapons returns a page of weapons ranked by logged team kills,
// for all time or in a window, with how many of those were forgiven, plus the
// total number of distinct weapons. It aggregates player_tk_logs (gg2_teamkill)
// and deliberately exposes no attacker/victim pairs. A NULL or empty weapon is
// reported as "unknown".
func (s *Store) ListTeamKillWeapons(ctx context.Context, w *Window, limit, offset int) ([]TeamKillWeaponStats, int, error) {
	var args []any
	where := ""
	if w != nil {
		where = `WHERE ` + w.bind(&args)("created_at")
	}
	source := `WITH src AS (
		SELECT COALESCE(NULLIF(weapon, ''), 'unknown') AS weapon_name,
		       COUNT(*) AS team_kills,
		       COUNT(*) FILTER (WHERE forgiven) AS forgiven
		FROM player_tk_logs ` + where + `
		GROUP BY weapon_name)`

	total, err := s.count(ctx, source+` SELECT COUNT(*) FROM src`, args...)
	if err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	rows, err := s.pool.Query(ctx, source+`
		SELECT weapon_name, team_kills, forgiven FROM src
		ORDER BY team_kills DESC, weapon_name
		LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	weapons := []TeamKillWeaponStats{}
	for rows.Next() {
		var weapon TeamKillWeaponStats
		if err := rows.Scan(&weapon.Weapon, &weapon.TeamKills, &weapon.Forgiven); err != nil {
			return nil, 0, err
		}
		weapons = append(weapons, weapon)
	}
	return weapons, total, rows.Err()
}

// ListFireSupport returns a page of players ranked by fire-support calls, plus
// the total number of players who have called it. For all time the counts come
// from the FireSupport plugin's fire_support table, whose last_used is a Unix
// timestamp (0 when unset, reported as null); for a window they are counted
// from fire_support_calls, and LastUsedAt is the last call in the window.
func (s *Store) ListFireSupport(ctx context.Context, w *Window, limit, offset int) ([]FireSupportStats, int, error) {
	var args []any
	source := `
		SELECT steamId AS steam_id, arty_thrown,
		       CASE WHEN last_used > 0 THEN to_timestamp(last_used) END AS last_used_at
		FROM fire_support
		WHERE arty_thrown > 0`
	if w != nil {
		in := w.bind(&args)
		source = `
		SELECT steam_id, COUNT(*) AS arty_thrown, MAX(called_at) AT TIME ZONE 'UTC' AS last_used_at
		FROM fire_support_calls
		WHERE ` + in("called_at") + `
		GROUP BY steam_id`
	}
	source = `WITH src AS (` + source + `)`

	total, err := s.count(ctx, source+` SELECT COUNT(*) FROM src`, args...)
	if err != nil {
		return nil, 0, err
	}

	args = append(args, limit, offset)
	rows, err := s.pool.Query(ctx, source+`
		SELECT src.steam_id, ps.name, src.arty_thrown, src.last_used_at
		FROM src
		LEFT JOIN player_stats ps ON ps.steam_id = src.steam_id
		ORDER BY src.arty_thrown DESC, src.steam_id
		LIMIT $`+strconv.Itoa(len(args)-1)+` OFFSET $`+strconv.Itoa(len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	players := []FireSupportStats{}
	for rows.Next() {
		var player FireSupportStats
		if err := rows.Scan(&player.SteamID, &player.Name, &player.ArtyThrown, &player.LastUsedAt); err != nil {
			return nil, 0, err
		}
		players = append(players, player)
	}
	return players, total, rows.Err()
}

// scanPlayers reads a full set of player_stats rows into a slice.
func scanPlayers(rows pgx.Rows) ([]PlayerStats, error) {
	players := []PlayerStats{}
	for rows.Next() {
		var player PlayerStats
		if err := rows.Scan(
			&player.SteamID, &player.Name, &player.Kills, &player.Deaths, &player.Suicides,
			&player.HeadshotGiven, &player.HeadshotTaken, &player.Suppressions,
			&player.Caps, &player.Killstreak, &player.Score, &player.Wins,
			&player.Losses, &player.PlayTimeSeconds, &player.Shots, &player.EnemyHits,
			&player.FriendlyHits, &player.EnemyHitRate, &player.CreatedAt, &player.UpdatedAt,
		); err != nil {
			return nil, err
		}
		players = append(players, player)
	}

	return players, rows.Err()
}
