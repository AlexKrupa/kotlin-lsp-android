// Package sources prepares the library sources of a Gradle root for the server.
package sources

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

func Exists(cacheDir string) bool {
	_, err := os.Stat(filepath.Join(cacheDir, "library-sources", "workspace.json"))
	return err == nil
}

// Prepare runs the init script before the server starts, so that its first import finds the
// library sources. Gradle writes to stderr, because stdout is the LSP channel.
func Prepare(root, scriptPath string, env []string) error {
	gradlew := filepath.Join(root, "gradlew")
	if _, err := os.Stat(gradlew); err != nil {
		return fmt.Errorf("no gradlew in %s: %w", root, err)
	}
	command := exec.Command(gradlew, "-q", "-I", scriptPath, "lspLibrarySources")
	command.Dir = root
	command.Env = env
	command.Stdout = os.Stderr
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("run %s lspLibrarySources in %s: %w", gradlew, root, err)
	}
	return nil
}

// Projects returns the projects that the proxy adds to the initialize request. The json project
// is there only when a workspace.json exists: the json project has no content without it.
func Projects(root, cacheDir string) []lsp.Project {
	projects := []lsp.Project{{Type: "gradle", Path: fileURI(root)}}
	if !Exists(cacheDir) {
		return projects
	}
	return append(projects, lsp.Project{Type: "json", Path: fileURI(filepath.Join(cacheDir, "library-sources"))})
}

func fileURI(path string) string {
	return (&url.URL{Scheme: "file", Path: path}).String()
}
