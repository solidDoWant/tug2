package main

import (
	"context"
	"errors"
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

// validSortColumns maps the sort values accepted on the API to SQL expressions,
// guarding against SQL injection via the query string.
var validSortColumns = map[string]string{
	"kills":      "kills",
	"deaths":     "deaths",
	"score":      "score",
	"wins":       "wins",
	"killstreak": "killstreak",
	"caps":       "caps",
	"play_time":  "play_time_seconds",
	"updated_at": "updated_at",
	"kd":         "(CASE WHEN deaths > 0 THEN kills::numeric / deaths ELSE kills END)",
}

// ListPlayers returns a page of players ordered by the given column (descending)
// along with the total number of matching players. A non-empty name keeps only
// players whose recorded name contains it, case-insensitively; LIKE wildcards
// in it are matched literally.
func (s *Store) ListPlayers(ctx context.Context, sort, name string, limit, offset int) ([]PlayerStats, int, error) {
	column, ok := validSortColumns[sort]
	if !ok {
		column = "score"
	}

	// $3 is NULL when no name filter is given, which matches every row.
	var pattern *string
	if name != "" {
		p := "%" + likeEscaper.Replace(name) + "%"
		pattern = &p
	}

	// #nosec G201 -- column is whitelisted via validSortColumns above.
	query := `
		SELECT steam_id, name, kills, deaths, suicides, headshot_given, headshot_taken,
		       suppressions, caps, killstreak, score, wins, losses, play_time_seconds, created_at, updated_at
		FROM player_stats
		WHERE $3::text IS NULL OR name ILIKE $3
		ORDER BY ` + column + ` DESC, steam_id
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset, pattern)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	players, err := scanPlayers(rows)
	if err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(*) FROM player_stats WHERE $1::text IS NULL OR name ILIKE $1`, pattern)
	if err != nil {
		return nil, 0, err
	}

	return players, total, nil
}

// likeEscaper escapes the LIKE metacharacters (with the default backslash
// escape) so user input is matched literally inside a %...% pattern.
var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// GetPlayer returns a single player by Steam ID.
func (s *Store) GetPlayer(ctx context.Context, steamID string) (*PlayerStats, error) {
	query := `
		SELECT steam_id, name, kills, deaths, suicides, headshot_given, headshot_taken,
		       suppressions, caps, killstreak, score, wins, losses, play_time_seconds, created_at, updated_at
		FROM player_stats
		WHERE steam_id = $1`

	rows, err := s.pool.Query(ctx, query, steamID)
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

// GetPlayerWeapons returns the per-weapon kill breakdown for a single player.
// It is a naturally bounded sub-resource, so it is not paginated.
func (s *Store) GetPlayerWeapons(ctx context.Context, steamID string) ([]WeaponKills, error) {
	query := `
		SELECT w.weapon_name, pk.kill_count
		FROM player_kills pk
		JOIN weapon_stats w ON w.weapon_id = pk.weapon_id
		WHERE pk.steam_id = $1
		ORDER BY pk.kill_count DESC`

	rows, err := s.pool.Query(ctx, query, steamID)
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

// ListWeapons returns a page of weapons aggregated across all players, plus the
// total number of distinct weapons with kills.
func (s *Store) ListWeapons(ctx context.Context, limit, offset int) ([]WeaponTotals, int, error) {
	query := `
		SELECT w.weapon_name, SUM(pk.kill_count) AS total_kills,
		       COUNT(DISTINCT pk.steam_id) AS unique_players
		FROM player_kills pk
		JOIN weapon_stats w ON w.weapon_id = pk.weapon_id
		GROUP BY w.weapon_name
		ORDER BY total_kills DESC
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	weapons := []WeaponTotals{}
	for rows.Next() {
		var weapon WeaponTotals
		if err := rows.Scan(&weapon.WeaponName, &weapon.TotalKills, &weapon.UniquePlayers); err != nil {
			return nil, 0, err
		}
		weapons = append(weapons, weapon)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(DISTINCT weapon_id) FROM player_kills`)
	if err != nil {
		return nil, 0, err
	}

	return weapons, total, nil
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

// ListMedics returns a page of medics ranked by time spent as medic, plus the
// total number of (non-banned) medics. Data comes from the gg2_medic_tracker
// schema. Banned medics are excluded from the leaderboard.
func (s *Store) ListMedics(ctx context.Context, limit, offset int) ([]MedicStats, int, error) {
	query := `
		SELECT m.steamId, ps.name, m.medic_time
		FROM medics m
		LEFT JOIN player_stats ps ON ps.steam_id = m.steamId
		WHERE m.banned = FALSE
		ORDER BY m.medic_time DESC, m.steamId
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	medics := []MedicStats{}
	for rows.Next() {
		var medic MedicStats
		if err := rows.Scan(&medic.SteamID, &medic.Name, &medic.MedicTime); err != nil {
			return nil, 0, err
		}
		medics = append(medics, medic)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(*) FROM medics WHERE banned = FALSE`)
	if err != nil {
		return nil, 0, err
	}

	return medics, total, nil
}

// ListTeamKills returns a page of players ranked by team kills given, plus the
// total number of tracked players. The teamkill counts come from the
// gg2_teamkill schema.
//
// Total kills are joined in from player_stats (the gg2_mstats2 schema). This
// used to read player_tks.kills, which nothing ever wrote, so it was always 0
// and this endpoint reported every player as having no kills; that column has
// since been removed. The join is a LEFT JOIN so a player with a teamkill
// record but no stats row still appears, with 0 kills.
//
// TKForgiven counts the player's forgiven entries in player_tk_logs (where they
// are the attacker); a player with no log rows gets 0.
//
// player_tks.steam_id is a BIGINT; it is cast to text because a SteamID64
// exceeds JavaScript's safe-integer range and would lose precision as a JSON
// number. That cast is also what joins it to player_stats.steam_id, which is
// text.
func (s *Store) ListTeamKills(ctx context.Context, limit, offset int) ([]TeamKillStats, int, error) {
	query := `
		SELECT pt.steam_id::text, ps.name, COALESCE(ps.kills, 0), pt.tk_given, pt.tk_taken,
		       COALESCE(f.forgiven, 0), pt.last_seen
		FROM player_tks pt
		LEFT JOIN player_stats ps ON ps.steam_id = pt.steam_id::text
		LEFT JOIN (
			SELECT attacker_steam_id, COUNT(*) FILTER (WHERE forgiven) AS forgiven
			FROM player_tk_logs
			GROUP BY attacker_steam_id
		) f ON f.attacker_steam_id = pt.steam_id
		ORDER BY pt.tk_given DESC
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
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
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(*) FROM player_tks`)
	if err != nil {
		return nil, 0, err
	}

	return teamKills, total, nil
}

