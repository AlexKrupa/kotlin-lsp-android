// Package proxy copies LSP messages between a client and a server connection.
package proxy

import (
	"bufio"
	"fmt"
	"io"
	"net"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

// Run copies messages in both directions and adds projects to the initialize request.
// It returns when one side closes, and then closes conn.
func Run(clientIn io.Reader, clientOut io.Writer, conn net.Conn, projects []lsp.Project) error {
	defer conn.Close()
	done := make(chan error, 2)
	go func() { done <- copyToServer(clientIn, conn, projects) }()
	go func() {
		if _, err := io.Copy(clientOut, conn); err != nil {
			done <- fmt.Errorf("copy server messages to client: %w", err)
			return
		}
		done <- nil
	}()
	return <-done
}

func copyToServer(clientIn io.Reader, conn net.Conn, projects []lsp.Project) error {
	reader := bufio.NewReader(clientIn)
	for {
		body, err := lsp.ReadMessage(reader)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read client message: %w", err)
		}
		if body, err = lsp.RewriteInitialize(body, projects); err != nil {
			return err
		}
		if err := lsp.WriteMessage(conn, body); err != nil {
			return fmt.Errorf("send client message to server: %w", err)
		}
	}
}
