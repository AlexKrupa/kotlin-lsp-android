package root

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func touch(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestFindPrefersSettingsOverModuleBuildFile(t *testing.T) {
	base := t.TempDir()
	touch(t, filepath.Join(base, "a", "settings.gradle.kts"))
	touch(t, filepath.Join(base, "a", "m", "build.gradle.kts"))
	start := filepath.Join(base, "a", "m", "src")
	if err := os.MkdirAll(start, 0o755); err != nil {
		t.Fatal(err)
	}

	found, err := Find(start)

	if err != nil {
		t.Fatalf("Find returned error: %v", err)
	}
	if want := filepath.Join(base, "a"); found != want {
		t.Fatalf("root = %q, want %q", found, want)
	}
}

func TestFindFallsBackToBuildFile(t *testing.T) {
	base := t.TempDir()
	touch(t, filepath.Join(base, "a", "build.gradle"))

	found, err := Find(filepath.Join(base, "a"))

	if err != nil {
		t.Fatalf("Find returned error: %v", err)
	}
	if want := filepath.Join(base, "a"); found != want {
		t.Fatalf("root = %q, want %q", found, want)
	}
}

func TestFindFailsWithNoMarker(t *testing.T) {
	base := t.TempDir()

	_, err := Find(base)

	if err == nil {
		t.Fatal("Find returned no error")
	}
	if !strings.Contains(err.Error(), base) {
		t.Fatalf("error %q does not name %q", err, base)
	}
}

func TestKeyMatchesShellWrapper(t *testing.T) {
	// printf %s /Users/x/src/oss/nowinandroid | shasum -a 256, first 12 characters
	if got := Key("/Users/x/src/oss/nowinandroid"); got != "695345205bef" {
		t.Fatalf("key = %q, want 695345205bef", got)
	}
}

func TestKeyOfPathWithSpacesAndUnicode(t *testing.T) {
	first := Key("/tmp/a b/ąę")

	if !regexp.MustCompile(`^[0-9a-f]{12}$`).MatchString(first) {
		t.Fatalf("key = %q, want 12 hex characters", first)
	}
	if second := Key("/tmp/a b/ąę"); second != first {
		t.Fatalf("key changed: %q then %q", first, second)
	}
}

func TestCacheRootUsesEnvironmentOverride(t *testing.T) {
	t.Setenv("KOTLIN_LSP_CACHE", "/custom/cache")

	if got := CacheRoot(); got != "/custom/cache" {
		t.Fatalf("CacheRoot = %q", got)
	}
	if got, want := CacheDir("/r"), filepath.Join("/custom/cache", Key("/r")); got != want {
		t.Fatalf("CacheDir = %q, want %q", got, want)
	}
}

func TestCacheRootDefaultsToHomeCache(t *testing.T) {
	t.Setenv("KOTLIN_LSP_CACHE", "")
	t.Setenv("HOME", "/home/x")

	if got, want := CacheRoot(), "/home/x/.cache/kotlin-lsp"; got != want {
		t.Fatalf("CacheRoot = %q, want %q", got, want)
	}
}
