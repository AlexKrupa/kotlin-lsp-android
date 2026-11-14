package properties

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeProperties(t *testing.T, content string) string {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, FileName), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestReadGivesHeap(t *testing.T) {
	root := writeProperties(t, "# Server of the large repo\n\n heap = 6g \n")

	read, err := Read(root)

	if err != nil {
		t.Fatalf("Read returned error: %v", err)
	}
	if read.Heap != "6g" {
		t.Fatalf("heap = %q, want 6g", read.Heap)
	}
}

func TestReadGivesNoValuesWithoutFile(t *testing.T) {
	read, err := Read(t.TempDir())

	if err != nil {
		t.Fatalf("Read returned error: %v", err)
	}
	if read != (Properties{}) {
		t.Fatalf("properties = %+v, want no values", read)
	}
}

func TestReadRejectsInvalidFiles(t *testing.T) {
	for content, wantText := range map[string]string{
		"heap=6 GB\n": `"6 GB"`,
		"heep=6g\n":   `"heep"`,
		"heap\n":      `"heap"`,
		"heap=\n":     `""`,
	} {
		root := writeProperties(t, content)

		_, err := Read(root)

		if err == nil {
			t.Errorf("Read(%q) returned no error", content)
			continue
		}
		for _, want := range []string{wantText, filepath.Join(root, FileName)} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("Read(%q) error %q does not contain %s", content, err, want)
			}
		}
	}
}
