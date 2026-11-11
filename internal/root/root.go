// Package root finds the Gradle root of a directory and names its cache folder.
package root

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

// markers are in priority order. Each one is searched in all parents before the next.
var markers = []string{
	"settings.gradle.kts",
	"settings.gradle",
	"build.gradle.kts",
	"build.gradle",
}

// Find returns the nearest parent of dir (or dir) that has the highest-priority root marker.
func Find(dir string) (string, error) {
	for _, marker := range markers {
		for current := dir; ; current = filepath.Dir(current) {
			if _, err := os.Stat(filepath.Join(current, marker)); err == nil {
				return current, nil
			}
			if filepath.Dir(current) == current {
				break
			}
		}
	}
	return "", fmt.Errorf("no Gradle root found from %s: none of %v exists in it or its parents", dir, markers)
}

// Key returns the first 12 hex characters of sha256(root). The shell wrapper uses the same key.
func Key(root string) string {
	sum := sha256.Sum256([]byte(root))
	return hex.EncodeToString(sum[:])[:12]
}

// CacheRoot returns $KOTLIN_LSP_CACHE, or ~/.cache/kotlin-lsp.
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

// CacheDir returns the cache folder of root.
func CacheDir(root string) string {
	return filepath.Join(CacheRoot(), Key(root))
}
