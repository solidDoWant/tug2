package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := run(ctx); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	cfg, err := ParseConfig()
	if err != nil {
		return fmt.Errorf("configuration error: %w", err)
	}

	metrics := NewMetrics(cfg)

	var issues *IssueTracker
	if cfg.IssuesEnabled {
		setupCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		issues, err = NewIssueTracker(setupCtx, cfg)
		cancel()
		if err != nil {
			return fmt.Errorf("setting up GitHub: %w", err)
		}
	} else {
		slog.Warn("GitHub App or GITHUB_REPO not configured; bug reports and feature requests are disabled")
	}

	session, err := NewSession(cfg.DiscordToken)
	if err != nil {
		return err
	}
	channels := &DiscordChannels{session: session, botChannelID: cfg.ChannelID, descriptions: cfg.ChannelDescriptions, refreshMember: true}
	var db statsDB
	if cfg.StatsDBURL != "" {
		pg, err := NewPostgresStatsDB(cfg.StatsDBURL)
		if err != nil {
			return err
		}
		defer pg.Close()
		db = pg
	}
	tools := NewToolset(cfg, NewStatsClient(cfg.Servers), issues, channels, db)
	agent := NewAgent(cfg, tools, issues != nil, metrics)

	checkCtx, cancelCheck := context.WithTimeout(ctx, 30*time.Second)
	err = agent.CheckAccess(checkCtx)
	cancelCheck()
	if err != nil {
		return err
	}
	slog.Info("Claude API access confirmed", "auth", cfg.AnthropicAuth, "model", cfg.Model)
	bot := NewBot(ctx, cfg, session, agent, issues, metrics, channels)
	if err := bot.Open(); err != nil {
		return fmt.Errorf("connecting to Discord: %w", err)
	}
	defer bot.Close()

	slog.Info("started", "model", cfg.Model, "effort", cfg.Effort, "servers", cfg.ServerOrder,
		"channel", cfg.ChannelID, "issues", issues != nil, "query_stats", cfg.statsDBServers(),
		"channel_descriptions", len(cfg.ChannelDescriptions), "user_limit_overrides", len(cfg.UserLimits))

	// Probes: liveness is the process; readiness is the Discord gateway session.
	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if !bot.Ready() {
			http.Error(w, "not connected to Discord", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("ok"))
	})
	health := &http.Server{Addr: cfg.HealthAddr, Handler: mux, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second}
	metricsServer := &http.Server{Addr: cfg.MetricsAddr, Handler: metrics.Handler(), ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second}

	serverErr := make(chan error, 2)
	serve := func(name string, srv *http.Server) {
		slog.Info("listening", "server", name, "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- fmt.Errorf("%s server: %w", name, err)
		}
	}
	go serve("health", health)
	go serve("metrics", metricsServer)

	select {
	case err := <-serverErr:
		return err
	case <-ctx.Done():
		slog.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return errors.Join(health.Shutdown(shutdownCtx), metricsServer.Shutdown(shutdownCtx))
	}
}
