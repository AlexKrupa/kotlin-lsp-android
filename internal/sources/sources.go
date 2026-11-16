package sources

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

func Exists(cacheDir string) bool {
	_, err := os.Stat(WorkspaceFile(cacheDir))
	return err == nil
}

// WorkspaceFile is the file of the json project. kotlin-lsp imports the workspace again when it
// changes.
func WorkspaceFile(cacheDir string) string {
	return filepath.Join(cacheDir, "library-sources", "workspace.json")
}

// Prepare runs the init script before the server starts, so that its first import finds the
// library sources. Gradle writes to stderr, because stdout is the LSP channel.
//
// It also builds the R jars, because the server reads a jar only at its start. They get a separate
// run, because a missing library fails their task graph. Their failure is no error: only R stays
// unresolved, and Gradle shows the cause on stderr. With --continue, a failed module does not stop
// the jars of the other modules.
func Prepare(root, scriptPath string, env []string) error {
	gradlew := filepath.Join(root, "gradlew")
	if _, err := os.Stat(gradlew); err != nil {
		return fmt.Errorf("no gradlew in %s: %w", root, err)
	}
	err := runTask(gradlew, root, scriptPath, env, "lspLibrarySources")
	_ = runTask(gradlew, root, scriptPath, env, "lspRClassJars", "--continue")
	return err
}

func runTask(gradlew, root, scriptPath string, env []string, arguments ...string) error {
	command := exec.Command(gradlew, append([]string{"-q", "-I", scriptPath}, arguments...)...)
	command.Dir = root
	command.Env = env
	command.Stdout = os.Stderr
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("run %s %s in %s: %w", gradlew, strings.Join(arguments, " "), root, err)
	}
	return nil
}

// The json project has no content without a workspace.json.
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
