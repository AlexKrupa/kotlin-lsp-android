package warmup

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

type message struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
}

// fakeServer is the server end of a connection to Run.
type fakeServer struct {
	t      *testing.T
	conn   net.Conn
	reader *bufio.Reader
}

func newFakeServer(t *testing.T) (*fakeServer, net.Conn) {
	serverConn, clientConn := net.Pipe()
	t.Cleanup(func() { serverConn.Close() })
	return &fakeServer{t: t, conn: serverConn, reader: bufio.NewReader(serverConn)}, clientConn
}

func (server *fakeServer) read() message {
	server.t.Helper()
	body, err := lsp.ReadMessage(server.reader)
	if err != nil {
		server.t.Fatalf("read client message: %v", err)
	}
	var decoded message
	if err := json.Unmarshal(body, &decoded); err != nil {
		server.t.Fatalf("decode client message %s: %v", body, err)
	}
	return decoded
}

func (server *fakeServer) send(body string) {
	server.t.Helper()
	if err := lsp.WriteMessage(server.conn, []byte(body)); err != nil {
		server.t.Fatalf("send server message: %v", err)
	}
}

func run(conn net.Conn, root string, timeout time.Duration) chan error {
	done := make(chan error, 1)
	projects := []lsp.Project{{Type: "jsonFile", Path: "file:///cache/workspace.json"}}
	go func() { done <- Run(conn, root, projects, timeout) }()
	return done
}

func TestRunInitializesRootAndWaitsForReady(t *testing.T) {
	server, conn := newFakeServer(t)
	done := run(conn, "/src/app", time.Minute)

	initialize := server.read()
	server.send(`{"jsonrpc":"2.0","id":"create-1","method":"window/workDoneProgress/create","params":{"token":"t"}}`)
	progressResponse := server.read()
	server.send(`{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}`)
	initialized := server.read()
	server.send(`{"jsonrpc":"2.0","method":"intellij/ready-for-test","params":{}}`)

	if initialize.Method != "initialize" {
		t.Fatalf("first message = %q, want initialize", initialize.Method)
	}
	params := string(initialize.Params)
	for _, want := range []string{`"rootUri":"file:///src/app"`, `"uri":"file:///src/app"`, `"path":"file:///cache/workspace.json"`} {
		if !strings.Contains(params, want) {
			t.Fatalf("initialize params %s do not contain %s", params, want)
		}
	}
	if string(progressResponse.ID) != `"create-1"` || progressResponse.Method != "" {
		t.Fatalf("response to the server request = %+v, want the result for id create-1", progressResponse)
	}
	if initialized.Method != "initialized" {
		t.Fatalf("message after the initialize response = %q, want initialized", initialized.Method)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run returned error: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run still waits after the ready notification")
	}
}

func TestRunAnswersConfigurationWithOneResultForEachItem(t *testing.T) {
	server, conn := newFakeServer(t)
	run(conn, "/src/app", time.Minute)
	server.read()

	server.send(`{"jsonrpc":"2.0","id":7,"method":"workspace/configuration","params":{"items":[{},{}]}}`)

	if response := server.read(); string(response.Result) != "[null,null]" {
		t.Fatalf("configuration result = %s, want [null,null]", response.Result)
	}
}

func TestRunFailsAfterTimeout(t *testing.T) {
	server, conn := newFakeServer(t)
	done := run(conn, "/src/app", 200*time.Millisecond)
	server.read()

	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "/src/app") {
			t.Fatalf("Run error = %v, want a timeout error that names the root", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run still waits after the timeout")
	}
}
