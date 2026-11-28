package main

import (
	"slices"
	"strconv"
	"strings"
)

// Player names in replies are written one way everywhere, so readers can pick
// them out: bold, and linked to the Steam profile when the SteamID is known.
// The model is unreliable at escaping names and building links itself, so the
// tools hand it a ready-made name_md next to each name to copy as is.

// markdownSpecials are the characters Discord markdown may treat as syntax in
// or around a name: emphasis, code, spoilers, quotes, headings, lists, masked
// links, mentions and timestamps (<...>), and :emoji:. Discord shows a
// backslash-escaped punctuation character literally, so escaping one that
// would have been plain text anyway is harmless.
const markdownSpecials = "\\*_~`|<>[]()#-:@"

// escapeMarkdown makes s display literally in Discord markdown. Line breaks
// become spaces, since a name never spans lines.
func escapeMarkdown(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r == '\n' || r == '\r' || r == '\t':
			b.WriteByte(' ')
		case strings.ContainsRune(markdownSpecials, r):
			b.WriteByte('\\')
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// steamProfileURL is a player's public Steam profile page.
func steamProfileURL(steamID string) string {
	return "https://steamcommunity.com/profiles/" + steamID
}

// playerNameMarkdown formats a player name for a reply: bold and escaped,
// and with a SteamID a masked link to the profile. The <url> form stops
// Discord from adding a preview embed for every linked name. It returns ""
// for a blank name.
func playerNameMarkdown(name, steamID string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	bold := "**" + strings.TrimSpace(escapeMarkdown(name)) + "**"
	if !isSteamID64(steamID) {
		return bold
	}
	return "[" + bold + "](<" + steamProfileURL(steamID) + ">)"
}

func isSteamID64(s string) bool {
	if len(s) != 17 {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// addNameMarkdown walks a decoded stats-api response and adds name_md next to
// every player name. The API names players only in objects that also carry
// their steam_id ({"steam_id": ..., "name": ...}).
func addNameMarkdown(v any) {
	switch v := v.(type) {
	case map[string]any:
		if name, ok := v["name"].(string); ok {
			if id, ok := v["steam_id"].(string); ok {
				if md := playerNameMarkdown(name, id); md != "" {
					v["name_md"] = md
				}
			}
		}
		for _, e := range v {
			addNameMarkdown(e)
		}
	case []any:
		for _, e := range v {
			addNameMarkdown(e)
		}
	}
}

// addNameMarkdownColumn adds a name_md column to a query_stats result that
// selected both a player's name and steam_id.
func addNameMarkdownColumn(res *QueryResult) {
	if res == nil || slices.Contains(res.Columns, "name_md") {
		return
	}
	nameCol, idCol := slices.Index(res.Columns, "name"), slices.Index(res.Columns, "steam_id")
	if nameCol < 0 || idCol < 0 {
		return
	}
	res.Columns = append(res.Columns, "name_md")
	for i, row := range res.Rows {
		name, _ := row[nameCol].(string)
		var id string
		switch v := row[idCol].(type) {
		case string:
			id = v
		case int64: // some tables store the SteamID64 as a bigint
			id = strconv.FormatInt(v, 10)
		}
		var md any
		if s := playerNameMarkdown(name, id); s != "" {
			md = s
		}
		res.Rows[i] = append(row, md)
	}
}
