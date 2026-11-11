// Command kotlin-lsp-android connects an LSP client on stdin and stdout to one shared kotlin-lsp
// server per Gradle root. It ignores its arguments, for example --stdio, except for the first
// argument "variant": "variant list" and "variant set <name>" select the build variant.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	initscript "github.com/AlexKrupa/kotlin-lsp-android/gradle"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/proxy"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/root"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/server"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/sources"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/variant"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "kotlin-lsp-android: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) > 1 && os.Args[1] == "variant" {
		return runVariant(os.Args[2:])
	}
	dir, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("get working directory: %w", err)
	}
	rootPath, err := root.Find(dir)
	if err != nil {
		return err
	}
	cacheDir := root.CacheDir(rootPath)
	scriptPath, err := initscript.Write(cacheDir)
	if err != nil {
		return err
	}
	env := server.Env(cacheDir, scriptPath)
	// The server starts without library sources when this run fails.
	if err := sources.Prepare(rootPath, cacheDir, env, false); err != nil {
		fmt.Fprintf(os.Stderr, "kotlin-lsp-android: library sources: %v\n", err)
	}
	conn, err := server.Ensure(rootPath, cacheDir, env)
	if err != nil {
		return err
	}
	return proxy.Run(os.Stdin, os.Stdout, conn, sources.Projects(rootPath, cacheDir))
}

func runVariant(args []string) error {
	dir, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("get working directory: %w", err)
	}
	rootPath, err := root.Find(dir)
	if err != nil {
		return err
	}
	cacheDir := root.CacheDir(rootPath)
	switch {
	case len(args) == 1 && args[0] == "list":
		names, err := variant.List(cacheDir)
		if err != nil {
			return err
		}
		for _, name := range names {
			fmt.Println(name)
		}
		return nil
	case len(args) == 2 && args[0] == "set":
		return variant.Set(rootPath, cacheDir, args[1])
	default:
		return fmt.Errorf("usage: %s variant list | variant set <name>", filepath.Base(os.Args[0]))
	}
}
