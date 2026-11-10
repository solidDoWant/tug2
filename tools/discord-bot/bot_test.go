package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestParseHostname(t *testing.T) {
	tests := []struct {
		hostname  string
		round     int
		maxRounds int
		objective string
		mapEnded  bool
	}{
		{"TUG GG 2 MAIN (2/5) [Cap 5/8]", 2, 5, "Cap 5/8", false},
		{"TUG GG 2 MAIN (1/5) [Caps 1/3, Caches 0/5]", 1, 5, "Caps 1/3, Caches 0/5", false},
		{"TUG GG 2 TEST (Map end)", 0, 0, "", true},
		{"Server (3)", 3, 0, "", false},
		{"Server (3/?) [Level 6]", 3, 0, "Level 6", false},
		{"Plain Server", 0, 0, "", false},
		// A "(n)" inside the base name is not round progress.
		{"Squad (2) Fun Server", 0, 0, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.hostname, func(t *testing.T) {
			var s ServerStatus
			parseHostname(&s, tt.hostname)
			if s.Round != tt.round || s.MaxRounds != tt.maxRounds || s.Objective != tt.objective || s.MapEnded != tt.mapEnded {
				t.Errorf("got round=%d max=%d objective=%q ended=%v", s.Round, s.MaxRounds, s.Objective, s.MapEnded)
			}
		})
	}
}

func TestSplitMessage(t *testing.T) {
	if got := splitMessage("short", 100); len(got) != 1 || got[0] != "short" {
		t.Fatalf("short message split: %q", got)
	}

	long := strings.Repeat("line of text\n", 400)
	chunks := splitMessage(long, 500)
	for i, c := range chunks {
		if n := len([]rune(c)); n > 500 {
			t.Errorf("chunk %d has %d runes", i, n)
		}
	}
	if joined := strings.Join(chunks, "\n"); strings.Count(joined, "line of text") != 400 {
		t.Errorf("lost text when splitting")
	}

	// A code block split across chunks is closed and reopened.
	table := "```\n" + strings.Repeat("row | 123 | 456\n", 100) + "```"
	for i, c := range splitMessage(table, 400) {
		if strings.Count(c, "```")%2 != 0 {
			t.Errorf("chunk %d has an unbalanced code fence", i)
		}
	}
}

func TestBuildMessages(t *testing.T) {
	at := func(min int) time.Time { return time.Date(2026, 11, 10, 12, min, 0, 0, time.UTC) }
	history := []Turn{
		{FromBot: true, Text: "stray leading bot message"},
		{Author: "TestUserOne", Text: "what's my kd?", Posted: at(0)},
		{Author: "TestUserTwo", Text: "mine too", Posted: at(1)},
		{FromBot: true, Text: "Which in-game names?"},
		{Author: "TestUserOne", Text: "TestPlayerAlpha", Posted: at(2)},
		{FromBot: true, Text: "trailing bot message"},
	}

	type wireMsg struct {
		Role    string `json:"role"`
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
	}
	render := func(h []Turn) ([]wireMsg, []byte) {
		raw, err := json.Marshal(buildMessages(h))
		if err != nil {
			t.Fatal(err)
		}
		var wire []wireMsg
		if err := json.Unmarshal(raw, &wire); err != nil {
			t.Fatal(err)
		}
		return wire, raw
	}

	wire, raw := render(history)
	if len(wire) != 3 || wire[0].Role != "user" || wire[1].Role != "assistant" || wire[2].Role != "user" {
		t.Fatalf("want user/assistant/user, got %s", raw)
	}
	first := wire[0].Content[0].Text
	for _, want := range []string{"[2026-11-10 12:00 UTC] [TestUserOne]: what's my kd?", "[2026-11-10 12:01 UTC] [TestUserTwo]: mine too"} {
		if !strings.Contains(first, want) {
			t.Errorf("first message %q missing %q", first, want)
		}
	}

	// A follow-up must leave every earlier message byte-identical, so the
	// previous turn's cached prefix still matches.
	_, before := render(history[:5])
	_, after := render(append(append([]Turn{}, history...), Turn{Author: "TestUserOne", Text: "and on test?", Posted: at(9)}))
	prefix := strings.TrimSuffix(string(before), "]")
	if !strings.HasPrefix(string(after), prefix) {
		t.Errorf("history prefix changed on a follow-up:\nbefore %s\nafter  %s", before, after)
	}
}

