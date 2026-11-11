package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/bwmarrin/discordgo"
)

func TestCleanTitle(t *testing.T) {
	tests := map[string]string{
		"Top medics on main":                     "Top medics on main",
		"\"Bug: revive messages render badly.\"": "Bug: revive messages render badly",
		"Title: **Map playtime on test**\nextra": "Map playtime on test",
		"  `spaced    out`  ":                    "spaced out",
		"":                                       "",
		"\"\"":                                   "",
	}
	for in, want := range tests {
		if got := cleanTitle(in); got != want {
			t.Errorf("cleanTitle(%q) = %q, want %q", in, got, want)
		}
	}
	long := cleanTitle(strings.Repeat("word ", 40))
	if n := len([]rune(long)); n > maxTitleRunes || !strings.HasSuffix(long, "…") {
		t.Errorf("long title = %q (%d runes)", long, n)
	}
}

func TestFiledIssueRendering(t *testing.T) {
	const url = "https://github.com/example/repo/issues/4"
	d := IssueDraft{Kind: IssueBug, Title: "Revive line breaks"}
	e := filedEmbed(d, url)
	if e.URL != url || e.Footer.Text != "Filed on GitHub · #4" {
		t.Errorf("filed embed url %q footer %q", e.URL, e.Footer.Text)
	}
	if got := filedMessage(url); got != "Filed as issue #4: "+url {
		t.Errorf("filedMessage = %q", got)
	}
	// The model sees the filed state in the history.
	text := botMessageText(&discordgo.Message{Content: "Here's the draft.", Embeds: []*discordgo.MessageEmbed{e}})
	if !strings.Contains(text, `[Issue "Revive line breaks": filed as `+url+"]") {
		t.Errorf("botMessageText = %q", text)
	}
	pending := botMessageText(&discordgo.Message{Embeds: []*discordgo.MessageEmbed{draftEmbed(d, "awaiting confirmation")}})
	if !strings.Contains(pending, "[Issue draft \"Revive line breaks\": awaiting confirmation]") {
		t.Errorf("pending botMessageText = %q", pending)
	}
}

func TestAgentTitle(t *testing.T) {
	var got struct {
		Tools    []json.RawMessage       `json:"tools"`
		System   []struct{ Text string } `json:"system"`
		Messages []struct {
			Content []struct{ Text string } `json:"content"`
		} `json:"messages"`
		CacheControl json.RawMessage `json:"cache_control"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&got)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"msg_1","type":"message","role":"assistant","model":"fake","content":[{"type":"text","text":"\"Bug: revive lines render as raw markdown.\""}],"stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":12}}`)
	}))
	t.Cleanup(server.Close)
	t.Setenv("ANTHROPIC_BASE_URL", server.URL)
	t.Setenv("ANTHROPIC_API_KEY", "test")
	agent := NewAgent(&Config{Model: "fake", Effort: "low"}, &Toolset{tools: map[string]tool{}}, false, nil)

	title, err := agent.Title(context.Background(), []Turn{
		{Author: "TestUserOne", Text: "[Forwarded message from #main-ingame]\nsome raw text"},
		{FromBot: true, Text: "ignored"},
		{Author: "TestUserOne", Text: "this isn't rendering properly"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if title != "Bug: revive lines render as raw markdown" {
		t.Errorf("title = %q", title)
	}
	if len(got.Tools) != 0 || len(got.CacheControl) != 0 || !strings.Contains(got.System[0].Text, "thread title") {
		t.Errorf("title call should have no tools or caching and its own prompt: %+v", got)
	}
	sent := got.Messages[0].Content[0].Text
	if !strings.Contains(sent, "[TestUserOne]: this isn't rendering properly") || strings.Contains(sent, "ignored") {
		t.Errorf("conversation sent = %q", sent)
	}
}
