package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/bwmarrin/discordgo"
)

func searchHit(id, channelID string, ts time.Time, content string) []*discordgo.Message {
	m := msgAt(id, ts, content)
	m.ChannelID = channelID
	m.Author = &discordgo.User{Username: "ingame-relay", Bot: true}
	return []*discordgo.Message{m}
}

func TestSearchQueryValues(t *testing.T) {
	q := searchQuery{
		Content:    "TestPlayerAlpha",
		ChannelIDs: []string{"11", "12"},
		Before:     time.Date(2026, 11, 10, 0, 0, 0, 0, time.UTC),
		After:      time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC),
		Limit:      5,
		Offset:     10,
	}
	v := q.values()
	if got := v["channel_id"]; !reflect.DeepEqual(got, []string{"11", "12"}) {
		t.Errorf("channel_id = %v", got)
	}
	if v.Get("max_id") != snowflakeAt(q.Before) || v.Get("min_id") != snowflakeAt(q.After) {
		t.Errorf("bounds = %s..%s", v.Get("min_id"), v.Get("max_id"))
	}
	if v.Get("sort_by") != "timestamp" || v.Get("sort_order") != "desc" || v.Get("limit") != "5" || v.Get("offset") != "10" {
		t.Errorf("values = %v", v)
	}

	q.Oldest = true
	if v := q.values(); v.Get("sort_order") != "asc" {
		t.Errorf("oldest: %v", v)
	}
	q.Relevance = true
	if v := q.values(); v.Get("sort_by") != "relevance" {
		t.Errorf("relevance: %v", v)
	}
	if v := (searchQuery{Content: "x", Limit: 1}).values(); v.Has("offset") || v.Has("min_id") || v.Has("max_id") {
		t.Errorf("unset fields sent: %v", v)
	}
}

func TestSearchChannels(t *testing.T) {
	at := time.Date(2026, 11, 10, 6, 37, 0, 0, time.UTC)
	readable := []ReadableChannel{{Name: "main-ingame", ID: "11"}, {Name: "changelog", ID: "12"}}
	src := &fakeChannels{readable: readable, found: &messageSearch{
		TotalResults: 40,
		Messages: [][]*discordgo.Message{
			searchHit("100", "11", at, "TestPlayerAlpha Left the server (Banned - 11y remaining. Reason: testing)"),
			searchHit("90", "11", at.Add(-time.Hour), "TestPlayerAlpha joined"),
			{nil},
		},
	}}

	got, err := searchChannels(context.Background(), src, "42", readable[:1], readable, searchQuery{Content: "  TestPlayerAlpha "})
	if err != nil {
		t.Fatal(err)
	}
	if src.searched.Get("content") != "TestPlayerAlpha" || src.searched.Get("limit") != fmt.Sprint(defaultSearchLimit) {
		t.Errorf("query = %v", src.searched)
	}
	if ids := src.searched["channel_id"]; !reflect.DeepEqual(ids, []string{"11"}) {
		t.Errorf("searched channels %v, want only the chosen one", ids)
	}
	if got.TotalMatches != 40 || len(got.Messages) != 2 || got.Next != 2 {
		t.Fatalf("result = %+v", got)
	}
	m := got.Messages[0]
	if m.Channel != "main-ingame" || m.PostedUTC != "2026-11-10 06:37" || m.Link != "https://discord.com/channels/42/11/100" || !strings.Contains(m.Content, "Banned") {
		t.Errorf("first match = %+v", m)
	}

	// The last page has no next offset.
	src.found.TotalResults = 2
	if got, _ := searchChannels(context.Background(), src, "42", readable, readable, searchQuery{Content: "x"}); got.Next != 0 {
		t.Errorf("next = %d on the last page", got.Next)
	}

	// Limits are clamped to what Discord accepts.
	if _, err := searchChannels(context.Background(), src, "42", readable, readable, searchQuery{Content: "x", Limit: 500, Offset: 99999}); err != nil {
		t.Fatal(err)
	}
	if src.searched.Get("limit") != fmt.Sprint(maxSearchLimit) || src.searched.Get("offset") != fmt.Sprint(maxSearchOffset) {
		t.Errorf("clamped query = %v", src.searched)
	}

	for _, q := range []searchQuery{{Content: "  "}, {Content: strings.Repeat("a", maxSearchQuery+1)}} {
		if _, err := searchChannels(context.Background(), src, "42", readable, readable, q); err == nil {
			t.Errorf("query %.10q: no error", q.Content)
		}
	}
	if _, err := searchChannels(context.Background(), src, "42", nil, readable, searchQuery{Content: "x"}); err == nil {
		t.Error("no channels: no error")
	}

	src.searchErr = errSearchIndexing
	if _, err := searchChannels(context.Background(), src, "42", readable, readable, searchQuery{Content: "x"}); !errors.Is(err, errSearchIndexing) {
		t.Errorf("indexing: %v", err)
	}
}

