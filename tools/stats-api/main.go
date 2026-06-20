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
	// Structured JSON logs to stderr so a log aggregator can parse the fields.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))

	// Signal handling lives here so run can be driven by a cancellable context
	// and remain free of os.Exit, letting its defers run on every path.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := run(ctx); err != nil {
		// slog has no Fatal; log the error then exit non-zero. run has already
		// unwound its defers (store.Close, cancels) by the time we get here.
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	config, err := ParseConfig()
	if err != nil {
		return fmt.Errorf("configuration error: %w", err)
	}

	// Connect to the database up front so a misconfiguration fails fast.
	connectCtx, cancelConnect := context.WithTimeout(ctx, 10*time.Second)
	defer cancelConnect()

	store, err := NewStore(connectCtx, config.DatabaseURL)
	if err != nil {
		return fmt.Errorf("failed to connect to database: %w", err)
	}
	defer store.Close()

	slog.Info("connected to database")

	server := NewServer(store)
	metrics := NewMetrics(store.Stat)

	// The metrics endpoint is wrapped around the API mux so every request is
	// counted and timed; metrics themselves are served on a separate listener.
	httpServer := &http.Server{
		Addr:         config.ListenAddr,
		Handler:      metrics.Instrument(server.Routes()),
		ReadTimeout:  config.ReadTimeout,
		WriteTimeout: config.WriteTimeout,
	}
	metricsServer := &http.Server{
		Addr:         config.MetricsAddr,
		Handler:      metrics.Handler(),
		ReadTimeout:  config.ReadTimeout,
		WriteTimeout: config.WriteTimeout,
	}

	// Buffered for both servers so a failing goroutine never blocks on send.
	serverErr := make(chan error, 2)
	serve := func(name string, srv *http.Server) {
		slog.Info("listening", "server", name, "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- fmt.Errorf("%s server error: %w", name, err)
		}
	}
	go serve("api", httpServer)
	go serve("metrics", metricsServer)

	select {
	case err := <-serverErr:
		return err
	case <-ctx.Done():
		slog.Info("received signal, shutting down")

		shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancelShutdown()

		// Shut both listeners down; join so neither error is dropped.
		if err := errors.Join(
			httpServer.Shutdown(shutdownCtx),
			metricsServer.Shutdown(shutdownCtx),
		); err != nil {
			return fmt.Errorf("graceful shutdown failed: %w", err)
		}

		return nil
	}
}
