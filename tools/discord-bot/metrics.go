package main

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/anthropics/anthropic-sdk-go/v2"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics are the bot's Prometheus series, served on METRICS_ADDR. Labels are
// deliberately low-cardinality: no user IDs, names, question text or thread
// IDs, so the series stay bounded and personal data stays out of Prometheus.
// Per-user detail is in the logs.
type Metrics struct {
	registry *prometheus.Registry

	questions        *prometheus.CounterVec
	questionLimits   *prometheus.CounterVec
	questionDuration prometheus.Histogram
	questionsActive  prometheus.Gauge
	questionTokens   prometheus.Histogram

	modelRequests        *prometheus.CounterVec
	modelRequestDuration *prometheus.HistogramVec
	modelTokens          *prometheus.CounterVec

	toolCalls        *prometheus.CounterVec
	toolCallDuration *prometheus.HistogramVec

	issues *prometheus.CounterVec

	discordConnected prometheus.Gauge
	discordEvents    *prometheus.CounterVec
}

// Question outcomes, for discordbot_questions_total.
const (
	outcomeAnswered    = "answered"
	outcomeLimited     = "limited"
	outcomeRefused     = "refused"
	outcomeError       = "error"
	outcomeRateLimited = "rate_limited"
	outcomeBusy        = "busy"
	// outcomeSilent: a message in a bot thread that wasn't for the bot.
	outcomeSilent = "silent"
)

func NewMetrics(cfg *Config) *Metrics {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	m := &Metrics{
		registry: reg,
		questions: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "discordbot_questions_total",
			Help: "Questions by outcome: answered, limited (hit a per-question limit; see discordbot_question_limits_total), refused (model declined), error, rate_limited (user over their limit), busy (user already had a question running).",
		}, []string{"outcome"}),
		questionLimits: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "discordbot_question_limits_total",
			Help: "Questions that hit a per-question limit, by which: rounds (LLM_MAX_TOOL_ROUNDS), budget (LLM_TOKENS_PER_QUESTION), context (LLM_MAX_CONTEXT_TOKENS), output (LLM_MAX_TOKENS cut the reply off).",
		}, []string{"limit"}),
		questionDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "discordbot_question_duration_seconds",
			Help:    "Time to answer a question, from starting work to the reply, for questions that reached the model.",
			Buckets: []float64{1, 2, 3, 5, 8, 13, 20, 30, 45, 60, 90, 120, 180},
		}),
		questionsActive: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "discordbot_questions_in_progress",
			Help: "Questions currently being answered (at most MAX_CONCURRENT_QUESTIONS).",
		}),
		questionTokens: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "discordbot_question_tokens",
			Help:    "Tokens processed per question across all its model calls (input, cache reads and writes, and output), against LLM_TOKENS_PER_QUESTION.",
			Buckets: prometheus.ExponentialBuckets(1000, 2, 9), // 1k .. 256k
		}),
		modelRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "discordbot_model_requests_total",
			Help: "Claude API requests by model and result: ok, rate_limited (429), overloaded (529), server_error (5xx), client_error (4xx), network (no response).",
		}, []string{"model", "result"}),
		modelRequestDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "discordbot_model_request_duration_seconds",
			Help:    "Claude API request latency by model.",
			Buckets: []float64{0.5, 1, 2, 3, 5, 8, 13, 20, 30, 60, 120},
		}, []string{"model"}),
		modelTokens: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "discordbot_model_tokens_total",
			Help: "Tokens billed by the Claude API by model and type: input (uncached), cache_read, cache_write, output (thinking included). Multiply by the model's prices for spend.",
		}, []string{"model", "type"}),
		toolCalls: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "discordbot_tool_calls_total",
			Help: "Tool calls by tool and result: ok, error (the tool failed or rejected its input), skipped (not run because of a per-question or per-round limit).",
		}, []string{"tool", "result"}),
		toolCallDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "discordbot_tool_call_duration_seconds",
			Help:    "Tool call latency by tool (stats API, server query, Discord or GitHub round trips).",
			Buckets: []float64{0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5, 10},
		}, []string{"tool"}),
		issues: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "discordbot_issues_total",
			Help: "Issue drafts by kind (bug, feature) and action: drafted, filed, cancelled, failed (GitHub rejected the filing), rate_limited (reporter over their daily limit).",
		}, []string{"kind", "action"}),
		discordConnected: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "discordbot_discord_connected",
			Help: "1 while the Discord gateway connection is up, else 0.",
		}),
		discordEvents: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "discordbot_discord_connection_events_total",
			Help: "Discord gateway connection events: connect, disconnect, resume.",
		}, []string{"event"}),
	}
	reg.MustRegister(m.questions, m.questionLimits, m.questionDuration, m.questionsActive, m.questionTokens,
		m.modelRequests, m.modelRequestDuration, m.modelTokens,
		m.toolCalls, m.toolCallDuration, m.issues, m.discordConnected, m.discordEvents)

	// Constant series describing the configuration, so the dashboard can show
	// which model and limits were in effect.
	info := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "discordbot_info",
		Help: "Always 1; labels carry the running configuration.",
	}, []string{"model", "effort", "tokens_per_question", "issues_enabled", "auth"})
	reg.MustRegister(info)
	info.WithLabelValues(cfg.Model, cfg.Effort, strconv.Itoa(cfg.TokensPerQuestion), strconv.FormatBool(cfg.IssuesEnabled), cfg.AnthropicAuth).Set(1)

	// Pre-create the common series so rates start at 0 instead of absent.
	for _, o := range []string{outcomeAnswered, outcomeLimited, outcomeRefused, outcomeError, outcomeRateLimited, outcomeBusy, outcomeSilent} {
		m.questions.WithLabelValues(o)
	}
	for _, t := range []string{"input", "cache_read", "cache_write", "output"} {
		m.modelTokens.WithLabelValues(cfg.Model, t)
	}
	return m
}

