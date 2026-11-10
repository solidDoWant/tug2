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
	if os.Getenv("ANTHROPIC_API_KEY") == "" {
		return errors.New("configuration error: ANTHROPIC_API_KEY is required")
	}

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
	tools := NewToolset(cfg, NewStatsClient(cfg.Servers), issues, session)
	agent := NewAgent(cfg, tools, issues != nil)
	bot := NewBot(ctx, cfg, session, agent, issues)
	if err := bot.Open(); err != nil {
		return fmt.Errorf("connecting to Discord: %w", err)
	}
	defer bot.Close()

	slog.Info("started", "model", cfg.Model, "effort", cfg.Effort, "servers", cfg.ServerOrder,
		"channel", cfg.ChannelID, "issues", issues != nil,
		"readable_channels", len(cfg.ReadableChannels), "user_limit_overrides", len(cfg.UserLimits))

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
	healthErr := make(chan error, 1)
	go func() {
		if err := health.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			healthErr <- err
		}
	}()

	select {
	case err := <-healthErr:
		return fmt.Errorf("health server: %w", err)
	case <-ctx.Done():
		slog.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return health.Shutdown(shutdownCtx)
	}
}
