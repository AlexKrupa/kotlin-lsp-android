package proxy

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
	"github.com/AlexKrupa/kotlin-lsp-android/internal/server"
)

func TestMain(m *testing.M) {
	binDir, err := os.MkdirTemp("", "fakeserver")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary := filepath.Join(binDir, "fakeserver")
	build := exec.Command("go", "build", "-o", binary, "../server/testdata/fakeserver")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "build fake server:", err)
		os.Exit(1)
	}
	os.Setenv("KOTLIN_LSP_SERVER", binary)
	code := m.Run()
	os.RemoveAll(binDir)
	os.Exit(code)
}

func TestProxyRewritesInitializeAndCopiesBothWays(t *testing.T) {
	cacheDir := t.TempDir()
	conn, err := server.Ensure(os.TempDir(), cacheDir, os.Environ(), func() {})
	if err != nil {
		t.Fatalf("Ensure returned error: %v", err)
	}
	t.Cleanup(func() { server.Stop(cacheDir) })
	clientIn, toProxy := io.Pipe()
	fromProxy, clientOut := io.Pipe()
	projects := []lsp.Project{{Type: "gradle", Path: "file:///project"}}
	result := make(chan error, 1)
	go func() { result <- Run(clientIn, clientOut, conn, projects) }()
	replies := bufio.NewReader(fromProxy)

	initialize := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`
	if err := lsp.WriteMessage(toProxy, []byte(initialize)); err != nil {
		t.Fatalf("write initialize: %v", err)
	}
	initializeReply, err := lsp.ReadMessage(replies)
	if err != nil {
		t.Fatalf("read initialize reply: %v", err)
	}
	didOpen := `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{}}`
	if err := lsp.WriteMessage(toProxy, []byte(didOpen)); err != nil {
		t.Fatalf("write didOpen: %v", err)
	}
	didOpenReply, err := lsp.ReadMessage(replies)
	if err != nil {
		t.Fatalf("read didOpen reply: %v", err)
	}
	toProxy.Close()

	var reply struct {
		Params struct {
			InitializationOptions struct {
				Projects []lsp.Project `json:"projects"`
			} `json:"initializationOptions"`
		} `json:"params"`
	}
	if err := json.Unmarshal(initializeReply, &reply); err != nil {
		t.Fatalf("invalid initialize reply %s: %v", initializeReply, err)
	}
	if got := reply.Params.InitializationOptions.Projects; len(got) != 1 || got[0] != projects[0] {
		t.Fatalf("projects = %v, want %v", got, projects)
	}
	if string(didOpenReply) != didOpen {
		t.Fatalf("didOpen reply = %s, want %s", didOpenReply, didOpen)
	}
	if err := <-result; err != nil {
		t.Fatalf("Run returned error: %v", err)
	}
}

func TestProxyReportsServerClose(t *testing.T) {
	cacheDir := t.TempDir()
	conn, err := server.Ensure(os.TempDir(), cacheDir, os.Environ(), func() {})
	if err != nil {
		t.Fatalf("Ensure returned error: %v", err)
	}
	clientIn, toProxy := io.Pipe()
	defer toProxy.Close()
	result := make(chan error, 1)
	go func() { result <- Run(clientIn, io.Discard, conn, nil) }()

	if err := server.Stop(cacheDir); err != nil {
		t.Fatalf("Stop returned error: %v", err)
	}

	if err := <-result; !errors.Is(err, ErrServerClosed) {
		t.Fatalf("Run returned %v, want ErrServerClosed", err)
	}
}
