// Command kotlin-lsp-android connects an LSP client on stdin and stdout to one shared kotlin-lsp
// server per Gradle root. It ignores its arguments, for example --stdio.
package main

import (
	"fmt"
	"net/url"
	"os"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/proxy"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/root"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/server"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "kotlin-lsp-android: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	dir, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("get working directory: %w", err)
	}
	rootPath, err := root.Find(dir)
	if err != nil {
		return err
	}
	conn, err := server.Ensure(rootPath, root.CacheDir(rootPath), os.Environ())
	if err != nil {
		return err
	}
	projects := []lsp.Project{{Type: "gradle", Path: (&url.URL{Scheme: "file", Path: rootPath}).String()}}
	return proxy.Run(os.Stdin, os.Stdout, conn, projects)
}
