package variant

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/server"
)

func TestMain(m *testing.M) {
	binDir, err := os.MkdirTemp("", "fakeserver")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary := filepath.Join(binDir, "fakeserver")
	build := exec.Command("go", "build", "-o", binary, "../server/testdata/fakeserver")
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

func writeVariants(t *testing.T, cacheDir, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(cacheDir, "variants.json"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

const twoModules = `{"modules": {":app": ["prodDebug", "demoDebug"], ":lib": ["debug"]}, "selected": {}}`

func TestListMergesModules(t *testing.T) {
	cacheDir := t.TempDir()
	writeVariants(t, cacheDir, twoModules)

	names, err := List(cacheDir)

	if err != nil {
		t.Fatal(err)
	}
	want := []string{"debug", "demoDebug", "prodDebug"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("names = %v, want %v", names, want)
	}
}

func TestListWithoutFileFails(t *testing.T) {
	cacheDir := t.TempDir()

	_, err := List(cacheDir)

	if err == nil || !strings.Contains(err.Error(), "first import has not run") {
		t.Fatalf("error = %v, want an error that says the first import has not run", err)
	}
}

func fakeGradlew(t *testing.T, root, body string) {
	t.Helper()
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(filepath.Join(root, "gradlew"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// startServer starts a fake server for cacheDir, kills it at the end of the test, and returns its
// port.
func startServer(t *testing.T, root, cacheDir string) string {
	t.Helper()
	scriptPath := filepath.Join(cacheDir, "lsp-library-sources.gradle")
	conn, err := server.Ensure(root, cacheDir, server.Env(cacheDir, scriptPath), func() {})
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	t.Cleanup(func() {
		content, err := os.ReadFile(filepath.Join(cacheDir, "pid"))
		if err != nil {
			return
		}
		if pid, err := strconv.Atoi(strings.TrimSpace(string(content))); err == nil {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	port, err := os.ReadFile(filepath.Join(cacheDir, "port"))
	if err != nil {
		t.Fatal(err)
	}
	return string(port)
}

func assertPortClosed(t *testing.T, port string) {
	t.Helper()
	if conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), time.Second); err == nil {
		conn.Close()
		t.Errorf("port %s is still open", port)
	}
}

func TestSetRejectsUnknownName(t *testing.T) {
	root, cacheDir := t.TempDir(), t.TempDir()
	marker := filepath.Join(root, "marker")
	fakeGradlew(t, root, "touch "+marker)
	writeVariants(t, cacheDir, twoModules)

	err := Set(root, cacheDir, "prodBeta")

	if err == nil {
		t.Fatal("Set accepted an unknown name")
	}
	for _, known := range []string{"prodBeta", "debug", "demoDebug", "prodDebug"} {
		if !strings.Contains(err.Error(), known) {
			t.Errorf("error %q does not contain %q", err, known)
		}
	}
	if _, err := os.Stat(filepath.Join(cacheDir, "variant")); err == nil {
		t.Error("variant file exists after a rejected name")
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("gradlew ran after a rejected name")
	}
}

func TestSetWritesFileRunsPrepareAndStops(t *testing.T) {
	root, cacheDir := t.TempDir(), t.TempDir()
	report := filepath.Join(root, "report")
	fakeGradlew(t, root, `echo "$LSP_ANDROID_VARIANT" > `+report)
	writeVariants(t, cacheDir, twoModules)
	port := startServer(t, root, cacheDir)

	if err := Set(root, cacheDir, "demoDebug"); err != nil {
		t.Fatal(err)
	}

	variant, err := os.ReadFile(filepath.Join(cacheDir, "variant"))
	if err != nil {
		t.Fatal(err)
	}
	if string(variant) != "demoDebug\n" {
		t.Errorf("variant file = %q, want %q", variant, "demoDebug\n")
	}
	recorded, err := os.ReadFile(report)
	if err != nil {
		t.Fatalf("gradlew did not run: %v", err)
	}
	if strings.TrimSpace(string(recorded)) != "demoDebug" {
		t.Errorf("gradlew saw LSP_ANDROID_VARIANT = %q, want demoDebug", recorded)
	}
	assertPortClosed(t, port)
}

func TestSetStopsServerWhenPrepareFails(t *testing.T) {
	root, cacheDir := t.TempDir(), t.TempDir()
	fakeGradlew(t, root, "exit 3")
	writeVariants(t, cacheDir, twoModules)
	port := startServer(t, root, cacheDir)

	err := Set(root, cacheDir, "debug")

	if err == nil || !strings.Contains(err.Error(), root) {
		t.Fatalf("error = %v, want the Prepare error that names %s", err, root)
	}
	assertPortClosed(t, port)
}