// ListTeamKillWeapons returns a page of weapons ranked by logged team kills,
// with how many of those were forgiven, plus the total number of distinct
// weapons. It aggregates player_tk_logs (gg2_teamkill) and deliberately exposes
// no attacker/victim pairs. A NULL or empty weapon is reported as "unknown".
func (s *Store) ListTeamKillWeapons(ctx context.Context, limit, offset int) ([]TeamKillWeaponStats, int, error) {
	query := `
		SELECT COALESCE(NULLIF(weapon, ''), 'unknown') AS weapon_name,
		       COUNT(*) AS team_kills,
		       COUNT(*) FILTER (WHERE forgiven) AS forgiven
		FROM player_tk_logs
		GROUP BY weapon_name
		ORDER BY team_kills DESC, weapon_name
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
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
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(DISTINCT COALESCE(NULLIF(weapon, ''), 'unknown')) FROM player_tk_logs`)
	if err != nil {
		return nil, 0, err
	}

	return weapons, total, nil
}

// ListFireSupport returns a page of players ranked by fire-support calls, plus
// the total number of players who have called it. Data comes from the
// FireSupport plugin's fire_support table, whose last_used is a Unix timestamp
// (0 when unset, reported as null).
func (s *Store) ListFireSupport(ctx context.Context, limit, offset int) ([]FireSupportStats, int, error) {
	query := `
		SELECT fs.steamId, ps.name, fs.arty_thrown,
		       CASE WHEN fs.last_used > 0 THEN to_timestamp(fs.last_used) END
		FROM fire_support fs
		LEFT JOIN player_stats ps ON ps.steam_id = fs.steamId
		WHERE fs.arty_thrown > 0
		ORDER BY fs.arty_thrown DESC, fs.steamId
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
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
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(*) FROM fire_support WHERE arty_thrown > 0`)
	if err != nil {
		return nil, 0, err
	}

	return players, total, nil
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
			&player.Losses, &player.PlayTimeSeconds, &player.CreatedAt, &player.UpdatedAt,
		); err != nil {
			return nil, err
		}
		players = append(players, player)
	}

	return players, rows.Err()
}
