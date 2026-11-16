// Package reimport makes kotlin-lsp import again after a failed Gradle import, when the files of
// the root change. kotlin-lsp watches the build scripts only after an import that gave a model, and
// it imports only for the first client of a workspace.
package reimport

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// These are variables so that tests can make them shorter.
var (
	pollInterval = 3 * time.Second
	// An agent or a checkout changes several files in a row. One import after the last change is
	// enough.
	quietTime = 3 * time.Second
)

// Run waits for a signal on failures. Then, after the next change of the git working tree of root,
// it touches workspaceFile. kotlin-lsp watches that file and imports the whole workspace again. A
// failure of that import comes as a new signal. A root outside git gets no import.
func Run(root, workspaceFile string, failures <-chan struct{}) {
	for range failures {
		if err := touchAfterChange(root, workspaceFile); err != nil {
			fmt.Fprintf(os.Stderr, "kotlin-lsp-android: no import after the failed import of %s: %v\n", root, err)
		}
	}
}

func touchAfterChange(root, workspaceFile string) error {
	last, err := treeState(root)
	if err != nil {
		return err
	}
	changed := false
	var changeTime time.Time
	for {
		time.Sleep(pollInterval)
		current, err := treeState(root)
		if err != nil {
			return err
		}
		if current != last {
			last, changed, changeTime = current, true, time.Now()
			continue
		}
		if changed && time.Since(changeTime) >= quietTime {
			now := time.Now()
			if err := os.Chtimes(workspaceFile, now, now); err != nil {
				return fmt.Errorf("touch %s: %w", workspaceFile, err)
			}
			return nil
		}
	}
}

// treeState changes when HEAD, the list of changed files, or the content of a changed file
// changes. Git ignores the build output of the failed import.
func treeState(root string) (string, error) {
	head, err := git(root, "rev-parse", "--verify", "-q", "HEAD")
	if err != nil {
		return "", err
	}
	status, err := git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return "", err
	}
	state := []string{head}
	for _, entry := range strings.Split(status, "\x00") {
		// A rename has the old path in the next entry, with no status.
		if len(entry) < 4 {
			continue
		}
		state = append(state, entry)
		// The status of a file stays " M" after its next change.
		if info, err := os.Stat(filepath.Join(root, entry[3:])); err == nil {
			state = append(state, fmt.Sprint(info.ModTime().UnixNano(), info.Size()))
		}
	}
	return strings.Join(state, "\n"), nil
}

func git(root string, args ...string) (string, error) {
	command := exec.Command("git", append([]string{"-C", root}, args...)...)
	// Without this, git status takes the index lock, and a git command of the user can fail.
	command.Env = append(os.Environ(), "GIT_OPTIONAL_LOCKS=0")
	output, err := command.Output()
	if err != nil {
		return "", fmt.Errorf("git %s in %s: %w", strings.Join(args, " "), root, err)
	}
	return string(output), nil
}
