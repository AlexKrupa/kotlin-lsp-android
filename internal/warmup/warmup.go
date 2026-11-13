// Package warmup opens the project of a root on the server, so that the import and the index load
// end before an editor or an agent connects.
package warmup

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

// kotlin-lsp sends this notification when the import and the indexing end.
const readyMethod = "intellij/ready-for-test"

const initializeID = 1

type serverMessage struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params struct {
		Items []json.RawMessage `json:"items"`
	} `json:"params"`
}

func Run(conn net.Conn, root string, projects []lsp.Project, timeout time.Duration) error {
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return fmt.Errorf("set deadline for the warm-up of %s: %w", root, err)
	}
	initialize, err := initializeRequest(root, projects)
	if err != nil {
		return err
	}
	if err := lsp.WriteMessage(conn, initialize); err != nil {
		return fmt.Errorf("send initialize for %s: %w", root, err)
	}

	reader := bufio.NewReader(conn)
	for {
		body, err := lsp.ReadMessage(reader)
		if err != nil {
			return fmt.Errorf("warm-up of %s did not get %s: %w", root, readyMethod, err)
		}
		var message serverMessage
		if err := json.Unmarshal(body, &message); err != nil {
			return fmt.Errorf("decode server message %s: %w", body, err)
		}
		switch {
		case message.Method == readyMethod:
			return nil
		case message.Method == "" && string(message.ID) == fmt.Sprint(initializeID):
			err = send(conn, map[string]any{"jsonrpc": "2.0", "method": "initialized", "params": map[string]any{}})
		case message.Method != "" && message.ID != nil:
			err = send(conn, map[string]any{"jsonrpc": "2.0", "id": message.ID, "result": result(message)})
		}
		if err != nil {
			return fmt.Errorf("answer %s for %s: %w", message.Method, root, err)
		}
	}
}

func initializeRequest(root string, projects []lsp.Project) ([]byte, error) {
	uri := (&url.URL{Scheme: "file", Path: root}).String()
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      initializeID,
		"method":  "initialize",
		"params": map[string]any{
			"processId":        os.Getpid(),
			"rootUri":          uri,
			"workspaceFolders": []map[string]string{{"uri": uri, "name": filepath.Base(root)}},
			"capabilities":     map[string]any{"window": map[string]any{"workDoneProgress": true}},
		},
	})
	if err != nil {
		return nil, fmt.Errorf("encode initialize for %s: %w", root, err)
	}
	return lsp.RewriteInitialize(body, projects)
}

// workspace/configuration needs one result for each item.
func result(message serverMessage) any {
	if message.Method == "workspace/configuration" {
		return make([]any, len(message.Params.Items))
	}
	return nil
}

func send(conn net.Conn, message map[string]any) error {
	body, err := json.Marshal(message)
	if err != nil {
		return err
	}
	return lsp.WriteMessage(conn, body)
}
