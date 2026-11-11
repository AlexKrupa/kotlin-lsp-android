package server

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

func TestMain(m *testing.M) {
	binDir, err := os.MkdirTemp("", "fakeserver")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary := filepath.Join(binDir, "fakeserver")
	build := exec.Command("go", "build", "-o", binary, "./testdata/fakeserver")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "build fake server:", err)
		os.Exit(1)
	}
	os.Setenv("KOTLIN_LSP_SERVER", binary)
	code := m.Run()
	os.RemoveAll(binDir)
	os.Exit(code)
}

// newCacheDir returns a cache folder whose server is killed at the end of the test.
func newCacheDir(t *testing.T) string {
	t.Helper()
	cacheDir := t.TempDir()
	t.Cleanup(func() {
		content, err := os.ReadFile(filepath.Join(cacheDir, "pid"))
		if err != nil {
			return
		}
		if pid, err := strconv.Atoi(string(content)); err == nil {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	return cacheDir
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(content)
}

func ensure(t *testing.T, cacheDir string) net.Conn {
	t.Helper()
	conn, err := Ensure(os.TempDir(), cacheDir, os.Environ(), func() {})
	if err != nil {
		t.Fatalf("Ensure returned error: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func TestEnsureStartsServerAndConnects(t *testing.T) {
	cacheDir := newCacheDir(t)

	conn := ensure(t, cacheDir)

	if err := lsp.WriteMessage(conn, []byte("{}")); err != nil {
		t.Fatalf("write to server: %v", err)
	}
	if body, err := lsp.ReadMessage(bufio.NewReader(conn)); err != nil || string(body) != "{}" {
		t.Fatalf("echo = %q, %v, want {}", body, err)
	}
	for _, name := range []string{"pid", "port"} {
		if _, err := os.Stat(filepath.Join(cacheDir, name)); err != nil {
			t.Fatalf("%s missing: %v", name, err)
		}
	}
}

func TestEnsureReusesRunningServer(t *testing.T) {
	cacheDir := newCacheDir(t)

	ensure(t, cacheDir)
	firstPid := readFile(t, filepath.Join(cacheDir, "pid"))
	ensure(t, cacheDir)
	secondPid := readFile(t, filepath.Join(cacheDir, "pid"))

	if firstPid != secondPid {
		t.Fatalf("pid changed from %s to %s", firstPid, secondPid)
	}
}

func TestEnsureStartsOneServerForConcurrentClients(t *testing.T) {
	cacheDir := newCacheDir(t)
	var wait sync.WaitGroup
	var prepareCount atomic.Int32
	errs := make(chan error, 5)

	for range 5 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			conn, err := Ensure(os.TempDir(), cacheDir, os.Environ(), func() { prepareCount.Add(1) })
			if err != nil {
				errs <- err
				return
			}
			conn.Close()
		}()
	}
	wait.Wait()

	close(errs)
	for err := range errs {
		t.Fatalf("Ensure returned error: %v", err)
	}
	if starts := strings.Count(readFile(t, filepath.Join(cacheDir, "starts")), "\n"); starts != 1 {
		t.Fatalf("server starts = %d, want 1", starts)
	}
	if got := prepareCount.Load(); got != 1 {
		t.Fatalf("prepare calls = %d, want 1", got)
	}
}

func TestEnsurePassesEnvironment(t *testing.T) {
	cacheDir := newCacheDir(t)
	t.Setenv("KOTLIN_LSP_TEST_PARENT", "1")

	conn, err := Ensure(os.TempDir(), cacheDir, []string{"KOTLIN_LSP_TEST_VALUE=a b"}, func() {})
	if err != nil {
		t.Fatalf("Ensure returned error: %v", err)
	}
	conn.Close()

	lines := strings.Split(readFile(t, filepath.Join(cacheDir, "env")), "\n")
	var hasValue bool
	for _, line := range lines {
		if line == "KOTLIN_LSP_TEST_VALUE=a b" {
			hasValue = true
		}
		if strings.HasPrefix(line, "KOTLIN_LSP_TEST_PARENT=") {
			t.Fatalf("server env has a variable of the parent: %s", line)
		}
	}
	if !hasValue {
		t.Fatalf("server env %v has no KOTLIN_LSP_TEST_VALUE=a b", lines)
	}
}

func TestEnsureFailsAfterTimeout(t *testing.T) {
	cacheDir := newCacheDir(t)
	defaultTimeout := startTimeout
	startTimeout = 2 * time.Second
	t.Cleanup(func() { startTimeout = defaultTimeout })

	_, err := Ensure(os.TempDir(), cacheDir, append(os.Environ(), "FAKE_SERVER_SILENT=1"), func() {})

	if err == nil {
		t.Fatal("Ensure returned no error")
	}
	if !strings.Contains(err.Error(), filepath.Join(cacheDir, "server.log")) {
		t.Fatalf("error %q does not name server.log", err)
	}
}

func TestStopEndsServer(t *testing.T) {
	cacheDir := newCacheDir(t)
	ensure(t, cacheDir).Close()
	port := readFile(t, filepath.Join(cacheDir, "port"))

	err := Stop(cacheDir)

	if err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}
	if conn, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", port)); err == nil {
		conn.Close()
		t.Fatalf("port %s is still open", port)
	}
}

// envValue returns the value of the last entry for name, and whether one exists.
func envValue(env []string, name string) (string, bool) {
	value, found := "", false
	for _, entry := range env {
		if rest, ok := strings.CutPrefix(entry, name+"="); ok {
			value, found = rest, true
		}
	}
	return value, found
}

func countEntries(env []string, name string) int {
	count := 0
	for _, entry := range env {
		if strings.HasPrefix(entry, name+"=") {
			count++
		}
	}
	return count
}

func TestEnvAppendsToExistingOptions(t *testing.T) {
	t.Setenv("JAVA_TOOL_OPTIONS", "-Xmx1g")
	t.Setenv("IJ_JAVA_OPTIONS", "-Da=b")

	env := Env(t.TempDir(), "/cache/script.gradle")

	if got, _ := envValue(env, "JAVA_TOOL_OPTIONS"); got != "-Xmx1g -Dorg.gradle.isolated-projects=false" {
		t.Errorf("JAVA_TOOL_OPTIONS = %q", got)
	}
	if got, _ := envValue(env, "IJ_JAVA_OPTIONS"); got != "-Da=b -Dcom.jetbrains.ls.imports.gradle.init.scripts=/cache/script.gradle" {
		t.Errorf("IJ_JAVA_OPTIONS = %q", got)
	}
	for _, name := range []string{"JAVA_TOOL_OPTIONS", "IJ_JAVA_OPTIONS"} {
		if count := countEntries(env, name); count != 1 {
			t.Errorf("%s appears %d times, want 1", name, count)
		}
	}
}

func TestEnvSetsOptionsWithoutParentValues(t *testing.T) {
	t.Setenv("JAVA_TOOL_OPTIONS", "")
	t.Setenv("IJ_JAVA_OPTIONS", "")

	env := Env(t.TempDir(), "/cache/script.gradle")

	if got, _ := envValue(env, "JAVA_TOOL_OPTIONS"); got != "-Dorg.gradle.isolated-projects=false" {
		t.Errorf("JAVA_TOOL_OPTIONS = %q", got)
	}
	if got, _ := envValue(env, "IJ_JAVA_OPTIONS"); got != "-Dcom.jetbrains.ls.imports.gradle.init.scripts=/cache/script.gradle" {
		t.Errorf("IJ_JAVA_OPTIONS = %q", got)
	}
}

func TestEnvSetsPathsAndFlags(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	t.Setenv("KOTLIN_LSP_ANDROID_OUTPUT", "/stale")
	cacheDir := filepath.Join(cacheRoot, "abc")

	env := Env(cacheDir, "/cache/script.gradle")

	want := map[string]string{
		"ORG_GRADLE_PROJECT_android.onlyEnableUnitTestForTheTestedBuildType": "false",
		"KOTLIN_LSP_ANDROID_OUTPUT": cacheDir,
		"KOTLIN_LSP_GRADLE_SOURCES": filepath.Join(cacheRoot, "gradle-sources"),
	}
	for name, value := range want {
		if got, _ := envValue(env, name); got != value {
			t.Errorf("%s = %q, want %q", name, got, value)
		}
		if count := countEntries(env, name); count != 1 {
			t.Errorf("%s appears %d times, want 1", name, count)
		}
	}
}

func TestEnvSetsVariantFromFile(t *testing.T) {
	t.Setenv("LSP_ANDROID_VARIANT", "inherited")
	cacheDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(cacheDir, "variant"), []byte("prodDebug\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	env := Env(cacheDir, "/cache/script.gradle")

	if got, _ := envValue(env, "LSP_ANDROID_VARIANT"); got != "prodDebug" {
		t.Errorf("LSP_ANDROID_VARIANT = %q, want prodDebug", got)
	}
	if count := countEntries(env, "LSP_ANDROID_VARIANT"); count != 1 {
		t.Errorf("LSP_ANDROID_VARIANT appears %d times, want 1", count)
	}
}

func TestEnvOmitsVariantWithoutFile(t *testing.T) {
	t.Setenv("LSP_ANDROID_VARIANT", "inherited")

	env := Env(t.TempDir(), "/cache/script.gradle")

	if got, found := envValue(env, "LSP_ANDROID_VARIANT"); found {
		t.Errorf("LSP_ANDROID_VARIANT = %q, want it not set", got)
	}
}
