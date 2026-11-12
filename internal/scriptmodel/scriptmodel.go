// Package scriptmodel writes the Kotlin DSL script model of a Gradle build.
package scriptmodel

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	initscript "github.com/AlexKrupa/kotlin-lsp-android/gradle"
)

const stderrLineCount = 20

// Run waits for the lock, because another run can write the model for the same root. If that
// run wrote the model during the wait, Run does not run again.
func Run(root, cacheDir string) error {
	folder := filepath.Join(cacheDir, "library-sources")
	homePath := filepath.Join(folder, "gradle-home.txt")
	homeBytes, err := os.ReadFile(homePath)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%s is missing: run the import first", homePath)
	}
	if err != nil {
		return fmt.Errorf("read %s: %w", homePath, err)
	}
	gradleHome := strings.TrimSpace(string(homeBytes))
	modelPath := filepath.Join(folder, "gradle-scripts.json")

	modifiedBefore := modifiedTime(modelPath)
	lock, err := lockFile(filepath.Join(cacheDir, "script-model.lock"))
	if err != nil {
		return err
	}
	defer lock.Close()
	if !modifiedTime(modelPath).Equal(modifiedBefore) {
		return nil
	}

	javaPath, err := exec.LookPath("java")
	if err != nil {
		return fmt.Errorf("find java on PATH: %w", err)
	}
	clientPath, err := initscript.WriteClient(cacheDir)
	if err != nil {
		return err
	}
	output, err := os.CreateTemp(folder, "gradle-scripts-*.json.tmp")
	if err != nil {
		return fmt.Errorf("create temporary file in %s: %w", folder, err)
	}
	defer os.Remove(output.Name())
	if err := output.Close(); err != nil {
		return fmt.Errorf("close %s: %w", output.Name(), err)
	}

	var stderr bytes.Buffer
	command := exec.Command(javaPath, "-cp", filepath.Join(gradleHome, "lib", "*"), clientPath, root, gradleHome, output.Name())
	command.Stdout = os.Stderr
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		cause := lastLines(stderr.String(), stderrLineCount)
		if cause == "" {
			return fmt.Errorf("script model client for %s: %w", root, err)
		}
		return fmt.Errorf("script model client for %s: %w: %s", root, err, cause)
	}
	if err := os.Rename(output.Name(), modelPath); err != nil {
		return fmt.Errorf("rename %s to %s: %w", output.Name(), modelPath, err)
	}
	return nil
}

// lockFile waits until it holds the lock. The caller closes the file to release the lock.
func lockFile(path string) (*os.File, error) {
	lock, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open lock %s: %w", path, err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		lock.Close()
		return nil, fmt.Errorf("lock %s: %w", path, err)
	}
	return lock, nil
}

// modifiedTime is the zero time for a missing file.
func modifiedTime(path string) time.Time {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return info.ModTime()
}

func lastLines(text string, lineCount int) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) > lineCount {
		lines = lines[len(lines)-lineCount:]
	}
	return strings.Join(lines, "\n")
}
