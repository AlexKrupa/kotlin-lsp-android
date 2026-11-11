package download

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// The test binary plays the child process that Start launches.
func TestMain(m *testing.M) {
	if len(os.Args) > 2 && os.Args[1] == "download" {
		os.Stdout.WriteString("child started for " + os.Args[2] + "\n")
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func zipOf(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for name, content := range files {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		entry.Write([]byte(content))
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func digestOf(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// serve answers the zip and the checksum of one Gradle version and counts the requests.
func serve(t *testing.T, version string, archive []byte, checksum string) *atomic.Int32 {
	t.Helper()
	var requests atomic.Int32
	base := "/gradle-" + version + "-src.zip"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		switch r.URL.Path {
		case base:
			w.Write(archive)
		case base + ".sha256":
			w.Write([]byte(checksum))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	previous := BaseURL
	BaseURL = server.URL
	t.Cleanup(func() { BaseURL = previous })
	return &requests
}

func writeMissing(t *testing.T, cacheDir, content string) {
	t.Helper()
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cacheDir, "missing-sources.json"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// fakeAndroid puts an `android` script on PATH that records its arguments in the returned file.
func fakeAndroid(t *testing.T, exitCode int) string {
	t.Helper()
	binDir := t.TempDir()
	record := filepath.Join(t.TempDir(), "args")
	script := "#!/bin/sh\necho \"$@\" >> '" + record + "'\nexit " + string(rune('0'+exitCode)) + "\n"
	if err := os.WriteFile(filepath.Join(binDir, "android"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir+":"+os.Getenv("PATH"))
	return record
}

func TestGradleSourcesVerifiesChecksum(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	archive := zipOf(t, map[string]string{"gradle-9.7.0/a/src/main/java/A.java": "class A {}"})
	serve(t, "9.7.0", archive, strings.Repeat("0", 64))
	cacheDir := filepath.Join(cacheRoot, "key")
	writeMissing(t, cacheDir, `{"androidPlatforms": [], "gradleVersions": ["9.7.0"]}`)

	err := Run(cacheDir)

	if err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("Run error = %v, want a checksum error", err)
	}
	entries, _ := os.ReadDir(filepath.Join(cacheRoot, "gradle-sources"))
	if len(entries) != 0 {
		t.Errorf("gradle-sources has %d entries after a checksum failure, want 0", len(entries))
	}
}

func TestGradleSourcesExtractsSrcMainOnly(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	archive := zipOf(t, map[string]string{
		"gradle-9.7.0/a/src/main/java/A.java": "class A {}",
		"gradle-9.7.0/a/src/test/java/T.java": "class T {}",
		"gradle-9.7.0/README":                 "readme",
	})
	serve(t, "9.7.0", archive, digestOf(archive)+"  gradle-9.7.0-src.zip\n")
	cacheDir := filepath.Join(cacheRoot, "key")
	writeMissing(t, cacheDir, `{"androidPlatforms": [], "gradleVersions": ["9.7.0"]}`)

	if err := Run(cacheDir); err != nil {
		t.Fatal(err)
	}

	target := filepath.Join(cacheRoot, "gradle-sources", "gradle-9.7.0")
	var files []string
	filepath.WalkDir(target, func(path string, entry os.DirEntry, err error) error {
		if err == nil && !entry.IsDir() {
			relative, _ := filepath.Rel(target, path)
			files = append(files, relative)
		}
		return nil
	})
	want := filepath.Join("a", "src", "main", "java", "A.java")
	if len(files) != 1 || files[0] != want {
		t.Errorf("extracted files = %v, want [%s]", files, want)
	}
	siblings, _ := os.ReadDir(filepath.Join(cacheRoot, "gradle-sources"))
	if len(siblings) != 1 {
		t.Errorf("gradle-sources has %d entries, want only the final folder", len(siblings))
	}
}

func TestGradleSourcesRejectsEntriesOutsideTarget(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	archive := zipOf(t, map[string]string{"gradle-9.7.0/../../escape/src/main/java/A.java": "class A {}"})
	serve(t, "9.7.0", archive, digestOf(archive))
	cacheDir := filepath.Join(cacheRoot, "key")
	writeMissing(t, cacheDir, `{"androidPlatforms": [], "gradleVersions": ["9.7.0"]}`)

	if err := Run(cacheDir); err == nil {
		t.Fatal("Run succeeded, want an error for an entry outside the target folder")
	}

	for _, path := range []string{
		filepath.Join(cacheRoot, "escape"),
		filepath.Join(cacheRoot, "gradle-sources", "gradle-9.7.0"),
	} {
		if _, err := os.Stat(path); err == nil {
			t.Errorf("%s exists after a rejected archive", path)
		}
	}
}

func TestGradleSourcesSkipsExistingFolder(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	requests := serve(t, "9.7.0", nil, "")
	os.MkdirAll(filepath.Join(cacheRoot, "gradle-sources", "gradle-9.7.0"), 0o755)
	cacheDir := filepath.Join(cacheRoot, "key")
	writeMissing(t, cacheDir, `{"androidPlatforms": [], "gradleVersions": ["9.7.0"]}`)

	if err := Run(cacheDir); err != nil {
		t.Fatal(err)
	}

	if got := requests.Load(); got != 0 {
		t.Errorf("requests = %d, want 0", got)
	}
}

func TestSdkSourcesRunsAndroidCli(t *testing.T) {
	t.Setenv("KOTLIN_LSP_CACHE", t.TempDir())
	record := fakeAndroid(t, 0)
	cacheDir := filepath.Join(os.Getenv("KOTLIN_LSP_CACHE"), "key")
	writeMissing(t, cacheDir, `{"androidPlatforms": ["android-36"], "gradleVersions": []}`)

	if err := Run(cacheDir); err != nil {
		t.Fatal(err)
	}

	got, err := os.ReadFile(record)
	if err != nil {
		t.Fatalf("android was not run: %v", err)
	}
	if want := "sdk install sources/android-36\n"; string(got) != want {
		t.Errorf("android arguments = %q, want %q", got, want)
	}
}

func TestSdkFailureDoesNotStopGradleDownload(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	fakeAndroid(t, 1)
	archive := zipOf(t, map[string]string{"gradle-9.7.0/a/src/main/java/A.java": "class A {}"})
	serve(t, "9.7.0", archive, digestOf(archive))
	cacheDir := filepath.Join(cacheRoot, "key")
	writeMissing(t, cacheDir, `{"androidPlatforms": ["android-36"], "gradleVersions": ["9.7.0"]}`)

	err := Run(cacheDir)

	if err == nil || !strings.Contains(err.Error(), "sources/android-36") {
		t.Errorf("Run error = %v, want an error that names sources/android-36", err)
	}
	if _, statErr := os.Stat(filepath.Join(cacheRoot, "gradle-sources", "gradle-9.7.0", "a", "src", "main", "java", "A.java")); statErr != nil {
		t.Errorf("Gradle sources missing after an SDK failure: %v", statErr)
	}
}

func TestNothingMissingDoesNothing(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	record := fakeAndroid(t, 0)
	requests := serve(t, "9.7.0", nil, "")
	cacheDir := filepath.Join(cacheRoot, "key")
	writeMissing(t, cacheDir, `{"androidPlatforms": [], "gradleVersions": []}`)

	if err := Run(cacheDir); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(record); err == nil {
		t.Error("android was run")
	}
	if got := requests.Load(); got != 0 {
		t.Errorf("requests = %d, want 0", got)
	}
}

func TestRunExitsAtOnceWhenAnotherDownloadHoldsTheLock(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	record := fakeAndroid(t, 0)
	cacheDir := filepath.Join(cacheRoot, "key")
	writeMissing(t, cacheDir, `{"androidPlatforms": ["android-36"], "gradleVersions": []}`)
	lock, err := os.OpenFile(filepath.Join(cacheRoot, "download.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}

	if err := Run(cacheDir); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(record); err == nil {
		t.Error("android was run while another download held the lock")
	}
}

func TestStartRunsDownloadChildAndLogsItsOutput(t *testing.T) {
	cacheRoot := t.TempDir()
	t.Setenv("KOTLIN_LSP_CACHE", cacheRoot)
	cacheDir := filepath.Join(cacheRoot, "key")

	if err := Start(cacheDir); err != nil {
		t.Fatal(err)
	}

	want := "child started for " + cacheDir
	deadline := time.Now().Add(10 * time.Second)
	for {
		log, _ := os.ReadFile(filepath.Join(cacheRoot, "download.log"))
		if strings.Contains(string(log), want) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("download.log = %q, want it to contain %q", log, want)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
