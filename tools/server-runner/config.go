package main

import (
	"flag"
	"fmt"
	"os"
	"slices"
	"time"
)

const separator = "--"

// Config holds runtime configuration
type Config struct {
	ConsoleLogPath  string
	RconHost        string
	RconPort        int
	RconPassword    string
	ShutdownTimeout time.Duration
	ServerArgs      []string
}

func buildFlagSet(config *Config) *flag.FlagSet {
	fs := flag.NewFlagSet("server-runner", flag.ContinueOnError)
	fs.StringVar(&config.ConsoleLogPath, "console-log", "console.log", "Path to the console log file")
	fs.StringVar(&config.RconHost, "rcon-host", "127.0.0.1", "RCON server host")
	fs.IntVar(&config.RconPort, "rcon-port", 27015, "RCON server port")
	fs.StringVar(&config.RconPassword, "rcon-password", "", "RCON server password")
	fs.DurationVar(&config.ShutdownTimeout, "shutdown-timeout", 15*time.Second, "Maximum time to wait for graceful shutdown via RCON")

	// Set custom usage message
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: server-runner [options] -- <server-command> [args...]\n\n")
		fmt.Fprintf(os.Stderr, "Options:\n")
		fs.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nThe '--' separator is required to separate server-runner flags from the server command.\n")
	}

	return fs
}

func ParseConfig(args []string) (*Config, error) {
	config := &Config{}
	fs := buildFlagSet(config)

	// Find the -- separator
	dashDashIndex := slices.Index(args, separator)

	// Determine which args to parse
	var argsToParse = args
	if dashDashIndex >= 0 {
		// If a separator was found, split args accordingly
		argsToParse = args[:dashDashIndex]
		config.ServerArgs = args[dashDashIndex+1:]
	}

	// Parse flags
	if err := fs.Parse(argsToParse); err != nil {
		if err == flag.ErrHelp {
			os.Exit(0)
		}
		return nil, fmt.Errorf("failed to parse flags: %w", err)
	}

	// If no separator was found, return an error
	if dashDashIndex < 0 {
		return nil, fmt.Errorf("missing required '--' separator between server-runner flags and server command")
	}

	return config, nil
}
