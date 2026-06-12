package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func StartXvfb(pm *ProcessManager, done chan<- error) (int, error) {
	// Create a pipe to read the display number from Xvfb
	r, w, err := os.Pipe()
	if err != nil {
		return 0, fmt.Errorf("failed to create pipe: %w", err)
	}
	defer r.Close()
	defer w.Close()

	xvfbCmd := exec.Command("Xvfb", "-displayfd", "3", "-screen", "0", "1024x768x24")
	// Don't forward signals to child processes, so that shutdown can be done in order and gracefully
	xvfbCmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: 0}
	xvfbCmd.ExtraFiles = []*os.File{w} // FD 3 for Xvfb to write display number
	SetupPrefixedStreams(xvfbCmd, "Xvfb")

	if err := xvfbCmd.Start(); err != nil {
		return 0, fmt.Errorf("failed to start Xvfb process: %w", err)
	}

	// Read the display number from the pipe
	displayNumber, err := readDisplayNumber(r)
	if err != nil {
		xvfbCmd.Process.Kill()
		return 0, fmt.Errorf("failed to read display number from Xvfb: %w", err)
	}

	pm.Add(&Process{
		Name: "Xvfb",
		Stop: func() error {
			if xvfbCmd.Process == nil {
				return nil
			}
			err := xvfbCmd.Process.Kill()
			if err != nil && !errors.Is(err, os.ErrProcessDone) {
				return fmt.Errorf("failed to kill Xvfb process: %w", err)
			}
			return nil
		},
	})

	// Monitor Xvfb process
	go func() {
		done <- xvfbCmd.Wait()
	}()

	return displayNumber, nil
}

func readDisplayNumber(r io.Reader) (int, error) {
	scanner := bufio.NewScanner(r)
	if scanner.Scan() {
		providedDisplayNumber := strings.TrimSpace(scanner.Text())
		// Parse and validate it's a number
		displayNumber, err := strconv.Atoi(providedDisplayNumber)
		if err != nil {
			return 0, fmt.Errorf("invalid display number: %q", providedDisplayNumber)
		}

		return displayNumber, nil
	}

	if err := scanner.Err(); err != nil {
		return 0, err
	}

	return 0, fmt.Errorf("no display number received from Xvfb")
}
