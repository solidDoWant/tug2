package main

import (
	"context"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
)

// Forgiving name search for find_players. People rarely type a Steam name
// exactly: "Jane Doe" may be recorded as "JaneDoe", "jane_doe", "J4ne.D0e" or
// "Jane the Doe". Rather than enumerate spellings, both sides are compared in
// a few forms, each a weaker kind of match:
//
//	exact       the whole name, case-insensitively
//	substring   the name contains the search, case-insensitively
//	normalised  the same, after lowercasing, folding common leetspeak digits
//	            (0→o, 1→i, 3→e, 4→a, 5→s, 7→t, @→a, $→s) and dropping everything
//	            but letters and digits ("J4ne.D0e" and "jane doe" are both "janedoe")
//	loose       the search's words appear in order with anything between them
//	            ("Jane Doe" finds "Jane the Doe"), like the regex Jane.*Doe
//
// The bot runs this itself, as one fixed query over its read-only stats
// database connection (the one query_stats uses), because ranking has to see
// every name: the best matches must come first before the result is cut to a
// page. The stats API's name filter stays a plain substring search; without a
// stats database, find_players falls back to it.
//
// Every form is computed in SQL from the bound search text, so the search and
// the stored names are normalised by the same code, and user input never
// becomes part of a pattern: exact and normalised compare with = and strpos,
// and the substring and loose patterns have LIKE's metacharacters escaped.
//
// Cost: player_stats has one row per player ever seen (thousands, not
// millions), and a %...% ILIKE can't use an index anyway, so this is one
// sequential scan with a regexp_replace per row.

// nameMatchKinds are the match kinds, best first; a rank is an index into it.
var nameMatchKinds = []string{"exact", "substring", "normalised", "loose"}

// maxNameMatches is how many players one name search returns.
const maxNameMatches = 10

var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// normaliseSQL is the SQL normalised form of the text expression e.
func normaliseSQL(e string) string {
	return `regexp_replace(translate(lower(` + e + `), '013457@$', 'oieastas'), '[^[:alnum:]]+', '', 'g')`
}

// findPlayersSQL ranks every named player against $1 (the search), $2 (its
// substring pattern) and $3 (its loose pattern, or NULL), and returns the best
// $4 with the total number of matches. updated_at is the database's local
// wall-clock time; casting it to timestamptz reads it in the session's zone,
// the server's default, so it scans as the right instant.
var findPlayersSQL = `
SELECT steam_id::text, name, name_rank, COALESCE(kills, 0)::bigint, COALESCE(deaths, 0)::bigint,
       COALESCE(score, 0)::bigint, COALESCE(play_time_seconds, 0)::bigint, updated_at::timestamptz,
       count(*) OVER ()
FROM (
	SELECT steam_id, name, kills, deaths, score, play_time_seconds, updated_at,
	       CASE
	           WHEN name IS NULL THEN NULL
	           WHEN lower(name) = lower($1::text) THEN 0
	           WHEN name ILIKE $2::text THEN 1
	           WHEN ` + normaliseSQL(`$1::text`) + ` <> ''
	                AND strpos(` + normaliseSQL(`name`) + `, ` + normaliseSQL(`$1::text`) + `) > 0 THEN 2
	           WHEN name ILIKE $3::text THEN 3
	       END AS name_rank
	FROM player_stats
) AS ranked
WHERE name_rank IS NOT NULL
ORDER BY name_rank, score DESC NULLS LAST, steam_id
LIMIT $4`

// looseWords splits a search into its words: runs of letters and digits.
func looseWords(name string) []string {
	return strings.FieldsFunc(name, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
}

// loosePattern is the ILIKE pattern of a loose match, or nil when the search
// has fewer than two words (a loose match would then be a substring match).
func loosePattern(name string) *string {
	words := looseWords(name)
	if len(words) < 2 {
		return nil
	}
	for i, w := range words {
		words[i] = likeEscaper.Replace(w)
	}
	p := "%" + strings.Join(words, "%") + "%"
	return &p
}

// PlayerMatch is one player found by a name search, with headline stats.
type PlayerMatch struct {
	SteamID         string
	Name            string
	NameMatch       string
	Kills           int64
	Deaths          int64
	Score           int64
	PlayTimeSeconds int64
	UpdatedAt       *time.Time
}

// toMap is the player as find_players lists it, in the same shape as a stats
// API player so both sources merge the same way.
func (p PlayerMatch) toMap() map[string]any {
	m := map[string]any{
		"steam_id":          p.SteamID,
		"name":              p.Name,
		"name_match":        p.NameMatch,
		"kills":             p.Kills,
		"deaths":            p.Deaths,
		"score":             p.Score,
		"play_time_seconds": p.PlayTimeSeconds,
		"updated_at":        nil,
	}
	if p.UpdatedAt != nil {
		m["updated_at"] = p.UpdatedAt.UTC().Format("2006-01-02 15:04:05")
	}
	return m
}

// FindPlayers runs the forgiving name search in a server's schema: the best
// maxNameMatches players, best match first, and how many matched in all.
func (d *PostgresStatsDB) FindPlayers(ctx context.Context, schema, name string) ([]PlayerMatch, int, error) {
	var out []PlayerMatch
	total := 0
	err := d.inReadOnlyTx(ctx, schema, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, findPlayersSQL,
			name, "%"+likeEscaper.Replace(name)+"%", loosePattern(name), maxNameMatches)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var p PlayerMatch
			var rank int32
			var count int64
			if err := rows.Scan(&p.SteamID, &p.Name, &rank, &p.Kills, &p.Deaths, &p.Score,
				&p.PlayTimeSeconds, &p.UpdatedAt, &count); err != nil {
				return err
			}
			p.NameMatch = nameMatchKinds[rank]
			total = int(count)
			out = append(out, p)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, 0, describeQueryError(err)
	}
	return out, total, nil
}
