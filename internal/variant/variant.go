// Package variant lists the build variants of a Gradle root and selects one for the server.
package variant

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	initscript "github.com/AlexKrupa/kotlin-lsp-android/gradle"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/server"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/sources"
)

// List returns the sorted, unique variant names of all modules, from the variants.json that the
// init script writes at each import.
func List(cacheDir string) ([]string, error) {
	path := filepath.Join(cacheDir, "variants.json")
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: the first import has not run: %w", path, err)
	}
	var file struct {
		Modules map[string][]string `json:"modules"`
	}
	if err := json.Unmarshal(content, &file); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	var names []string
	for _, moduleNames := range file.Modules {
		names = append(names, moduleNames...)
	}
	slices.Sort(names)
	return slices.Compact(names), nil
}

// Set selects the variant for the next start of the server: it refreshes the library sources for
// the variant and stops the running server. The next client starts the server again. The server
// stops also when the refresh fails, so that its next import applies the variant.
func Set(root, cacheDir, name string) error {
	names, err := List(cacheDir)
	if err != nil {
		return err
	}
	if !slices.Contains(names, name) {
		return fmt.Errorf("unknown variant %q, known variants: %s", name, strings.Join(names, ", "))
	}
	variantPath := filepath.Join(cacheDir, "variant")
	if err := os.WriteFile(variantPath, []byte(name+"\n"), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", variantPath, err)
	}
	scriptPath, err := initscript.Write(cacheDir)
	if err != nil {
		return err
	}
	prepareErr := sources.Prepare(root, cacheDir, server.Env(cacheDir, scriptPath), true)
	return errors.Join(prepareErr, server.Stop(cacheDir))
}
