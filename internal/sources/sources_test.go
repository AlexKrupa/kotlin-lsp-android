package sources

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

func writeWorkspaceJson(t *testing.T, cacheDir string) {
	t.Helper()
	folder := filepath.Join(cacheDir, "library-sources")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "workspace.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestProjectsOmitsJsonWithoutFile(t *testing.T) {
	root := "/tmp/some root/ąę"
	projects := Projects(root, t.TempDir())

	want := []lsp.Project{{Type: "gradle", Path: "file:///tmp/some%20root/%C4%85%C4%99"}}
	if len(projects) != 1 || projects[0] != want[0] {
		t.Fatalf("projects = %v, want %v", projects, want)
	}
}

func TestProjectsAddsJsonWithFile(t *testing.T) {
	cacheDir := t.TempDir()
	writeWorkspaceJson(t, cacheDir)

	projects := Projects("/tmp/root", cacheDir)

	want := lsp.Project{Type: "json", Path: "file://" + cacheDir + "/library-sources"}
	if len(projects) != 2 || projects[0].Type != "gradle" || projects[1] != want {
		t.Fatalf("projects = %v, want gradle then %v", projects, want)
	}
}

func fakeGradlew(t *testing.T, root, body string) {
	t.Helper()
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(filepath.Join(root, "gradlew"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestExistsReportsWorkspaceJson(t *testing.T) {
	cacheDir := t.TempDir()
	if Exists(cacheDir) {
		t.Fatal("Exists = true with no workspace.json")
	}

	writeWorkspaceJson(t, cacheDir)

	if !Exists(cacheDir) {
		t.Fatal("Exists = false with a workspace.json")
	}
}

func TestPrepareRunsGradlewWithScriptAndEnv(t *testing.T) {
	root := t.TempDir()
	scriptPath := filepath.Join(t.TempDir(), "script.gradle")
	report := filepath.Join(root, "report")
	fakeGradlew(t, root, `echo "$PWD|$*|$SOME_VARIABLE" > `+report)

	if err := Prepare(root, scriptPath, append(os.Environ(), "SOME_VARIABLE=value")); err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(report)
	if err != nil {
		t.Fatal(err)
	}
	resolvedRoot, _ := filepath.EvalSymlinks(root)
	want := resolvedRoot + "|-q -I " + scriptPath + " lspLibrarySources|value\n"
	if string(content) != want {
		t.Fatalf("gradlew call = %q, want %q", content, want)
	}
}

func TestPrepareReportsMissingGradlew(t *testing.T) {
	root := t.TempDir()

	err := Prepare(root, filepath.Join(t.TempDir(), "script.gradle"), os.Environ())

	if err == nil || !strings.Contains(err.Error(), root) {
		t.Fatalf("error = %v, want an error that names %s", err, root)
	}
}

func TestPrepareReportsFailedGradlew(t *testing.T) {
	root := t.TempDir()
	fakeGradlew(t, root, "exit 3")

	err := Prepare(root, filepath.Join(t.TempDir(), "script.gradle"), os.Environ())

	if err == nil || !strings.Contains(err.Error(), root) {
		t.Fatalf("error = %v, want an error that names %s", err, root)
	}
}

func TestFailedPrepareLeavesNoJsonProject(t *testing.T) {
	root, cacheDir := t.TempDir(), t.TempDir()
	fakeGradlew(t, root, "exit 3")

	Prepare(root, filepath.Join(cacheDir, "script.gradle"), os.Environ())
	projects := Projects(root, cacheDir)

	if len(projects) != 1 || projects[0].Type != "gradle" {
		t.Fatalf("projects = %v, want only the gradle project", projects)
	}
}
