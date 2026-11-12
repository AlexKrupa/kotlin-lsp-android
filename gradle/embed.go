package initscript

import (
	"bytes"
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
)

const (
	fileName       = "lsp-library-sources.gradle"
	clientFileName = "ScriptModel.java"
)

//go:embed lsp-library-sources.gradle
var script []byte

//go:embed ScriptModel.java
var client []byte

// Write keeps a file with the same content, so that Gradle sees no new modification time.
func Write(cacheDir string) (string, error) {
	return writeEmbedded(cacheDir, fileName, script, "init script")
}

// WriteClient writes the Tooling API client that `script-model` runs. It keeps a file with the
// same content.
func WriteClient(cacheDir string) (string, error) {
	return writeEmbedded(cacheDir, clientFileName, client, "script model client")
}

func writeEmbedded(cacheDir, name string, content []byte, description string) (string, error) {
	path := filepath.Join(cacheDir, name)
	if existing, err := os.ReadFile(path); err == nil && bytes.Equal(existing, content) {
		return path, nil
	}
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return "", fmt.Errorf("create cache folder %s: %w", cacheDir, err)
	}
	if err := os.WriteFile(path, content, 0o644); err != nil {
		return "", fmt.Errorf("write %s %s: %w", description, path, err)
	}
	return path, nil
}
