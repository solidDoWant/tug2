package main

import (
	"context"
	"errors"

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
// native inputs rather than anything bespoke here.
func NewStore(ctx context.Context, databaseURL string) (*Store, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
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
	"updated_at": "updated_at",
	"kd":         "(CASE WHEN deaths > 0 THEN kills::numeric / deaths ELSE kills END)",
}

// ListPlayers returns a page of players ordered by the given column (descending)
// along with the total number of players.
func (s *Store) ListPlayers(ctx context.Context, sort string, limit, offset int) ([]PlayerStats, int, error) {
	column, ok := validSortColumns[sort]
	if !ok {
		column = "score"
	}

	// #nosec G201 -- column is whitelisted via validSortColumns above.
	query := `
		SELECT steam_id, kills, deaths, suicides, headshot_given, headshot_taken,
		       suppressions, caps, killstreak, score, wins, losses, created_at, updated_at
		FROM player_stats
		ORDER BY ` + column + ` DESC
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	players, err := scanPlayers(rows)
	if err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(*) FROM player_stats`)
	if err != nil {
		return nil, 0, err
	}

	return players, total, nil
}

// GetPlayer returns a single player by Steam ID.
func (s *Store) GetPlayer(ctx context.Context, steamID string) (*PlayerStats, error) {
	query := `
		SELECT steam_id, kills, deaths, suicides, headshot_given, headshot_taken,
		       suppressions, caps, killstreak, score, wins, losses, created_at, updated_at
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

// ListMaps returns a page of per-map win/loss summaries plus the total number of
// maps with recorded rounds.
func (s *Store) ListMaps(ctx context.Context, limit, offset int) ([]MapStats, int, error) {
	query := `
		SELECT m.map_name,
		       COUNT(*) FILTER (WHERE wll.win) AS wins,
		       COUNT(*) FILTER (WHERE NOT wll.win) AS losses,
		       COUNT(*) AS total_rounds,
		       ROUND(100.0 * COUNT(*) FILTER (WHERE wll.win) / NULLIF(COUNT(*), 0), 2) AS win_rate
		FROM win_loss_log wll
		JOIN map_stats m ON m.map_id = wll.map_id
		GROUP BY m.map_name
		ORDER BY total_rounds DESC
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
			&mapStats.TotalRounds, &mapStats.WinRate); err != nil {
			return nil, 0, err
		}
		maps = append(maps, mapStats)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	total, err := s.count(ctx, `SELECT COUNT(DISTINCT map_id) FROM win_loss_log`)
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

// ListMedics returns a page of medics ranked by time spent as medic, plus the
// total number of (non-banned) medics. Data comes from the gg2_medic_tracker
// schema. Banned medics are excluded from the leaderboard.
func (s *Store) ListMedics(ctx context.Context, limit, offset int) ([]MedicStats, int, error) {
	query := `
		SELECT steamId, medic_time
		FROM medics
		WHERE banned = FALSE
		ORDER BY medic_time DESC
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	medics := []MedicStats{}
	for rows.Next() {
		var medic MedicStats
		if err := rows.Scan(&medic.SteamID, &medic.MedicTime); err != nil {
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
// total number of tracked players. Data comes from the gg2_teamkill schema.
//
// player_tks.steam_id is a BIGINT; it is cast to text because a SteamID64
// exceeds JavaScript's safe-integer range and would lose precision as a JSON
// number.
func (s *Store) ListTeamKills(ctx context.Context, limit, offset int) ([]TeamKillStats, int, error) {
	query := `
		SELECT steam_id::text, kills, tk_given, tk_taken, last_seen
		FROM player_tks
		ORDER BY tk_given DESC
		LIMIT $1 OFFSET $2`

	rows, err := s.pool.Query(ctx, query, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	teamKills := []TeamKillStats{}
	for rows.Next() {
		var tk TeamKillStats
		if err := rows.Scan(&tk.SteamID, &tk.Kills, &tk.TKGiven, &tk.TKTaken, &tk.LastSeen); err != nil {
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

// scanPlayers reads a full set of player_stats rows into a slice.
func scanPlayers(rows pgx.Rows) ([]PlayerStats, error) {
	players := []PlayerStats{}
	for rows.Next() {
		var player PlayerStats
		if err := rows.Scan(
			&player.SteamID, &player.Kills, &player.Deaths, &player.Suicides,
			&player.HeadshotGiven, &player.HeadshotTaken, &player.Suppressions,
			&player.Caps, &player.Killstreak, &player.Score, &player.Wins,
			&player.Losses, &player.CreatedAt, &player.UpdatedAt,
		); err != nil {
			return nil, err
		}
		players = append(players, player)
	}

	return players, rows.Err()
}
