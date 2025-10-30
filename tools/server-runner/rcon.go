package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/gorcon/rcon"
)

// gracefulShutdownServer attempts to shut down the server via RCON quit command.
// It returns an error if the shutdown times out, nil if successful.
func gracefulShutdownServer(host string, port int, password string, timeout time.Duration, process *os.Process) error {
	if process == nil {
		return nil
	}

	deadline := time.Now().Add(timeout)

	// Establish network connection with deadline
	address := net.JoinHostPort(host, strconv.Itoa(port))
	conn, err := net.DialTimeout("tcp", address, time.Until(deadline))
	if err != nil {
		return fmt.Errorf("failed to dial RCON server at %s: %w", address, err)
	}
	defer conn.Close()

	// Set deadline for the connection
	conn.SetDeadline(deadline)

	// Open RCON connection with the remaining deadline
	rconConn, err := rcon.Open(conn, password)
	if err != nil {
		return fmt.Errorf("failed to authenticate with RCON server at %s: %w", address, err)
	}
	defer rconConn.Close()

	// Send quit command
	_, err = rconConn.Execute("quit")
	if err != nil {
		return fmt.Errorf("failed to execute RCON quit command: %w", err)
	}

	// Wait for process to exit within the remaining timeout
	done := make(chan error, 1)
	go func() {
		_, err := process.Wait()
		done <- err
	}()

	select {
	case <-done:
		// Process exited successfully
		return nil
	case <-time.After(time.Until(deadline)):
		// Timeout waiting for process to exit
		return fmt.Errorf("server did not shut down within %v after RCON quit command", timeout)
	}
}
