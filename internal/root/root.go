package root

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

var markers = []string{
	"settings.gradle.kts",
	"settings.gradle",
	"build.gradle.kts",
	"build.gradle",
}

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
