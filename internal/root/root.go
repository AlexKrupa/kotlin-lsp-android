package root

import (
	"cmp"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"slices"
)

var settingsMarkers = []string{"settings.gradle.kts", "settings.gradle"}

var buildMarkers = []string{"build.gradle.kts", "build.gradle"}

// Find returns the outermost settings folder of the git repo, so that an included build shares the
// server of the build that includes it.
func Find(dir string) (string, error) {
	if settingsDir, found := findSettings(dir); found {
		return settingsDir, nil
	}
	for _, marker := range buildMarkers {
		for current := dir; ; current = filepath.Dir(current) {
			if exists(filepath.Join(current, marker)) {
				return current, nil
			}
			if filepath.Dir(current) == current {
				break
			}
		}
	}
	markers := append(slices.Clone(settingsMarkers), buildMarkers...)
	return "", fmt.Errorf("no Gradle root found from %s: none of %v exists in it or its parents", dir, markers)
}

func findSettings(dir string) (string, bool) {
	var nearest, outermost string
	for current := dir; ; current = filepath.Dir(current) {
		if slices.ContainsFunc(settingsMarkers, func(marker string) bool { return exists(filepath.Join(current, marker)) }) {
			nearest = cmp.Or(nearest, current)
			outermost = current
		}
		if exists(filepath.Join(current, ".git")) {
			return outermost, outermost != ""
		}
		if filepath.Dir(current) == current {
			// Outside a git repo, an outer settings file can belong to another build.
			return nearest, nearest != ""
		}
	}
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func key(root string) string {
	sum := sha256.Sum256([]byte(root))
	return hex.EncodeToString(sum[:])[:12]
}

func CacheRoot() string {
	if override := os.Getenv("KOTLIN_LSP_CACHE"); override != "" {
		return override
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "kotlin-lsp")
	}
	return filepath.Join(home, ".cache", "kotlin-lsp")
}

func CacheDir(root string) string {
	return filepath.Join(CacheRoot(), key(root))
}