func TestSearchTool(t *testing.T) {
	readable := []ReadableChannel{{Name: "main-ingame", ID: "11"}, {Name: "changelog", ID: "12"}}
	src := &fakeChannels{readable: readable}
	cfg := &Config{Servers: map[string]GameServer{}}
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, src, nil)
	tc := &toolContext{guildID: "42"}
	run := func(input string) error {
		_, err := ts.Run(context.Background(), tc, "search_channels", []byte(input))
		return err
	}

	// No channels named: every readable channel, and nothing else.
	if err := run(`{"query":"TestPlayerAlpha"}`); err != nil {
		t.Fatal(err)
	}
	if ids := src.searched["channel_id"]; !reflect.DeepEqual(ids, []string{"11", "12"}) {
		t.Errorf("searched %v, want all readable channels", ids)
	}

	if err := run(`{"query":"x","channels":["#changelog"],"order":"oldest","after":"2026-11-01"}`); err != nil {
		t.Fatal(err)
	}
	if ids := src.searched["channel_id"]; !reflect.DeepEqual(ids, []string{"12"}) || src.searched.Get("sort_order") != "asc" || !src.searched.Has("min_id") {
		t.Errorf("query = %v", src.searched)
	}

	for _, bad := range []string{
		`{"query":"x","channels":["bot-channel"]}`, // not readable
		`{"query":"x","order":"sideways"}`,
		`{"query":"x","before":"yesterday"}`,
	} {
		if err := run(bad); err == nil {
			t.Errorf("%s: no error", bad)
		}
	}
}

// TestSearchMessagesHTTP checks the REST call itself against a fake Discord.
func TestSearchMessagesHTTP(t *testing.T) {
	status := http.StatusOK
	var gotPath, gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotQuery = r.URL.Path, r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if status == http.StatusAccepted {
			fmt.Fprint(w, `{"message":"Index not yet available. Try again later","code":110000,"retry_after":2}`)
			return
		}
		fmt.Fprint(w, `{"total_results":1,"messages":[[{"id":"100","channel_id":"11","content":"hello","timestamp":"2026-11-10T06:37:00+00:00","author":{"id":"1","username":"relay"}}]]}`)
	}))
	defer srv.Close()

	saved := discordgo.EndpointGuilds
	discordgo.EndpointGuilds = srv.URL + "/api/v10/guilds/"
	defer func() { discordgo.EndpointGuilds = saved }()

	session, _ := discordgo.New("Bot test")
	session.Client = srv.Client()
	d := &DiscordChannels{session: session}

	q := searchQuery{Content: "hello", ChannelIDs: []string{"11"}, Limit: 5}.values()
	found, err := d.SearchMessages(context.Background(), "42", q)
	if err != nil {
		t.Fatal(err)
	}
	if gotPath != "/api/v10/guilds/42/messages/search" || !strings.Contains(gotQuery, "content=hello") || !strings.Contains(gotQuery, "channel_id=11") {
		t.Errorf("request = %s?%s", gotPath, gotQuery)
	}
	if found.TotalResults != 1 || len(found.Messages) != 1 || found.Messages[0][0].Content != "hello" {
		t.Errorf("found = %+v", found)
	}

	status = http.StatusAccepted
	if _, err := d.SearchMessages(context.Background(), "42", q); !errors.Is(err, errSearchIndexing) {
		t.Errorf("202: %v", err)
	}
}
