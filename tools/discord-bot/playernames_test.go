package main

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestPlayerNameMarkdown(t *testing.T) {
	const id = "76561198000000001"
	for _, c := range []struct{ name, steamID, want string }{
		{"TestPlayerAlpha", id, "[**TestPlayerAlpha**](<https://steamcommunity.com/profiles/76561198000000001>)"},
		{"TestPlayerAlpha", "", "**TestPlayerAlpha**"},
		{"TestPlayerAlpha", "12345", "**TestPlayerAlpha**"}, // not a SteamID64
		// Markdown in names is shown literally rather than breaking the bold or the link.
		{"*x*", "", `**\*x\***`},
		{"__under__", "", `**\_\_under\_\_**`},
		{"~~gone~~ ||spoiler||", "", `**\~\~gone\~\~ \|\|spoiler\|\|**`},
		{"`code`", "", "**\\`code\\`**"},
		{"> quote", "", `**\> quote**`},
		{"[TAG]Beta(1)", id, `[**\[TAG\]Beta\(1\)**](<https://steamcommunity.com/profiles/76561198000000001>)`},
		{`back\slash`, "", `**back\\slash**`},
		{"<@123> :smile:", "", `**\<\@123\> \:smile\:**`},
		{"two\nlines", "", "**two lines**"},
		{"  padded  ", "", "**padded**"},
		{"Ünïcødé 名前", "", "**Ünïcødé 名前**"},
		{"   ", id, ""},
	} {
		if got := playerNameMarkdown(c.name, c.steamID); got != c.want {
			t.Errorf("playerNameMarkdown(%q, %q) = %q, want %q", c.name, c.steamID, got, c.want)
		}
	}
}

func TestAddNameMarkdown(t *testing.T) {
	var v any
	if err := json.Unmarshal([]byte(`{
		"items": [
			{"steam_id": "76561198000000001", "name": "Test*Alpha", "kills": 3},
			{"steam_id": "76561198000000002", "name": null},
			{"weapon_name": "m4a1", "name": "not a player"}
		],
		"player": {"steam_id": "76561198000000003", "name": "TestPlayerBeta"}
	}`), &v); err != nil {
		t.Fatal(err)
	}
	addNameMarkdown(v)
	obj := v.(map[string]any)
	items := obj["items"].([]any)
	if got := items[0].(map[string]any)["name_md"]; got != `[**Test\*Alpha**](<https://steamcommunity.com/profiles/76561198000000001>)` {
		t.Errorf("first item name_md = %v", got)
	}
	for i := 1; i < 3; i++ {
		if _, ok := items[i].(map[string]any)["name_md"]; ok {
			t.Errorf("item %d got a name_md: %v", i, items[i])
		}
	}
	if got := obj["player"].(map[string]any)["name_md"]; got != "[**TestPlayerBeta**](<https://steamcommunity.com/profiles/76561198000000003>)" {
		t.Errorf("nested player name_md = %v", got)
	}
}

func TestAddNameMarkdownColumn(t *testing.T) {
	res := &QueryResult{
		Columns: []string{"steam_id", "name", "kills"},
		Rows: [][]any{
			{"76561198000000001", "TestPlayerAlpha", int64(5)},
			{int64(76561198000000002), "_Beta_", int64(4)}, // bigint SteamID column
			{"76561198000000003", nil, int64(1)},
		},
	}
	addNameMarkdownColumn(res)
	want := &QueryResult{
		Columns: []string{"steam_id", "name", "kills", "name_md"},
		Rows: [][]any{
			{"76561198000000001", "TestPlayerAlpha", int64(5), "[**TestPlayerAlpha**](<https://steamcommunity.com/profiles/76561198000000001>)"},
			{int64(76561198000000002), "_Beta_", int64(4), `[**\_Beta\_**](<https://steamcommunity.com/profiles/76561198000000002>)`},
			{"76561198000000003", nil, int64(1), nil},
		},
	}
	if !reflect.DeepEqual(res, want) {
		t.Errorf("got %#v\nwant %#v", res, want)
	}

	// Without a steam_id column there is nothing to link, so nothing is added.
	plain := &QueryResult{Columns: []string{"name"}, Rows: [][]any{{"TestPlayerAlpha"}}}
	addNameMarkdownColumn(plain)
	if len(plain.Columns) != 1 || len(plain.Rows[0]) != 1 {
		t.Errorf("name-only result changed: %#v", plain)
	}
	addNameMarkdownColumn(nil)
}

func TestFindPlayersHasNameMarkdown(t *testing.T) {
	var searched []string
	stats := fakeStats(t, map[string]string{"76561198000000001": "Test Player Beta"}, &searched)
	cfg := &Config{Servers: map[string]GameServer{"main": {Name: "main", StatsAPIURL: "unused"}}, ServerOrder: []string{"main"}}
	ts := NewToolset(cfg, stats, nil, nil, nil)
	out, err := ts.Run(context.Background(), &toolContext{}, "find_players", json.RawMessage(`{"name":"beta"}`))
	if err != nil {
		t.Fatal(err)
	}
	// The model gets the link as written, not with <> escaped as \u003c\u003e.
	encoded, err := encodeToolResult(out)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(encoded, `"name_md":"[**Test Player Beta**](<https://steamcommunity.com/profiles/76561198000000001>)"`) {
		t.Errorf("find_players result has no name_md: %s", encoded)
	}
}

func TestSystemPromptPlayerNames(t *testing.T) {
	prompt := buildSystemPrompt(&Config{}, true)
	for _, want := range []string{"name_md", "never name_md"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("system prompt does not mention %q", want)
		}
	}
}
