package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

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

	if len(config.ServerArgs) < 1 {
		fmt.Fprintf(logWriter, "Error: no command specified to execute\n")
		os.Exit(1)
	}

	// Run the server process
	cmd := exec.Command(config.ServerArgs[0], config.ServerArgs[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(logWriter, "Failed to start server: %v\n", err)
		os.Exit(1)
	}

	// Start monitoring memory usage
	monitorCtx, cancelMonitor := context.WithCancel(context.Background())
	var peakVmSizeMB atomic.Uint64
	go monitorMemory(monitorCtx, cmd.Process.Pid, &peakVmSizeMB)

	// Set up signal handling for graceful shutdown
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	// Wait for either process to exit or signal
	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	var exitErr error
	gracefulStop := false
	select {
	case exitErr = <-done:
		// Process exited normally
	case <-ctx.Done():
		// Signal received - attempt graceful shutdown
		fmt.Fprintf(logWriter, "Received signal, attempting graceful shutdown...\n")
		if err := gracefulShutdownServer(config.RconHost, config.RconPort, config.RconPassword, config.ShutdownTimeout, cmd.Process); err != nil {
			fmt.Fprintf(logWriter, "Graceful shutdown failed: %v, force killing process...\n", err)
			cmd.Process.Kill()
		} else {
			// We deliberately stopped a running server via RCON. The native Linux
			// srcds returns a non-zero exit code on `quit`, so ignore it and report
			// success for this operator-initiated shutdown.
			gracefulStop = true
		}
		exitErr = <-done
	}

	cancelMonitor()

	exitCode := getExitCode(exitErr)
	if cmd.Process != nil {
		printResourceUsage(logWriter, cmd.Process.Pid, &peakVmSizeMB)
	}

	// Treat exit code 139 (SIGSEGV) as success due to a Linux build-specific bug,
	// and treat a successful graceful shutdown as success regardless of srcds's exit code.
	if exitCode == 139 || gracefulStop {
		exitCode = 0
	}
	os.Exit(exitCode)
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

func getExitCode(err error) int {
	if err == nil {
		return 0
	}

	exitErr, ok := err.(*exec.ExitError)
	if !ok {
		return 1
	}

	status, ok := exitErr.Sys().(syscall.WaitStatus)
	if !ok {
		return 1
	}

	if status.Signaled() {
		// Process was killed by signal - return 128 + signal number
		return 128 + int(status.Signal())
	}

	return status.ExitStatus()
}

func monitorMemory(ctx context.Context, pid int, peakVmSize *atomic.Uint64) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			vmSizeMB := getVmSize(pid)
			if vmSizeMB <= 0 {
				continue
			}

			// Store as uint64 MB value
			currentPeak := peakVmSize.Load()
			vmSizeUint := uint64(vmSizeMB)
			if vmSizeUint > currentPeak {
				peakVmSize.Store(vmSizeUint)
			}
		}
	}
}

func getVmSize(pid int) float64 {
	statusPath := fmt.Sprintf("/proc/%d/status", pid)
	file, err := os.Open(statusPath)
	if err != nil {
		return 0
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "VmSize:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				vmSizeKB, err := strconv.ParseFloat(fields[1], 64)
				if err == nil {
					return vmSizeKB / 1024.0 // Convert KB to MB
				}
			}
		}
	}
	return 0
}

func printResourceUsage(logWriter *PrefixedWriter, pid int, peakVmSize *atomic.Uint64) {
	var rusage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_CHILDREN, &rusage); err != nil {
		fmt.Fprintf(logWriter, "Failed to get resource usage: %v\n", err)
		return
	}

	// Convert maxrss from KB to MB for readability
	maxRssMB := float64(rusage.Maxrss) / 1024.0

	peakVmSizeMB := peakVmSize.Load()

	if peakVmSizeMB > 0 {
		fmt.Fprintf(logWriter, "Server resource usage - Peak RSS: %.2f MB, Peak Virtual Memory: %d MB\n", maxRssMB, peakVmSizeMB)
		return
	}
	fmt.Fprintf(logWriter, "Server resource usage - Peak RSS: %.2f MB\n", maxRssMB)
}
