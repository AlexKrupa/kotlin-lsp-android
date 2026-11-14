// Package properties reads the optional file of a root with the settings of its server.
package properties

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const FileName = ".kotlin-lsp.properties"

type Properties struct {
	// Heap is the maximum heap size of the server in the format of -Xmx, for example 6g.
	Heap string
}

var heapPattern = regexp.MustCompile(`^[0-9]+[kKmMgG]?$`)

func Read(root string) (Properties, error) {
	path := filepath.Join(root, FileName)
	content, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Properties{}, nil
	}
	if err != nil {
		return Properties{}, fmt.Errorf("read %s: %w", path, err)
	}

	var read Properties
	for lineIndex, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		switch {
		case !found:
			return Properties{}, fmt.Errorf("%s:%d: %q has no =", path, lineIndex+1, key)
		case key != "heap":
			return Properties{}, fmt.Errorf("%s:%d: unknown key %q, the known key is heap", path, lineIndex+1, key)
		case !heapPattern.MatchString(value):
			return Properties{}, fmt.Errorf("%s:%d: heap %q is not a size like 6g or 4096m", path, lineIndex+1, value)
		}
		read.Heap = value
	}
	return read, nil
}
