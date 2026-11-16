package reimport

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// The time for Run to read the first state after a failure signal. Git takes longer than pollInterval.
const firstStateTime = 500 * time.Millisecond

func shortIntervals(t *testing.T) {
	t.Helper()
	defaultPoll, defaultQuiet := pollInterval, quietTime
	pollInterval, quietTime = 10*time.Millisecond, 30*time.Millisecond
	t.Cleanup(func() { pollInterval, quietTime = defaultPoll, defaultQuiet })
}

func runGit(t *testing.T, root string, args ...string) {
	t.Helper()
	command := exec.Command("git", append([]string{"-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"}, args...)...)
	command.Dir = root
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, output)
	}
}

func gitRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writeFile(t, root, "build.gradle.kts", "plugins {}\n")
	runGit(t, root, "init", "-q")
	runGit(t, root, "add", ".")
	runGit(t, root, "commit", "-q", "-m", "start")
	return root
}

func writeFile(t *testing.T, root, name, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// workspaceFile is the file that kotlin-lsp watches, with a modification time in the past.
type workspaceFile struct {
	path string
	past time.Time
}

func newWorkspaceFile(t *testing.T) workspaceFile {
	t.Helper()
	file := workspaceFile{path: filepath.Join(t.TempDir(), "workspace.json"), past: time.Now().Add(-time.Hour).Truncate(time.Second)}
	writeFile(t, filepath.Dir(file.path), filepath.Base(file.path), "{}")
	file.reset(t)
	return file
}

func (file workspaceFile) reset(t *testing.T) {
	t.Helper()
	if err := os.Chtimes(file.path, file.past, file.past); err != nil {
		t.Fatal(err)
	}
}

func (file workspaceFile) touched() bool {
	info, err := os.Stat(file.path)
	return err == nil && !info.ModTime().Equal(file.past)
}

func (file workspaceFile) waitTouch(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !file.touched() {
		if time.Now().After(deadline) {
			t.Fatal("no touch of the workspace file after the change")
		}
		time.Sleep(pollInterval)
	}
}

func (file workspaceFile) expectNoTouch(t *testing.T) {
	t.Helper()
	time.Sleep(20 * quietTime)
	if file.touched() {
		t.Fatal("touch of the workspace file with no failure and change")
	}
}

func start(root string, file workspaceFile) chan<- struct{} {
	failures := make(chan struct{}, 1)
	go Run(root, file.path, failures)
	return failures
}

func TestRunTouchesWorkspaceFileAfterChangeOfFailedRoot(t *testing.T) {
	shortIntervals(t)
	root := gitRepo(t)
	file := newWorkspaceFile(t)
	failures := start(root, file)
	writeFile(t, root, "build.gradle.kts", "plugins { id(\"a\") }\n")
	file.expectNoTouch(t)

	failures <- struct{}{}
	time.Sleep(firstStateTime)
	writeFile(t, root, "build.gradle.kts", "plugins { id(\"b\") }\n")

	file.waitTouch(t)
}

func TestRunWaitsForNextFailureAfterTouch(t *testing.T) {
	shortIntervals(t)
	root := gitRepo(t)
	file := newWorkspaceFile(t)
	failures := start(root, file)
	failures <- struct{}{}
	time.Sleep(firstStateTime)
	writeFile(t, root, "build.gradle.kts", "plugins { id(\"a\") }\n")
	file.waitTouch(t)
	file.reset(t)
	writeFile(t, root, "build.gradle.kts", "plugins { id(\"a\"); id(\"b\") }\n")
	file.expectNoTouch(t)

	failures <- struct{}{}
	time.Sleep(firstStateTime)
	writeFile(t, root, "build.gradle.kts", "plugins { id(\"a\"); id(\"c\") }\n")

	file.waitTouch(t)
}

func TestRunTouchesWorkspaceFileAfterCommit(t *testing.T) {
	shortIntervals(t)
	root := gitRepo(t)
	file := newWorkspaceFile(t)
	failures := start(root, file)
	failures <- struct{}{}
	time.Sleep(firstStateTime)

	runGit(t, root, "commit", "-q", "--allow-empty", "-m", "next")

	file.waitTouch(t)
}

func TestRunDoesNotTouchOutsideGit(t *testing.T) {
	shortIntervals(t)
	root := t.TempDir()
	file := newWorkspaceFile(t)
	failures := start(root, file)
	failures <- struct{}{}
	time.Sleep(firstStateTime)

	writeFile(t, root, "build.gradle.kts", "plugins {}\n")

	file.expectNoTouch(t)
}
