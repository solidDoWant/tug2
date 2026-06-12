package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"github.com/drone/envsubst"
)

func main() {
	logWriter := NewPrefixedWriter("server-runner", os.Stderr)

	args := os.Args[1:]
	if err := evalArgs(args); err != nil {
		fmt.Fprintf(logWriter, "Argument evaluation error: %v\n", err)
		os.Exit(1)
	}

	config, err := ParseConfig(args)
	if err != nil {
		fmt.Fprintf(logWriter, "Configuration error: %v\n", err)
		os.Exit(1)
	}

	ctx := context.Background()
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := run(ctx, config); err != nil {
		fmt.Fprintf(logWriter, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, config *Config) (err error) {
	pm := &ProcessManager{}

	// Ensure cleanup on exit
	defer func() {
		if shutdownErr := pm.Shutdown(); shutdownErr != nil {
			err = errors.Join(err, fmt.Errorf("shutdown failed: %w", shutdownErr))
		}
	}()

	// Start Xvfb and get the display ID
	xvfbDone := make(chan error, 1)
	displayID, err := StartXvfb(pm, xvfbDone)
	if err != nil {
		return fmt.Errorf("failed to start Xvfb: %w", err)
	}

	// Start tailing console.log
	if err := StartConsoleTail(pm, config.ConsoleLogPath); err != nil {
		return fmt.Errorf("failed to start console tail: %w", err)
	}

	// Start the main server process with the display ID
	serverDone := make(chan error, 1)
	if err := StartServer(pm, config, displayID, serverDone); err != nil {
		return fmt.Errorf("failed to start server: %w", err)
	}

	// Wait for either the server to exit, Xvfb to crash, or a signal
	select {
	case err := <-serverDone:
		if err != nil {
			return fmt.Errorf("server exited with error: %w", err)
		}

		return nil
	case err := <-xvfbDone:
		if err != nil {
			return fmt.Errorf("xvfb crashed: %w", err)
		}

		return fmt.Errorf("xvfb exited unexpectedly")
	case <-ctx.Done():
		fmt.Fprintln(NewPrefixedWriter("server-runner", os.Stderr), "Received signal, shutting down...")
		return nil
	}
}

func StartServer(pm *ProcessManager, config *Config, displayID int, done chan<- error) error {
	if len(config.ServerArgs) < 1 {
		return errors.New("no command specified to execute")
	}

	serverCmd := exec.Command(config.ServerArgs[0], config.ServerArgs[1:]...)
	// Don't forward signals to child processes, so that shutdown can be done in order and gracefully
	serverCmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: 0}
	SetupPrefixedStreams(serverCmd, "server")
	serverCmd.Stdin = nil // Redirect from /dev/null equivalent
	serverCmd.Env = append(os.Environ(), fmt.Sprintf("DISPLAY=:%d", displayID))

	pm.Add(&Process{
		Name: "server",
		Stop: func() error {
			if serverCmd.Process == nil {
				return nil
			}

			if serverCmd.ProcessState != nil && serverCmd.ProcessState.Exited() {
				return nil
			}

			// Attempt graceful shutdown via RCON
			err := gracefulShutdownServer(
				config.RconHost,
				config.RconPort,
				config.RconPassword,
				config.ShutdownTimeout,
				serverCmd.Process,
			)

			if err == nil {
				return nil
			}

			err = fmt.Errorf("graceful shutdown via RCON failed: %w", err)

			// Graceful shutdown failed, force kill
			killErr := serverCmd.Process.Kill()
			if killErr != nil && !errors.Is(killErr, os.ErrProcessDone) {
				return errors.Join(err, fmt.Errorf("force kill also failed: %w", killErr))
			}

			return err
		},
	})

	if err := serverCmd.Start(); err != nil {
		return fmt.Errorf("failed to start server command: %w", err)
	}

	// Monitor server process
	go func() {
		done <- serverCmd.Wait()
	}()

	return nil
}

func evalArgs(args []string) error {
	for i, arg := range args {
		arg, err := envsubst.EvalEnv(arg)
		if err != nil {
			return fmt.Errorf("failed to evaluate %q: %w", arg, err)
		}

		args[i] = arg
	}

	return nil
}
