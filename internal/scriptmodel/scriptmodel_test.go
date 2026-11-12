package scriptmodel

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A fake java on PATH writes its arguments to the output path (its sixth argument) as JSON.
const recordingJava = `#!/bin/sh
printf '["%s","%s","%s","%s","%s","%s"]' "$1" "$2" "$3" "$4" "$5" "$6" > "$6"
`

const failingJava = `#!/bin/sh
echo boom >&2
exit 1
`

func useFakeJava(t *testing.T, script string) {
	t.Helper()
	binDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(binDir, "java"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
}

func newCache(t *testing.T) (cacheDir, folder string) {
	t.Helper()
	cacheDir = t.TempDir()
	folder = filepath.Join(cacheDir, "library-sources")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	return cacheDir, folder
}

func writeGradleHome(t *testing.T, folder, home string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(folder, "gradle-home.txt"), []byte(home), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunFailsWithoutGradleHome(t *testing.T) {
	useFakeJava(t, recordingJava)
	cacheDir, _ := newCache(t)

	err := Run("/some/root", cacheDir)

	if err == nil || !strings.Contains(err.Error(), "gradle-home.txt") ||
		!strings.Contains(err.Error(), "run the import first") {
		t.Fatalf("error = %v, want gradle-home.txt and run the import first", err)
	}
}

func TestRunCallsClientWithGradleLib(t *testing.T) {
	useFakeJava(t, recordingJava)
	cacheDir, folder := newCache(t)
	writeGradleHome(t, folder, "/gradle/home")

	if err := Run("/some/root", cacheDir); err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(filepath.Join(folder, "gradle-scripts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var arguments []string
	if err := json.Unmarshal(content, &arguments); err != nil {
		t.Fatalf("parse %s: %v", content, err)
	}
	outputPath := arguments[5]
	if len(arguments) != 6 ||
		arguments[0] != "-cp" ||
		arguments[1] != "/gradle/home/lib/*" ||
		arguments[2] != filepath.Join(cacheDir, "ScriptModel.java") ||
		arguments[3] != "/some/root" ||
		arguments[4] != "/gradle/home" ||
		filepath.Dir(outputPath) != folder ||
		filepath.Base(outputPath) == "gradle-scripts.json" {
		t.Fatalf("arguments = %q", arguments)
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
		t.Fatalf("temporary output %s still exists: %v", outputPath, err)
	}
}

func TestRunKeepsOldModelWhenClientFails(t *testing.T) {
	useFakeJava(t, failingJava)
	cacheDir, folder := newCache(t)
	writeGradleHome(t, folder, "/gradle/home")
	modelPath := filepath.Join(folder, "gradle-scripts.json")
	if err := os.WriteFile(modelPath, []byte("old model"), 0o644); err != nil {
		t.Fatal(err)
	}

	err := Run("/some/root", cacheDir)

	if err == nil || !strings.Contains(err.Error(), "boom") || !strings.Contains(err.Error(), "/some/root") {
		t.Fatalf("error = %v, want boom and the root", err)
	}
	content, _ := os.ReadFile(modelPath)
	if string(content) != "old model" {
		t.Fatalf("model = %q, want the old content", content)
	}
	entries, _ := os.ReadDir(folder)
	for _, entry := range entries {
		if strings.Contains(entry.Name(), ".tmp") {
			t.Fatalf("temporary file %s was not removed", entry.Name())
		}
	}
}

func TestRunErrorHasNoStderrPartWhenStderrIsEmpty(t *testing.T) {
	useFakeJava(t, "#!/bin/sh\nexit 1\n")
	cacheDir, folder := newCache(t)
	writeGradleHome(t, folder, "/gradle/home")

	err := Run("/some/root", cacheDir)

	if err == nil || strings.HasSuffix(err.Error(), ": ") {
		t.Fatalf("error = %q, want no empty stderr part", err)
	}
}

func TestRunWaitsForLock(t *testing.T) {
	useFakeJava(t, recordingJava)
	cacheDir, folder := newCache(t)
	writeGradleHome(t, folder, "/gradle/home")
	lock, err := os.OpenFile(filepath.Join(cacheDir, "script-model.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	modelPath := filepath.Join(folder, "gradle-scripts.json")
	released := make(chan time.Time, 1)
	go func() {
		time.Sleep(300 * time.Millisecond)
		os.WriteFile(modelPath, []byte("from holder"), 0o644)
		released <- time.Now()
		lock.Close()
	}()

	err = Run("/some/root", cacheDir)
	returned := time.Now()

	if err != nil {
		t.Fatal(err)
	}
	if releasedAt := <-released; returned.Before(releasedAt) {
		t.Fatalf("Run returned %v before the lock release %v", returned, releasedAt)
	}
	content, _ := os.ReadFile(modelPath)
	if string(content) != "from holder" {
		t.Fatalf("model = %q, want the content of the lock holder", content)
	}
}

func TestRunFailsWithoutJava(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	cacheDir, folder := newCache(t)
	writeGradleHome(t, folder, "/gradle/home")

	err := Run("/some/root", cacheDir)

	if err == nil || !strings.Contains(err.Error(), "java") || !strings.Contains(err.Error(), "PATH") {
		t.Fatalf("error = %v, want java and PATH", err)
	}
}
