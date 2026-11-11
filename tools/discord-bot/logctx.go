package main

import (
	"context"
	"log/slog"
)

// Every line logged while answering a question carries the same attributes
// (message, thread, user), so one request's lines can be found together:
// filter on message (the ID of the Discord message that asked) or thread.

type loggerKey struct{}

// withLogger returns ctx carrying l, for logger to find.
func withLogger(ctx context.Context, l *slog.Logger) context.Context {
	return context.WithValue(ctx, loggerKey{}, l)
}

// logger is the request's logger, or the default one outside a request.
func logger(ctx context.Context) *slog.Logger {
	if l, ok := ctx.Value(loggerKey{}).(*slog.Logger); ok {
		return l
	}
	return slog.Default()
}
