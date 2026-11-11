// Package server starts one detached kotlin-lsp server per Gradle root and connects to it.
package server

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultServer = "/opt/homebrew/bin/kotlin-lsp"
	pollInterval  = 100 * time.Millisecond
	stopTimeout   = 30 * time.Second
)

// startTimeout is a variable so that tests can make it shorter.
var startTimeout = 300 * time.Second

// Ensure returns a connection to the server of root. If no server listens, it starts one with
// env. A lock on <cacheDir>/lock makes sure that clients which start at the same time share
// one server.
func Ensure(root, cacheDir string, env []string) (net.Conn, error) {
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return nil, fmt.Errorf("create cache folder %s: %w", cacheDir, err)
	}
	lockPath := filepath.Join(cacheDir, "lock")
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open lock %s: %w", lockPath, err)
	}
	// Closing the file releases the lock.
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return nil, fmt.Errorf("lock %s: %w", lockPath, err)
	}

	if conn, err := connect(cacheDir); err == nil {
		return conn, nil
	}
	return start(root, cacheDir, env)
}

func start(root, cacheDir string, env []string) (net.Conn, error) {
	portPath := filepath.Join(cacheDir, "port")
	// The server can leave the file behind when it stops.
	if err := os.Remove(portPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("remove old port file %s: %w", portPath, err)
	}
	logPath := filepath.Join(cacheDir, "server.log")
	logFile, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open server log %s: %w", logPath, err)
	}
	defer logFile.Close()

	command := exec.Command(serverPath(),
		"--socket", "127.0.0.1:0",
		"--multi-client",
		"--system-path", cacheDir,
		"--port-file", portPath)
	command.Dir = root
	command.Env = env
	command.Stdout = logFile
	command.Stderr = logFile
	// The server outlives the client, so it must not get the signals of the terminal of the client.
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		return nil, fmt.Errorf("start server %s for %s: %w", command.Path, root, err)
	}
	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	pidPath := filepath.Join(cacheDir, "pid")
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(command.Process.Pid)), 0o644); err != nil {
		return nil, fmt.Errorf("write pid file %s: %w", pidPath, err)
	}

	deadline := time.Now().Add(startTimeout)
	for {
		if conn, err := connect(cacheDir); err == nil {
			return conn, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("server for %s does not listen after %s, see %s", root, startTimeout, logPath)
		}
		select {
		case <-exited:
			return nil, fmt.Errorf("server for %s exited before it listened (%s), see %s", root, command.ProcessState, logPath)
		case <-time.After(pollInterval):
		}
	}
}

// Stop sends SIGTERM to the server of cacheDir and waits until its port closes.
// With no server that listens, it does nothing.
func Stop(cacheDir string) error {
	port, err := readPort(cacheDir)
	if err != nil {
		return nil
	}
	conn, err := dial(port)
	if err != nil {
		return nil
	}
	conn.Close()

	pidPath := filepath.Join(cacheDir, "pid")
	content, err := os.ReadFile(pidPath)
	if err != nil {
		return fmt.Errorf("read pid file %s: %w", pidPath, err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(content)))
	if err != nil {
		return fmt.Errorf("invalid pid in %s: %w", pidPath, err)
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return fmt.Errorf("stop server %d of %s: %w", pid, cacheDir, err)
	}

	deadline := time.Now().Add(stopTimeout)
	for {
		conn, err := dial(port)
		if err != nil {
			return nil
		}
		conn.Close()
		if time.Now().After(deadline) {
			return fmt.Errorf("server %d of %s still listens on port %s after %s", pid, cacheDir, port, stopTimeout)
		}
		time.Sleep(pollInterval)
	}
}

func serverPath() string {
	if override := os.Getenv("KOTLIN_LSP_SERVER"); override != "" {
		return override
	}
	return defaultServer
}

func connect(cacheDir string) (net.Conn, error) {
	port, err := readPort(cacheDir)
	if err != nil {
		return nil, err
	}
	return dial(port)
}

func readPort(cacheDir string) (string, error) {
	content, err := os.ReadFile(filepath.Join(cacheDir, "port"))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(content)), nil
}

func dial(port string) (net.Conn, error) {
	return net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), time.Second)
}
