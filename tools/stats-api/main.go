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
	httpServer := &http.Server{
		Addr:         config.ListenAddr,
		Handler:      server.Routes(),
		ReadTimeout:  config.ReadTimeout,
		WriteTimeout: config.WriteTimeout,
	}

	serverErr := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", config.ListenAddr)
		serverErr <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-serverErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("server error: %w", err)
		}

		return nil
	case <-ctx.Done():
		slog.Info("received signal, shutting down")

		shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancelShutdown()

		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("graceful shutdown failed: %w", err)
		}

		return nil
	}
}
