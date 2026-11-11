// Command kotlin-lsp-android connects an LSP client on stdin and stdout to one shared kotlin-lsp
// server per Gradle root. It ignores its arguments, for example --stdio, except for the first
// argument "variant": "variant list" and "variant set <name>" select the build variant. The
// first argument "download <cacheDir>" is for the background process that the proxy starts.
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	initscript "github.com/AlexKrupa/kotlin-lsp-android/gradle"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/download"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/proxy"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/root"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/server"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/sources"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/variant"
)

// serverClosedExitCode tells the Neovim plugin to start the client again.
const serverClosedExitCode = 3

func main() {
	err := run()
	if err == nil {
		return
	}
	fmt.Fprintf(os.Stderr, "kotlin-lsp-android: %v\n", err)
	if errors.Is(err, proxy.ErrServerClosed) {
		os.Exit(serverClosedExitCode)
	}
	os.Exit(1)
}

func run() error {
	if len(os.Args) == 3 && os.Args[1] == "download" {
		return download.Run(os.Args[2])
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
	if len(os.Args) > 1 && os.Args[1] == "variant" {
		return runVariant(rootPath, cacheDir, os.Args[2:])
	}
	scriptPath, err := initscript.Write(cacheDir)
	if err != nil {
		return err
	}
	env := server.Env(cacheDir, scriptPath)
	prepare := func() {
		if sources.Exists(cacheDir) {
			return
		}
		// If this run fails, the server starts without library sources.
		if err := sources.Prepare(rootPath, scriptPath, env); err != nil {
			fmt.Fprintf(os.Stderr, "kotlin-lsp-android: library sources: %v\n", err)
		}
	}
	conn, err := server.Ensure(rootPath, cacheDir, env, prepare)
	if err != nil {
		return err
	}
	if err := download.Start(cacheDir); err != nil {
		fmt.Fprintf(os.Stderr, "kotlin-lsp-android: download sources: %v\n", err)
	}
	return proxy.Run(os.Stdin, os.Stdout, conn, sources.Projects(rootPath, cacheDir))
}

func runVariant(rootPath, cacheDir string, args []string) error {
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