// Handler serves /metrics.
func (m *Metrics) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{}))
	return mux
}

// The methods below are nil-safe, so components can run without metrics
// (as most tests do).

func (m *Metrics) Question(outcome string) {
	if m != nil {
		m.questions.WithLabelValues(outcome).Inc()
	}
}

func (m *Metrics) QuestionLimit(limit string) {
	if m != nil {
		m.questionLimits.WithLabelValues(limit).Inc()
	}
}

func (m *Metrics) QuestionFinished(d time.Duration, tokens int64) {
	if m != nil {
		m.questionDuration.Observe(d.Seconds())
		m.questionTokens.Observe(float64(tokens))
	}
}

func (m *Metrics) QuestionStarted() func() {
	if m == nil {
		return func() {}
	}
	m.questionsActive.Inc()
	return m.questionsActive.Dec
}

// ModelRequest records one Claude API call: its result, latency and usage.
func (m *Metrics) ModelRequest(model string, d time.Duration, usage *anthropic.Usage, err error) {
	if m == nil {
		return
	}
	m.modelRequests.WithLabelValues(model, modelResult(err)).Inc()
	m.modelRequestDuration.WithLabelValues(model).Observe(d.Seconds())
	if usage != nil {
		m.modelTokens.WithLabelValues(model, "input").Add(float64(usage.InputTokens))
		m.modelTokens.WithLabelValues(model, "cache_read").Add(float64(usage.CacheReadInputTokens))
		m.modelTokens.WithLabelValues(model, "cache_write").Add(float64(usage.CacheCreationInputTokens))
		m.modelTokens.WithLabelValues(model, "output").Add(float64(usage.OutputTokens))
	}
}

// modelResult classifies a Claude API error by HTTP status.
func modelResult(err error) string {
	if err == nil {
		return "ok"
	}
	var apiErr *anthropic.Error
	if !errors.As(err, &apiErr) {
		return "network"
	}
	switch {
	case apiErr.StatusCode == http.StatusTooManyRequests:
		return "rate_limited"
	case apiErr.StatusCode == 529:
		return "overloaded"
	case apiErr.StatusCode >= 500:
		return "server_error"
	default:
		return "client_error"
	}
}

func (m *Metrics) ToolCall(tool, result string, d time.Duration) {
	if m == nil {
		return
	}
	m.toolCalls.WithLabelValues(tool, result).Inc()
	if result != "skipped" {
		m.toolCallDuration.WithLabelValues(tool).Observe(d.Seconds())
	}
}

func (m *Metrics) Issue(kind IssueKind, action string) {
	if m != nil {
		m.issues.WithLabelValues(string(kind), action).Inc()
	}
}

func (m *Metrics) DiscordConnection(event string, connected bool) {
	if m == nil {
		return
	}
	m.discordEvents.WithLabelValues(event).Inc()
	if connected {
		m.discordConnected.Set(1)
	} else {
		m.discordConnected.Set(0)
	}
}
