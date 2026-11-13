package server

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// These are variables so that tests can make them shorter.
var (
	watchInterval = time.Minute
	idleTimeout   = time.Hour
)

// StartWatch starts Watch in a background process that outlives the client.
func StartWatch(cacheDir string) error {
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("find own executable: %w", err)
	}
	logPath := filepath.Join(cacheDir, "watch.log")
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open watch log %s: %w", logPath, err)
	}
	defer log.Close()
	child := exec.Command(executable, "watch", cacheDir)
	child.Stdout = log
	child.Stderr = log
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		return fmt.Errorf("start watch process %s: %w", executable, err)
	}
	return child.Process.Release()
}

// Watch stops the server of cacheDir after idleTimeout with no client. If another Watch runs for
// cacheDir, it returns at once.
func Watch(cacheDir string) error {
	watchLock, err := lockFile(filepath.Join(cacheDir, "watch.lock"), syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) {
		return nil
	}
	if err != nil {
		return err
	}
	defer watchLock.Close()

	lastClientTime := time.Now()
	for {
		time.Sleep(watchInterval)
		stopped, err := stopIfIdle(cacheDir, &lastClientTime)
		if stopped || err != nil {
			return err
		}
	}
}

// stopIfIdle holds the start lock, so that no client connects during the check and the stop.
func stopIfIdle(cacheDir string, lastClientTime *time.Time) (stopped bool, err error) {
	lock, err := lockStart(cacheDir)
	if err != nil {
		return false, err
	}
	defer lock.Close()

	// A connection for the check would add lines to the server log.
	if !Runs(cacheDir) {
		return true, nil
	}
	clients, err := lockClients(cacheDir, syscall.LOCK_EX|syscall.LOCK_NB)
	if errors.Is(err, syscall.EWOULDBLOCK) {
		*lastClientTime = time.Now()
		return false, nil
	}
	if err != nil {
		return false, err
	}
	clients.Close()
	if time.Since(*lastClientTime) < idleTimeout {
		return false, nil
	}
	if err := Stop(cacheDir); err != nil {
		return false, fmt.Errorf("stop idle server of %s: %w", cacheDir, err)
	}
	return true, nil
}

// Runs reports whether the server process of cacheDir runs.
func Runs(cacheDir string) bool {
	content, err := os.ReadFile(filepath.Join(cacheDir, "pid"))
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(content)))
	if err != nil {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}
