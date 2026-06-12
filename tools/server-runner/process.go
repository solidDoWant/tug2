package main

import (
	"errors"
	"fmt"
	"os"
)

// Process represents a managed process with cleanup capability
type Process struct {
	Name string
	Stop func() error
}

// ProcessManager tracks all processes and ensures reverse-order shutdown
type ProcessManager struct {
	processes []*Process
}

func (pm *ProcessManager) Add(p *Process) {
	pm.processes = append(pm.processes, p)
}

func (pm *ProcessManager) Shutdown() error {
	errs := make([]error, 0, len(pm.processes))
	logWriter := NewPrefixedWriter("server-runner", os.Stderr)

	// Shutdown in reverse order
	for i := len(pm.processes) - 1; i >= 0; i-- {
		p := pm.processes[i]
		fmt.Fprintf(logWriter, "Shutting down %s...\n", p.Name)

		if p.Stop == nil {
			continue
		}

		if err := p.Stop(); err != nil {
			fmt.Fprintf(logWriter, "Error stopping %s: %v\n", p.Name, err)
			errs = append(errs, fmt.Errorf("failed to stop %s: %w", p.Name, err))
		}
	}

	return errors.Join(errs...)
}
