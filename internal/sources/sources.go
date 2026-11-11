// Package sources prepares the library sources of a Gradle root for the server.
package sources

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"

	initscript "github.com/AlexKrupa/kotlin-lsp-android/gradle"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

func workspaceJsonPath(cacheDir string) string {
	return filepath.Join(cacheDir, "library-sources", "workspace.json")
}

// Prepare runs the init script in a separate Gradle run, so that the first import of the server
// finds the library sources. With a workspace.json it does nothing. The output of Gradle goes to
// stderr: stdout is the LSP channel.
func Prepare(root, cacheDir string, env []string) error {
	if _, err := os.Stat(workspaceJsonPath(cacheDir)); err == nil {
		return nil
	}
	gradlew := filepath.Join(root, "gradlew")
	if _, err := os.Stat(gradlew); err != nil {
		return fmt.Errorf("no gradlew in %s: %w", root, err)
	}
	command := exec.Command(gradlew, "-q", "-I", filepath.Join(cacheDir, initscript.FileName), "lspLibrarySources")
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
	if _, err := os.Stat(workspaceJsonPath(cacheDir)); err != nil {
		return projects
	}
	return append(projects, lsp.Project{Type: "json", Path: fileURI(filepath.Join(cacheDir, "library-sources"))})
}

func fileURI(path string) string {
	return (&url.URL{Scheme: "file", Path: path}).String()
}
