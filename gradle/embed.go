// Package initscript embeds the Gradle init script and writes it to the cache folder.
package initscript

import (
	"bytes"
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
)

// FileName is the name of the script in the cache folder.
const FileName = "lsp-library-sources.gradle"

//go:embed lsp-library-sources.gradle
var script []byte

// Write puts the script in cacheDir and returns its path. A file with the same content stays as
// it is, so that its modification time does not change for Gradle.
func Write(cacheDir string) (string, error) {
	path := filepath.Join(cacheDir, FileName)
	if existing, err := os.ReadFile(path); err == nil && bytes.Equal(existing, script) {
		return path, nil
	}
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return "", fmt.Errorf("create cache folder %s: %w", cacheDir, err)
	}
	if err := os.WriteFile(path, script, 0o644); err != nil {
		return "", fmt.Errorf("write init script %s: %w", path, err)
	}
	return path, nil
}
