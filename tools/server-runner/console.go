package main

import (
	"fmt"
	"os"

	"github.com/hpcloud/tail"
)

func StartConsoleTail(pm *ProcessManager, consoleLogPath string) error {
	// Truncate the console log file before tailing
	if err := truncateConsoleLog(consoleLogPath); err != nil {
		return fmt.Errorf("failed to truncate console log: %w", err)
	}

	// Create prefixed writers for consistent output formatting
	stdoutWriter := NewPrefixedWriter(consoleLogPath, os.Stdout)
	stderrWriter := NewPrefixedWriter(consoleLogPath, os.Stderr)

	t, err := tail.TailFile(consoleLogPath, tail.Config{
		Follow: true,
		ReOpen: true,
	})
	if err != nil {
		return fmt.Errorf("failed to start tailing console log file %q: %w", consoleLogPath, err)
	}

	pm.Add(&Process{
		Name: "console-tail",
		Stop: func() error {
			if err := t.Stop(); err != nil {
				return fmt.Errorf("failed to stop console tail: %w", err)
			}
			return nil
		},
	})

	// Start goroutine to copy tail output to stdout
	go func() {
		for line := range t.Lines {
			if line.Err != nil {
				fmt.Fprintf(stderrWriter, "Error tailing %s: %v\n", consoleLogPath, line.Err)
				continue
			}
			fmt.Fprintln(stdoutWriter, line.Text)
		}
	}()

	return nil
}

func truncateConsoleLog(consoleLogPath string) error {
	f, err := os.OpenFile(consoleLogPath, os.O_WRONLY|os.O_TRUNC|os.O_CREATE, 0644)
	if err != nil {
		if os.IsNotExist(err) {
			// If the file does not exist, nothing to truncate
			return nil
		}

		return fmt.Errorf("failed to truncate console log %q: %w", consoleLogPath, err)
	}

	if err := f.Close(); err != nil {
		return fmt.Errorf("failed to close console log %q: %w", consoleLogPath, err)
	}

	return nil
}
