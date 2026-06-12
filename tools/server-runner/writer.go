package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
)

// outputMutex ensures stdout and stderr writes are not interleaved
var outputMutex sync.Mutex

// PrefixedWriter wraps an io.Writer and prefixes each line with a given prefix
// Uses a global mutex to prevent interleaving between different writers
type PrefixedWriter struct {
	prefix      string
	writer      io.Writer
	buffer      bytes.Buffer
	needsPrefix bool
}

func NewPrefixedWriter(label string, writer io.Writer) *PrefixedWriter {
	return &PrefixedWriter{
		prefix:      fmt.Sprintf("[%s] ", label),
		writer:      writer,
		needsPrefix: true,
	}
}

func (pw *PrefixedWriter) Write(p []byte) (n int, err error) {
	outputMutex.Lock()
	defer outputMutex.Unlock()

	// Process input buffer to handle line breaks
	// We write to an internal buffer first to ensure atomic writes under the mutex
	input := p

	for len(input) > 0 {
		// Find the next line break (\n, \r, or \r\n)
		nlIndex := bytes.IndexByte(input, '\n')
		crIndex := bytes.IndexByte(input, '\r')

		var breakIndex int
		var breakLen int

		if nlIndex == -1 && crIndex == -1 {
			// No line break found - write with prefix if needed, then done
			if pw.needsPrefix {
				pw.buffer.WriteString(pw.prefix)
				pw.needsPrefix = false
			}
			pw.buffer.Write(input)
			break
		}

		// Determine which line break comes first
		if nlIndex == -1 {
			breakIndex = crIndex
			breakLen = 1
		} else if crIndex == -1 {
			breakIndex = nlIndex
			breakLen = 1
		} else if crIndex < nlIndex {
			// Check for \r\n sequence
			if crIndex+1 == nlIndex {
				breakIndex = crIndex
				breakLen = 2 // \r\n
			} else {
				breakIndex = crIndex
				breakLen = 1 // standalone \r
			}
		} else {
			breakIndex = nlIndex
			breakLen = 1 // standalone \n
		}

		// Write the line (including the line break) with prefix if needed
		if pw.needsPrefix {
			pw.buffer.WriteString(pw.prefix)
		}
		pw.buffer.Write(input[:breakIndex+breakLen])

		// Flush the complete line
		if _, err := pw.writer.Write(pw.buffer.Bytes()); err != nil {
			return len(p) - len(input), err
		}
		pw.buffer.Reset()
		pw.needsPrefix = true

		// Continue with remaining input
		input = input[breakIndex+breakLen:]
	}

	// Flush any remaining buffered content without line break
	if pw.buffer.Len() > 0 {
		if _, err := pw.writer.Write(pw.buffer.Bytes()); err != nil {
			return len(p) - len(input), err
		}
		pw.buffer.Reset()
	}

	return len(p), nil
}

// SetupPrefixedStreams configures stdout and stderr for a command with prefixed writers
func SetupPrefixedStreams(cmd *exec.Cmd, label string) {
	cmd.Stdout = NewPrefixedWriter(label, os.Stdout)
	cmd.Stderr = NewPrefixedWriter(label, os.Stderr)
}
