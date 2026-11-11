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

func TestPrepareSkipsWhenFileExists(t *testing.T) {
	root, cacheDir := t.TempDir(), t.TempDir()
	marker := filepath.Join(root, "marker")
	fakeGradlew(t, root, "touch "+marker)
	writeWorkspaceJson(t, cacheDir)

	if err := Prepare(root, cacheDir, os.Environ(), false); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(marker); err == nil {
		t.Fatal("gradlew ran although workspace.json exists")
	}
}

func TestPrepareRunsWithFileWhenForced(t *testing.T) {
	root, cacheDir := t.TempDir(), t.TempDir()
	marker := filepath.Join(root, "marker")
	fakeGradlew(t, root, "touch "+marker)
	writeWorkspaceJson(t, cacheDir)

	if err := Prepare(root, cacheDir, os.Environ(), true); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(marker); err != nil {
		t.Fatal("gradlew did not run although force is set")
	}
}

func TestPrepareRunsGradlewWithScriptAndEnv(t *testing.T) {
	root, cacheDir := t.TempDir(), t.TempDir()
	report := filepath.Join(root, "report")
	fakeGradlew(t, root, `echo "$PWD|$*|$SOME_VARIABLE" > `+report)

	if err := Prepare(root, cacheDir, append(os.Environ(), "SOME_VARIABLE=value"), false); err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(report)
	if err != nil {
		t.Fatal(err)
	}
	resolvedRoot, _ := filepath.EvalSymlinks(root)
	want := resolvedRoot + "|-q -I " + filepath.Join(cacheDir, "lsp-library-sources.gradle") + " lspLibrarySources|value\n"
	if string(content) != want {
		t.Fatalf("gradlew call = %q, want %q", content, want)
	}
}

func TestPrepareReportsMissingGradlew(t *testing.T) {
	root := t.TempDir()

	err := Prepare(root, t.TempDir(), os.Environ(), false)

	if err == nil || !strings.Contains(err.Error(), root) {
		t.Fatalf("error = %v, want an error that names %s", err, root)
	}
}

func TestPrepareReportsFailedGradlew(t *testing.T) {
	root := t.TempDir()
	fakeGradlew(t, root, "exit 3")

	err := Prepare(root, t.TempDir(), os.Environ(), false)

	if err == nil || !strings.Contains(err.Error(), root) {
		t.Fatalf("error = %v, want an error that names %s", err, root)
	}
}

func TestFailedPrepareLeavesNoJsonProject(t *testing.T) {
	root, cacheDir := t.TempDir(), t.TempDir()
	fakeGradlew(t, root, "exit 3")

	Prepare(root, cacheDir, os.Environ(), false)
	projects := Projects(root, cacheDir)

	if len(projects) != 1 || projects[0].Type != "gradle" {
		t.Fatalf("projects = %v, want only the gradle project", projects)
	}
}
