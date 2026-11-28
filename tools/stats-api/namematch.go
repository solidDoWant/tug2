package main

import (
	"strconv"
	"strings"
	"unicode"
)

// Fuzzy name search (name_match=fuzzy on /api/v1/players). People rarely type
// a Steam name exactly: "Jane Doe" may be recorded as "JaneDoe", "jane_doe",
// "J4ne.D0e" or "Jane the Doe". Rather than enumerate spellings, both sides
// are compared in a few forms, each a weaker kind of match:
//
//	exact       the whole name, case-insensitively
//	substring   the name contains the query, case-insensitively (the default search)
//	normalised  the same, after lowercasing, folding common leetspeak digits
//	            (0→o, 1→i, 3→e, 4→a, 5→s, 7→t, @→a, $→s) and dropping everything
//	            but letters and digits ("J4ne.D0e" and "jane doe" are both "janedoe")
//	loose       the query's words appear in order with anything between them
//	            ("Jane Doe" finds "Jane the Doe"), like the regex Jane.*Doe
//
// Every form is computed in SQL from the bound query text, so the query and
// the stored names are normalised by the same code, and user input never
// becomes part of a pattern: exact and normalised compare with = and strpos,
// and the loose pattern's words have LIKE's metacharacters escaped.
//
// Cost: player_stats has one row per player ever seen (thousands, not
// millions), and a %...% ILIKE could never use an index anyway, so this is the
// same sequential scan the plain search already does, with a regexp_replace
// per row on top. The ranking is computed once per row in a subquery.

// nameMatchKinds are the match kinds, best first; a rank is an index into it.
var nameMatchKinds = []string{"exact", "substring", "normalised", "loose"}

// leetFrom and leetTo are the leetspeak folds of the normalised form, as the
// two arguments of SQL translate().
const leetFrom, leetTo = "013457@$", "oieastas"

// normaliseSQL is the SQL normalised form of the text expression e.
func normaliseSQL(e string) string {
	return `regexp_replace(translate(lower(` + e + `), '` + leetFrom + `', '` + leetTo + `'), '[^[:alnum:]]+', '', 'g')`
}

// looseWords splits a query into its words: runs of letters and digits.
func looseWords(name string) []string {
	return strings.FieldsFunc(name, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
}

// loosePattern is the ILIKE pattern of a loose match, or nil when the query
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

// nameMatchRank returns a SQL expression that is the rank (index into
// nameMatchKinds) of the best way the text column col matches name, or NULL
// when it doesn't match at all. Its parameters are appended to args.
func nameMatchRank(col, name string, args *[]any) string {
	bind := func(v any) string {
		*args = append(*args, v)
		return "$" + strconv.Itoa(len(*args))
	}
	q := bind(name)
	sub := bind("%" + likeEscaper.Replace(name) + "%")
	loose := bind(loosePattern(name))
	norm := normaliseSQL(q + `::text`)
	return `CASE
		WHEN ` + col + ` IS NULL THEN NULL
		WHEN lower(` + col + `) = lower(` + q + `::text) THEN 0
		WHEN ` + col + ` ILIKE ` + sub + `::text THEN 1
		WHEN ` + norm + ` <> '' AND strpos(` + normaliseSQL(col) + `, ` + norm + `) > 0 THEN 2
		WHEN ` + col + ` ILIKE ` + loose + `::text THEN 3
	END`
}
