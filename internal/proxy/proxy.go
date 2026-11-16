package proxy

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

// ErrServerClosed means that the server closed the connection before the client.
var ErrServerClosed = errors.New("the server closed the connection")

// Run copies messages between the client and the server. After a failed Gradle import, it sends
// to failures without a wait.
func Run(clientIn io.Reader, clientOut io.Writer, conn net.Conn, projects []lsp.Project, failures chan<- struct{}) error {
	defer conn.Close()
	done := make(chan error, 2)
	go func() { done <- copyToServer(clientIn, conn, projects) }()
	go func() { done <- copyToClient(conn, clientOut, failures) }()
	return <-done
}

func copyToClient(conn net.Conn, clientOut io.Writer, failures chan<- struct{}) error {
	reader := bufio.NewReader(conn)
	for {
		body, err := lsp.ReadMessage(reader)
		if err == io.EOF {
			return ErrServerClosed
		}
		if err != nil {
			return fmt.Errorf("read server message: %w", err)
		}
		if lsp.ImportFailed(body) {
			select {
			case failures <- struct{}{}:
			default:
			}
		}
		if err := lsp.WriteMessage(clientOut, body); err != nil {
			return fmt.Errorf("send server message to client: %w", err)
		}
	}
}

func copyToServer(clientIn io.Reader, conn net.Conn, projects []lsp.Project) error {
	reader := bufio.NewReader(clientIn)
	// Only the first message of a client is the initialize request, so later bodies need no decode.
	rewritten := false
	for {
		body, err := lsp.ReadMessage(reader)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read client message: %w", err)
		}
		if !rewritten {
			if body, err = lsp.RewriteInitialize(body, projects); err != nil {
				return err
			}
			rewritten = true
		}
		if err := lsp.WriteMessage(conn, body); err != nil {
			return fmt.Errorf("send client message to server: %w", err)
		}
	}
}
