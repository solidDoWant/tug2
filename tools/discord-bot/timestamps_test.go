package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAddUnixTimes(t *testing.T) {
	var v any
	if err := json.Unmarshal([]byte(`{
		"items": [{"name": "TestPlayerAlpha", "last_seen": "2026-11-10T06:37:04Z", "created_at": "2026-11-10T06:37:04.5+02:00"}],
		"window": {"since": "2026-11-01T00:00:00Z", "until": "2026-11-28T08:00:00Z", "history_since": null},
		"map_name": "2026-11-10",
		"played_at": "2026-11-10T06:37:04Z", "played_at_unix": 5
	}`), &v); err != nil {
		t.Fatal(err)
	}
	addUnixTimes(v)
	want := `{"items":[{"created_at":"2026-11-10T06:37:04.5+02:00","created_at_unix":1794285424,"last_seen":"2026-11-10T06:37:04Z","last_seen_unix":1794292624,"name":"TestPlayerAlpha"}],` +
		`"map_name":"2026-11-10","played_at":"2026-11-10T06:37:04Z","played_at_unix":5,` +
		`"window":{"history_since":null,"since":"2026-11-01T00:00:00Z","since_unix":1793491200,"until":"2026-11-28T08:00:00Z","until_unix":1795852800}}`
	if got := mustJSON(v); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
}

func TestSystemPromptTimes(t *testing.T) {
	prompt := buildSystemPrompt(&Config{}, true)
	for _, want := range []string{"<t:UNIX:f>", "_unix", "never <t:...>"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("system prompt does not mention %q", want)
		}
	}
}
