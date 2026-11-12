package initscript

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWriteCreatesScriptInMissingFolder(t *testing.T) {
	cacheDir := filepath.Join(t.TempDir(), "new", "cache")

	path, err := Write(cacheDir)
	if err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if path != filepath.Join(cacheDir, "lsp-library-sources.gradle") || !bytes.Equal(content, script) {
		t.Fatalf("path = %s, content equals embedded script: %v", path, bytes.Equal(content, script))
	}
}

func TestWriteKeepsFileWithSameContent(t *testing.T) {
	cacheDir := t.TempDir()
	path, err := Write(cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	past := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(path, past, past); err != nil {
		t.Fatal(err)
	}

	if _, err := Write(cacheDir); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(past) {
		t.Fatalf("modification time = %v, want %v", info.ModTime(), past)
	}
}

func TestWriteReplacesChangedFile(t *testing.T) {
	cacheDir := t.TempDir()
	path := filepath.Join(cacheDir, fileName)
	if err := os.WriteFile(path, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := Write(cacheDir); err != nil {
		t.Fatal(err)
	}

	content, _ := os.ReadFile(path)
	if !bytes.Equal(content, script) {
		t.Fatal("file does not have the embedded content")
	}
}

func TestWriteClientCreatesClientInMissingFolder(t *testing.T) {
	cacheDir := filepath.Join(t.TempDir(), "new", "cache")

	path, err := WriteClient(cacheDir)
	if err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if path != filepath.Join(cacheDir, "ScriptModel.java") || !bytes.Equal(content, client) {
		t.Fatalf("path = %s, content equals embedded client: %v", path, bytes.Equal(content, client))
	}
}

func TestWriteClientKeepsFileWithSameContent(t *testing.T) {
	cacheDir := t.TempDir()
	path, err := WriteClient(cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	past := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(path, past, past); err != nil {
		t.Fatal(err)
	}

	if _, err := WriteClient(cacheDir); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(past) {
		t.Fatalf("modification time = %v, want %v", info.ModTime(), past)
	}
}

func TestWriteClientReplacesChangedFile(t *testing.T) {
	cacheDir := t.TempDir()
	path := filepath.Join(cacheDir, clientFileName)
	if err := os.WriteFile(path, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := WriteClient(cacheDir); err != nil {
		t.Fatal(err)
	}

	content, _ := os.ReadFile(path)
	if !bytes.Equal(content, client) {
		t.Fatal("file does not have the embedded content")
	}
}
