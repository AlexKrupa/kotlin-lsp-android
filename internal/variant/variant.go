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

func List(cacheDir string) ([]string, error) {
	path := filepath.Join(cacheDir, "variants.json")
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: the init script has not run: %w", path, err)
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

// Set stops the server also when the refresh fails, so that the next import applies the variant.
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
	prepareErr := sources.Prepare(root, scriptPath, server.Env(cacheDir, scriptPath))
	return errors.Join(prepareErr, server.Stop(cacheDir))
}
