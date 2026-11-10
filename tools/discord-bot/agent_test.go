package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/anthropics/anthropic-sdk-go/v2"
)

// fakeModel stands in for the Messages API: it asks for a tool on every call
// until tool_choice is "none", then answers. Each call reports inputTokens.
type fakeModel struct {
	mu          sync.Mutex
	calls       int
	inputTokens int
	// ignoreLimit makes the model keep asking for tools regardless.
	ignoreLimit bool
	// toolsPerCall is how many tool calls each response asks for (default 1).
	toolsPerCall  int
	toolChoices   []string
	cacheControls []string
}

func (f *fakeModel) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ToolChoice struct {
			Type string `json:"type"`
		} `json:"tool_choice"`
		CacheControl struct {
			Type string `json:"type"`
		} `json:"cache_control"`
		Messages []json.RawMessage `json:"messages"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	// The bot withholds results with "Not run: ..." when a limit is reached;
	// a well-behaved model then answers instead of asking for more.
	limitHit := len(req.Messages) > 0 && strings.Contains(string(req.Messages[len(req.Messages)-1]), "Not run: this question")

	f.mu.Lock()
	f.calls++
	n := f.calls
	f.toolChoices = append(f.toolChoices, req.ToolChoice.Type)
	f.cacheControls = append(f.cacheControls, req.CacheControl.Type)
	f.mu.Unlock()

	calls := max(f.toolsPerCall, 1)
	var uses []string
	for i := 0; i < calls; i++ {
		uses = append(uses, fmt.Sprintf(`{"type":"tool_use","id":"tu_%d_%d","name":"probe","input":{}}`, n, i))
	}
	content := "[" + strings.Join(uses, ",") + "]"
	stop := "tool_use"
	if limitHit && !f.ignoreLimit {
		content = `[{"type":"text","text":"Here's what I found so far."}]`
		stop = "end_turn"
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"id":"msg_%d","type":"message","role":"assistant","model":"fake","content":%s,"stop_reason":%q,"usage":{"input_tokens":%d,"output_tokens":10}}`,
		n, content, stop, f.inputTokens)
}

func newTestAgent(t *testing.T, model *fakeModel, cfg *Config) (*Agent, *int) {
	server := httptest.NewServer(model)
	t.Cleanup(server.Close)
	t.Setenv("ANTHROPIC_BASE_URL", server.URL)
	t.Setenv("ANTHROPIC_API_KEY", "test")

	toolRuns := 0
	ts := &Toolset{tools: map[string]tool{}}
	ts.add("probe", "test tool", map[string]any{}, nil, func(context.Context, *toolContext, json.RawMessage) (any, error) {
		toolRuns++
		return map[string]string{"ok": "yes"}, nil
	})
	p := ts.tools["probe"].param
	ts.params = append(ts.params, anthropicToolUnion(&p))
	return NewAgent(cfg, ts, false, nil), &toolRuns
}

func TestAgentStopsAtTokenBudget(t *testing.T) {
	model := &fakeModel{inputTokens: 40000}
	cfg := &Config{Model: "fake", Effort: "low", MaxTokens: 1000, MaxToolRounds: 50, TokensPerQuestion: 100000}
	agent, toolRuns := newTestAgent(t, model, cfg)

	ans, err := agent.Answer(context.Background(), "1", []Turn{{Author: "TestUserOne", Text: "read everything"}})
	if err != nil {
		t.Fatal(err)
	}
	// Call 1 (40k spent) may be followed by a ~40k call: 80k <= 100k, go on.
	// After call 2 (80k spent) another ~40k call would reach 120k, so its
	// results are withheld and call 3 is the tools-disabled wrap-up.
	if *toolRuns != 2 || model.calls != 3 {
		t.Errorf("tool runs = %d, model calls = %d; want 2 and 3", *toolRuns, model.calls)
	}
	// tool_choice must never change (it would invalidate the cached
	// conversation), and every request uses automatic caching.
	for i := range model.toolChoices {
		if model.toolChoices[i] != "" || model.cacheControls[i] != "ephemeral" {
			t.Errorf("call %d: tool_choice %q, cache_control %q", i, model.toolChoices[i], model.cacheControls[i])
		}
	}
	if !strings.Contains(ans.Text, "what I found so far") {
		t.Errorf("answer = %q", ans.Text)
	}
}

func TestAgentStopsAtContextCap(t *testing.T) {
	model := &fakeModel{inputTokens: 70000}
	cfg := &Config{Model: "fake", Effort: "low", MaxTokens: 1000, MaxToolRounds: 50, MaxContextTokens: 80000}
	agent, toolRuns := newTestAgent(t, model, cfg)
	agent.tools.tools["probe"] = tool{param: agent.tools.tools["probe"].param,
		run: func(context.Context, *toolContext, json.RawMessage) (any, error) {
			*toolRuns++
			return strings.Repeat("x", 60000), nil // ~20k tokens: 70k + 20k > 80k
		}}

	if _, err := agent.Answer(context.Background(), "1", []Turn{{Author: "TestUserOne", Text: "q"}}); err != nil {
		t.Fatal(err)
	}
	if model.calls != 2 {
		t.Errorf("model calls = %d; want the second call to be the wrap-up", model.calls)
	}
}

// TestAgentFinalCallIgnoresMoreTools covers a model that keeps asking for
// tools after being told to stop: the bot answers instead of looping.
func TestAgentFinalCallIgnoresMoreTools(t *testing.T) {
	model := &fakeModel{inputTokens: 10, ignoreLimit: true}
	cfg := &Config{Model: "fake", Effort: "low", MaxTokens: 1000, MaxToolRounds: 2}
	agent, _ := newTestAgent(t, model, cfg)
	ans, err := agent.Answer(context.Background(), "1", []Turn{{Author: "TestUserOne", Text: "q"}})
	if err != nil {
		t.Fatal(err)
	}
	if model.calls != 4 || !strings.Contains(ans.Text, "more lookups than I'm allowed") {
		t.Errorf("calls = %d, answer %q", model.calls, ans.Text)
	}
}

func TestAgentCapsToolCallsPerRound(t *testing.T) {
	model := &fakeModel{inputTokens: 10, toolsPerCall: 10}
	cfg := &Config{Model: "fake", Effort: "low", MaxTokens: 1000, MaxToolRounds: 1, MaxToolCallsPerRound: 4}
	agent, toolRuns := newTestAgent(t, model, cfg)

	if _, err := agent.Answer(context.Background(), "1", []Turn{{Author: "TestUserOne", Text: "q"}}); err != nil {
		t.Fatal(err)
	}
	if *toolRuns != 4 {
		t.Errorf("tool runs = %d, want 4 of the 10 requested", *toolRuns)
	}
}

func TestAgentStopsAtRoundLimit(t *testing.T) {
	model := &fakeModel{inputTokens: 10}
	cfg := &Config{Model: "fake", Effort: "low", MaxTokens: 1000, MaxToolRounds: 3}
	agent, toolRuns := newTestAgent(t, model, cfg)

	ans, err := agent.Answer(context.Background(), "1", []Turn{{Author: "TestUserOne", Text: "q"}})
	if err != nil {
		t.Fatal(err)
	}
	if *toolRuns != 3 || model.calls != 5 || ans.Text == "" {
		t.Errorf("tool runs = %d, model calls = %d, answer %q; want 3, 5 and an answer", *toolRuns, model.calls, ans.Text)
	}
}

func anthropicToolUnion(p *anthropic.ToolParam) anthropic.ToolUnionParam {
	return anthropic.ToolUnionParam{OfTool: p}
}
