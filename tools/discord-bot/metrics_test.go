package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/anthropics/anthropic-sdk-go/v2"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestAgentMetrics(t *testing.T) {
	model := &fakeModel{inputTokens: 100, toolsPerCall: 3}
	cfg := &Config{Model: "fake", Effort: "low", MaxTokens: 1000, MaxToolRounds: 1, MaxToolCallsPerRound: 2}
	agent, _ := newTestAgent(t, model, cfg)
	m := NewMetrics(cfg)
	agent.metrics = m

	ans, err := agent.Answer(context.Background(), "1", []Turn{{Author: "TestUserOne", Text: "q"}})
	if err != nil {
		t.Fatal(err)
	}
	// Call 1 asks for 3 tools: 2 run, 1 skipped (per-round cap). Call 2 asks
	// for 3 more: the round limit is reached, so all 3 are skipped. Call 3
	// answers.
	checks := map[string]float64{
		"requests ok":   testutil.ToFloat64(m.modelRequests.WithLabelValues("fake", "ok")),
		"input tokens":  testutil.ToFloat64(m.modelTokens.WithLabelValues("fake", "input")),
		"output tokens": testutil.ToFloat64(m.modelTokens.WithLabelValues("fake", "output")),
		"tool ok":       testutil.ToFloat64(m.toolCalls.WithLabelValues("probe", "ok")),
		"tool skipped":  testutil.ToFloat64(m.toolCalls.WithLabelValues("probe", "skipped")),
	}
	want := map[string]float64{"requests ok": 3, "input tokens": 300, "output tokens": 30, "tool ok": 2, "tool skipped": 4}
	for k, v := range want {
		if checks[k] != v {
			t.Errorf("%s = %v, want %v", k, checks[k], v)
		}
	}
	if ans.Limit != "rounds" || ans.Tokens != 330 {
		t.Errorf("answer limit %q tokens %d", ans.Limit, ans.Tokens)
	}

	// The exposition has the expected series and no per-user labels.
	rec := httptest.NewRecorder()
	m.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := rec.Body.String()
	for _, want := range []string{`discordbot_model_tokens_total{model="fake",type="cache_read"} 0`,
		`discordbot_questions_total{outcome="answered"} 0`, `discordbot_info{`, "go_goroutines"} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics missing %s", want)
		}
	}
}

func TestModelResult(t *testing.T) {
	for status, want := range map[int]string{429: "rate_limited", 529: "overloaded", 500: "server_error", 400: "client_error"} {
		if got := modelResult(&anthropic.Error{StatusCode: status}); got != want {
			t.Errorf("status %d = %s, want %s", status, got, want)
		}
	}
	if got := modelResult(errors.New("dial tcp: timeout")); got != "network" {
		t.Errorf("network error = %s", got)
	}
	if got := modelResult(nil); got != "ok" {
		t.Errorf("nil = %s", got)
	}
	var nilMetrics *Metrics
	nilMetrics.Question(outcomeAnswered) // nil-safe
}
