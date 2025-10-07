package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"github.com/drone/envsubst"
)

// This is a simple program that parses CLI args and matching args from the environment.
// This is needed because a shell is (intentionally) unavailable, to allow for easier
// server startup configuration.
func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}
}

func run(osArgs []string) error {
	args := make([]string, 0, len(osArgs))
	for _, providedArg := range osArgs {
		arg, err := envsubst.EvalEnv(providedArg)
		if err != nil {
			return fmt.Errorf("failed to evaluate %q: %w", providedArg, err)
		}

		args = append(args, arg)
	}

	if len(args) < 1 {
		return errors.New("no command provided")
	}

	cmd := args[0]
	cmdPath, err := exec.LookPath(cmd)
	if err != nil && !errors.Is(err, exec.ErrDot) {
		return fmt.Errorf("failed to find command %q: %w", cmd, err)
	}

	if err := syscall.Exec(cmdPath, args, os.Environ()); err != nil {
		return fmt.Errorf("failed to exec command %q: %w", cmdPath, err)
	}

	// This will never be hit but is needed to satisfy the compiler
	return nil
}
