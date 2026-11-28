package main

import (
	"context"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"
)

// Many players put their Steam name in brackets after their Discord name, as in
// "discordname [SteamName]". It is only a habit: brackets can just as well hold
// a clan tag or be part of the name itself. So a lookup by Discord name tries
// the whole name and each part, and leaves the model to judge which matched.

const (
	maxNameCandidates = 5
	minCandidateRunes = 2
)

var (
	bracketed    = regexp.MustCompile(`\[([^\[\]]*)\]|\(([^()]*)\)|\{([^{}]*)\}`)
	extraSpaces  = regexp.MustCompile(`\s+`)
	nameDividers = strings.NewReplacer("|", "\x00", "｜", "\x00")
)

// nameCandidates returns the names worth searching for a Discord display name:
// the whole name, the parts outside brackets, then each bracketed part, without
// duplicates (case-insensitively) or fragments too short to search on.
func nameCandidates(display string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(s string) {
		s = strings.TrimSpace(extraSpaces.ReplaceAllString(s, " "))
		key := strings.ToLower(s)
		if utf8.RuneCountInString(s) < minCandidateRunes || seen[key] || len(out) >= maxNameCandidates {
			return
		}
		seen[key] = true
		out = append(out, s)
	}

	add(display)
	outside := bracketed.ReplaceAllString(display, "\x00")
	for part := range strings.SplitSeq(nameDividers.Replace(outside), "\x00") {
		add(part)
	}
	for _, m := range bracketed.FindAllStringSubmatch(display, -1) {
		add(m[1] + m[2] + m[3])
	}
	return out
}

// playerNameQuery is the /api/v1/players query for a name search. The fuzzy
// match also finds spellings that differ in case, spacing, separators,
// punctuation or leetspeak, and words with something between them, and says
// for each player how their name matched (name_match).
func playerNameQuery(name string) url.Values {
	q := pageQuery(10, 0)
	q.Set("name", name)
	q.Set("name_match", "fuzzy")
	q.Set("sort", "score")
	return q
}

// matchKinds are the stats API's name_match values, best first.
var matchKinds = []string{"exact", "substring", "normalised", "loose"}

// matchRank is the position of a name_match value in matchKinds; unknown
// values rank last. A stats API without name_match=fuzzy leaves name_match
// out and does a plain substring search, so a missing one is a substring.
func matchRank(kind any) int {
	if kind == nil {
		kind = "substring"
	}
	for i, k := range matchKinds {
		if k == kind {
			return i
		}
	}
	return len(matchKinds)
}

// nameMatches is what find_players returns.
type nameMatches struct {
	DiscordName string   `json:"discord_name,omitempty"`
	Searched    []string `json:"searched"`
	// Players are the matches of every search, once each, best match first,
	// with the names that found them in matched_by and the best way any of
	// them matched in name_match.
	Players []map[string]any `json:"players"`
	// More is set when a search had more matches than it returned.
	More bool `json:"more_matches,omitempty"`
	// Confidence and Advice tell the model whether it can use the match or
	// must ask the user which player they mean.
	Confidence string `json:"confidence"`
	Advice     string `json:"advice"`
}

// The confidence levels of a name search.
const (
	confidenceExact     = "exact"     // one player has exactly that name
	confidenceClear     = "clear"     // one player's name contains it, and no other comes close
	confidenceAmbiguous = "ambiguous" // several players match about as well
	confidenceLow       = "low"       // only spellings that differ (separators, leetspeak, words apart)
	confidenceNone      = "none"
)

// judge rates the results of a name search from how the best matches
// matched, and says what the model should do about it.
func (m *nameMatches) judge() {
	if len(m.Players) == 0 {
		m.Confidence = confidenceNone
		m.Advice = "No player matched. Ask for their exact Steam (in-game) name, or check the spelling."
		return
	}
	best := matchRank(m.Players[0]["name_match"])
	// tied counts the players that match as well as the best, and near those
	// that match at least as well as normalised: a name equal to the search
	// but for spacing is as likely to be the one meant as a longer name that
	// contains it.
	tied, near := 0, 0
	for _, p := range m.Players {
		r := matchRank(p["name_match"])
		if r == best {
			tied++
		}
		if r <= matchRank("normalised") {
			near++
		}
	}
	ask := " List the candidates by their Steam name (name), with a detail that tells them apart such as last seen (updated_at) or score, and ask the user which one they mean. Don't pick one yourself."
	switch {
	case best > matchRank("substring"):
		m.Confidence = confidenceLow
		m.Advice = "No name contains the search as typed; these only match once spaces, separators, punctuation or leetspeak are ignored (normalised) or with other text between its words (loose), so they may be someone else." + ask
	case tied > 1:
		m.Confidence = confidenceAmbiguous
		m.Advice = "Several players match equally well." + ask
	case best == matchRank("exact"):
		m.Confidence = confidenceExact
		m.Advice = "One player has exactly this name; use them, and say which name matched."
	case near > 1:
		m.Confidence = confidenceAmbiguous
		m.Advice = "One player's name contains the search, but others match once spaces, separators, punctuation or leetspeak are ignored." + ask
	default:
		m.Confidence = confidenceClear
		m.Advice = "One player's name contains the search and no other comes close; use them, and say which name matched. The others listed match less well."
	}
	if m.More {
		m.Advice += " There were more matches than listed; if none is right, ask for the full name."
	}
}

// findPlayersByNames runs a name search for each name, merges the results and
// judges how confident the match is.
func findPlayersByNames(ctx context.Context, stats *StatsClient, server, discordName string, names []string) (*nameMatches, error) {
	out := &nameMatches{DiscordName: discordName, Searched: names, Players: []map[string]any{}}
	byID := map[string]map[string]any{}
	for _, name := range names {
		res, err := stats.Get(ctx, server, "/api/v1/players", playerNameQuery(name))
		if err != nil {
			return nil, err
		}
		obj, _ := res.(map[string]any)
		items, _ := obj["items"].([]any)
		if total, ok := obj["total"].(float64); ok && int(total) > len(items) {
			out.More = true
		}
		for _, it := range items {
			p, ok := it.(map[string]any)
			if !ok {
				continue
			}
			id, _ := p["steam_id"].(string)
			if prev, ok := byID[id]; ok && id != "" {
				prev["matched_by"] = append(prev["matched_by"].([]string), name)
				if matchRank(p["name_match"]) < matchRank(prev["name_match"]) {
					prev["name_match"] = p["name_match"]
				}
				continue
			}
			p["matched_by"] = []string{name}
			byID[id] = p
			out.Players = append(out.Players, p)
		}
	}
	// Stable, so equally good matches keep the API's order (by score).
	slices.SortStableFunc(out.Players, func(a, b map[string]any) int {
		return matchRank(a["name_match"]) - matchRank(b["name_match"])
	})
	out.judge()
	return out, nil
}