func TestRateLimiter(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	r := NewRateLimiter(2, 1, nil)
	r.now = func() time.Time { return now }

	for i := 0; i < 2; i++ {
		if ok, _ := r.AllowQuestion("u"); !ok {
			t.Fatalf("question %d rejected", i)
		}
	}
	if ok, wait := r.AllowQuestion("u"); ok || wait != time.Hour {
		t.Fatalf("third question: ok=%v wait=%v", ok, wait)
	}
	if ok, _ := r.AllowQuestion("other"); !ok {
		t.Fatalf("limits must be per user")
	}
	now = now.Add(time.Hour)
	if ok, _ := r.AllowQuestion("u"); !ok {
		t.Fatalf("window did not slide")
	}

	if ok, _ := r.AllowIssue("u"); !ok {
		t.Fatal("first issue rejected")
	}
	r.RefundIssue("u")
	if ok, _ := r.AllowIssue("u"); !ok {
		t.Fatal("refunded slot not returned")
	}
	if ok, _ := r.AllowIssue("u"); ok {
		t.Fatal("issue limit not enforced")
	}
}

func TestRateLimiterOverrides(t *testing.T) {
	zero, five := 0, 5
	r := NewRateLimiter(1, 1, map[string]UserLimit{
		"owner":  {QuestionsPerHour: &zero, IssuesPerDay: &zero}, // no limits
		"raised": {QuestionsPerHour: &five},                      // issues keep the default
	})

	for i := 0; i < 100; i++ {
		if ok, _ := r.AllowQuestion("owner"); !ok {
			t.Fatalf("owner limited after %d questions", i)
		}
		if ok, _ := r.AllowIssue("owner"); !ok {
			t.Fatalf("owner limited after %d issues", i)
		}
	}
	for i := 0; i < 5; i++ {
		if ok, _ := r.AllowQuestion("raised"); !ok {
			t.Fatalf("raised user limited after %d questions", i)
		}
	}
	if ok, _ := r.AllowQuestion("raised"); ok {
		t.Fatal("raised user's limit not enforced")
	}
	if ok, _ := r.AllowIssue("raised"); !ok {
		t.Fatal("raised user's first issue rejected")
	}
	if ok, _ := r.AllowIssue("raised"); ok {
		t.Fatal("raised user should keep the default issue limit")
	}
	if ok, _ := r.AllowQuestion("someone"); !ok {
		t.Fatal("default user's first question rejected")
	}
	if ok, _ := r.AllowQuestion("someone"); ok {
		t.Fatal("default limit not enforced")
	}
}

func TestParseConfigExtras(t *testing.T) {
	t.Setenv("DISCORD_TOKEN", "x")
	t.Setenv("DISCORD_CHANNEL_ID", "1")
	t.Setenv("SERVERS", `[{"name":"main","query_address":"h:27000"}]`)
	t.Setenv("USER_LIMITS", `{"100000000000000001": {"questions_per_hour": 0, "issues_per_day": 0, "note": "owner"},
		"100000000000000002": {"questions_per_hour": 60}}`)
	t.Setenv("READABLE_CHANNELS", `[{"name":"Changelog","id":"100000000000000003","description":"server update notes"}]`)

	cfg, err := ParseConfig()
	if err != nil {
		t.Fatal(err)
	}
	owner := cfg.UserLimits["100000000000000001"]
	if owner.QuestionsPerHour == nil || *owner.QuestionsPerHour != 0 || owner.IssuesPerDay == nil {
		t.Errorf("owner limits = %+v", owner)
	}
	if cfg.UserLimits["100000000000000002"].IssuesPerDay != nil {
		t.Errorf("omitted limit should stay nil (use the default)")
	}
	if len(cfg.ReadableChannels) != 1 || cfg.ReadableChannels[0].Name != "changelog" {
		t.Errorf("readable channels = %+v", cfg.ReadableChannels)
	}

	bad := map[string]string{
		"USER_LIMITS":       `{"not-an-id": {"questions_per_hour": 1}}`,
		"READABLE_CHANNELS": `[{"name":"x","id":"123"}]`,
	}
	for key, value := range bad {
		t.Run(key, func(t *testing.T) {
			t.Setenv(key, value)
			if _, err := ParseConfig(); err == nil || !strings.Contains(err.Error(), key) {
				t.Errorf("want an error naming %s, got %v", key, err)
			}
		})
	}
	t.Run("negative limit", func(t *testing.T) {
		t.Setenv("USER_LIMITS", `{"100000000000000001": {"issues_per_day": -1}}`)
		if _, err := ParseConfig(); err == nil {
			t.Error("negative limit accepted")
		}
	})
	t.Run("unknown field", func(t *testing.T) {
		t.Setenv("USER_LIMITS", `{"100000000000000001": {"questions_per_day": 5}}`)
		if _, err := ParseConfig(); err == nil {
			t.Error("typo'd field accepted")
		}
	})
}

