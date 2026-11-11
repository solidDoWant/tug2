package main

import (
	"context"
	"net/url"
	"regexp"
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
	for _, part := range strings.Split(nameDividers.Replace(outside), "\x00") {
		add(part)
	}
	for _, m := range bracketed.FindAllStringSubmatch(display, -1) {
		add(m[1] + m[2] + m[3])
	}
	return out
}

// playerNameQuery is the /api/v1/players query for a name search.
func playerNameQuery(name string) url.Values {
	q := pageQuery(10, 0)
	q.Set("name", name)
	q.Set("sort", "score")
	return q
}

// nameMatches is what find_players returns for a search on several names.
type nameMatches struct {
	DiscordName string   `json:"discord_name"`
	Searched    []string `json:"searched"`
	// Players are the matches of every search, once each, with the names that
	// found them in matched_by.
	Players []map[string]any `json:"players"`
}

// findPlayersByNames runs a name search for each name and merges the results.
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
		for _, it := range items {
			p, ok := it.(map[string]any)
			if !ok {
				continue
			}
			id, _ := p["steam_id"].(string)
			if prev, ok := byID[id]; ok && id != "" {
				prev["matched_by"] = append(prev["matched_by"].([]string), name)
				continue
			}
			p["matched_by"] = []string{name}
			byID[id] = p
			out.Players = append(out.Players, p)
		}
	}
	return out, nil
}
