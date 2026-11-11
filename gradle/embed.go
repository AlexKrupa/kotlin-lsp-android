package initscript

import (
	"bytes"
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
)

const fileName = "lsp-library-sources.gradle"

//go:embed lsp-library-sources.gradle
var script []byte

// Write keeps a file with the same content, so that Gradle sees no new modification time.
func Write(cacheDir string) (string, error) {
	path := filepath.Join(cacheDir, fileName)
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