func TestParseConfigGitHubApp(t *testing.T) {
	t.Setenv("DISCORD_TOKEN", "x")
	t.Setenv("DISCORD_CHANNEL_ID", "1")
	t.Setenv("SERVERS", `[{"name":"main","query_address":"h:27000"}]`)

	keyFile := t.TempDir() + "/key.pem"
	if err := os.WriteFile(keyFile, []byte("not checked here"), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Setenv("GITHUB_REPO", "example/repo")
	t.Setenv("GITHUB_APP_ID", "12345")
	t.Setenv("GITHUB_APP_PRIVATE_KEY_FILE", keyFile)
	cfg, err := ParseConfig()
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.IssuesEnabled || cfg.GitHubAppID != 12345 || string(cfg.GitHubAppPrivateKey) != "not checked here" {
		t.Errorf("app config = enabled %v id %d", cfg.IssuesEnabled, cfg.GitHubAppID)
	}

	t.Run("id without key", func(t *testing.T) {
		t.Setenv("GITHUB_APP_PRIVATE_KEY_FILE", "")
		if _, err := ParseConfig(); err == nil {
			t.Error("app id without a key accepted")
		}
	})
	t.Run("both key sources", func(t *testing.T) {
		t.Setenv("GITHUB_APP_PRIVATE_KEY", "inline")
		if _, err := ParseConfig(); err == nil {
			t.Error("two key sources accepted")
		}
	})
	t.Run("no app means issues off", func(t *testing.T) {
		t.Setenv("GITHUB_APP_ID", "")
		t.Setenv("GITHUB_APP_PRIVATE_KEY_FILE", "")
		cfg, err := ParseConfig()
		if err != nil || cfg.IssuesEnabled {
			t.Errorf("err=%v enabled=%v", err, cfg != nil && cfg.IssuesEnabled)
		}
	})
}

func TestParseConfig(t *testing.T) {
	t.Setenv("DISCORD_TOKEN", "x")
	t.Setenv("DISCORD_CHANNEL_ID", "1")
	t.Setenv("SERVERS", `[{"name":"Main","stats_api_url":"http://stats/","query_address":"h:27000"},{"name":"test","query_address":"h:27001"}]`)
	cfg, err := ParseConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Model != "claude-haiku-5-5" || cfg.Effort != "low" {
		t.Errorf("model defaults = %q/%q", cfg.Model, cfg.Effort)
	}
	if got := cfg.statsServers(); len(got) != 1 || got[0] != "main" {
		t.Errorf("statsServers = %v", got)
	}
	if cfg.Servers["main"].StatsAPIURL != "http://stats" {
		t.Errorf("trailing slash not trimmed: %q", cfg.Servers["main"].StatsAPIURL)
	}
	if cfg.IssuesEnabled {
		t.Errorf("issues enabled without a token")
	}

	t.Setenv("LLM_EFFORT", "extreme")
	t.Setenv("GITHUB_APP_ID", "1")
	t.Setenv("GITHUB_REPO", "nope")
	if _, err := ParseConfig(); err == nil || !strings.Contains(err.Error(), "LLM_EFFORT") || !strings.Contains(err.Error(), "GITHUB_REPO must be") {
		t.Errorf("expected both errors reported, got %v", err)
	}
}
