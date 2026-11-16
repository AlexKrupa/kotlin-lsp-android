package server

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	initscript "github.com/AlexKrupa/kotlin-lsp-android/gradle"
)

func shortWatch(t *testing.T) {
	t.Helper()
	defaultInterval, defaultIdle, defaultRestore := watchInterval, idleTimeout, restoreInterval
	watchInterval, idleTimeout, restoreInterval = 20*time.Millisecond, 200*time.Millisecond, 10*time.Millisecond
	t.Cleanup(func() { watchInterval, idleTimeout, restoreInterval = defaultInterval, defaultIdle, defaultRestore })
}

func watch(cacheDir string) chan error {
	done := make(chan error, 1)
	go func() { done <- Watch(cacheDir) }()
	return done
}

func waitDone(t *testing.T, done chan error, timeout time.Duration) {
	t.Helper()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Watch returned error: %v", err)
		}
	case <-time.After(timeout):
		t.Fatalf("Watch still runs after %s", timeout)
	}
}

func serverRuns(cacheDir string) bool {
	conn, err := connect(cacheDir)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func TestWatchStopsServerWithNoClient(t *testing.T) {
	shortWatch(t)
	cacheDir := newCacheDir(t)
	ensure(t, cacheDir).Close()

	waitDone(t, watch(cacheDir), 5*time.Second)

	if serverRuns(cacheDir) {
		t.Fatal("server runs after the idle timeout")
	}
}

func TestWatchKeepsServerWhileClientIsConnected(t *testing.T) {
	shortWatch(t)
	cacheDir := newCacheDir(t)
	conn := ensure(t, cacheDir)

	done := watch(cacheDir)
	time.Sleep(3 * idleTimeout)

	if !serverRuns(cacheDir) {
		t.Fatal("server stopped while a client was connected")
	}
	conn.Close()
	waitDone(t, done, 5*time.Second)
	if serverRuns(cacheDir) {
		t.Fatal("server runs after the last client disconnected and the idle timeout")
	}
}

func TestWatchCountsIdleTimeFromLastClient(t *testing.T) {
	shortWatch(t)
	cacheDir := newCacheDir(t)
	conn := ensure(t, cacheDir)
	done := watch(cacheDir)
	time.Sleep(3 * idleTimeout)

	conn.Close()
	time.Sleep(idleTimeout / 2)

	if !serverRuns(cacheDir) {
		t.Fatal("server stopped before the idle timeout after the last client")
	}
	waitDone(t, done, 5*time.Second)
}

func TestWatchExitsWhenAnotherWatcherRuns(t *testing.T) {
	shortWatch(t)
	cacheDir := newCacheDir(t)
	conn := ensure(t, cacheDir)
	first := watch(cacheDir)

	time.Sleep(5 * watchInterval)
	waitDone(t, watch(cacheDir), time.Second)

	conn.Close()
	waitDone(t, first, 5*time.Second)
}

func TestWatchRestoresDeletedInitScript(t *testing.T) {
	shortWatch(t)
	idleTimeout = time.Hour
	cacheDir := newCacheDir(t)
	conn := ensure(t, cacheDir)
	scriptPath, err := initscript.Write(cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	done := watch(cacheDir)

	if err := os.Remove(scriptPath); err != nil {
		t.Fatal(err)
	}
	time.Sleep(5 * restoreInterval)

	if _, err := os.Stat(scriptPath); err != nil {
		t.Fatalf("init script after the deletion: %v", err)
	}
	conn.Close()
	if err := Stop(cacheDir); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}
	waitDone(t, done, 5*time.Second)
}

func TestWatchExitsWhenServerStops(t *testing.T) {
	shortWatch(t)
	idleTimeout = time.Hour
	cacheDir := newCacheDir(t)
	ensure(t, cacheDir).Close()
	done := watch(cacheDir)

	if err := Stop(cacheDir); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}

	waitDone(t, done, 5*time.Second)
}

func TestEnsureStartsNewServerAfterIdleStop(t *testing.T) {
	shortWatch(t)
	cacheDir := newCacheDir(t)
	ensure(t, cacheDir).Close()
	firstPid := readFile(t, filepath.Join(cacheDir, "pid"))
	waitDone(t, watch(cacheDir), 5*time.Second)

	ensure(t, cacheDir)

	if secondPid := readFile(t, filepath.Join(cacheDir, "pid")); secondPid == firstPid {
		t.Fatalf("pid = %s after the idle stop, want a new server", secondPid)
	}
}
