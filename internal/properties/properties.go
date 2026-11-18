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
	// JavaHome is the JDK of Gradle: the java-home key, or else the JAVA_HOME variable. Without
	// the key, the JDK depends on the environment of the client that starts the server.
	JavaHome string
}

var heapPattern = regexp.MustCompile(`^[0-9]+[kKmMgG]?$`)

func Read(root string) (Properties, error) {
	path := filepath.Join(root, FileName)
	content, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Properties{JavaHome: os.Getenv("JAVA_HOME")}, nil
	}
	if err != nil {
		return Properties{}, fmt.Errorf("read %s: %w", path, err)
	}

	read := Properties{JavaHome: os.Getenv("JAVA_HOME")}
	for lineIndex, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if !found {
			return Properties{}, fmt.Errorf("%s:%d: %q has no =", path, lineIndex+1, key)
		}
		switch key {
		case "heap":
			if !heapPattern.MatchString(value) {
				return Properties{}, fmt.Errorf("%s:%d: heap %q is not a size like 6g or 4096m", path, lineIndex+1, value)
			}
			read.Heap = value
		case "java-home":
			// kotlin-lsp uses the JDK with no check.
			if _, err := os.Stat(filepath.Join(value, "bin", "java")); err != nil {
				return Properties{}, fmt.Errorf("%s:%d: java-home %q has no bin/java", path, lineIndex+1, value)
			}
			read.JavaHome = value
		default:
			return Properties{}, fmt.Errorf("%s:%d: unknown key %q, the known keys are heap and java-home", path, lineIndex+1, key)
		}
	}
	return read, nil
}
