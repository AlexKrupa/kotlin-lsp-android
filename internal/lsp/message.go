package lsp

import (
	"encoding/json"
	"fmt"
	"io"
)

// messageTypeError is the MessageType.Error of the LSP specification.
const messageTypeError = 1

// WriteErrorMessage writes a window/showMessage notification. A server can send it before its
// initialize response.
func WriteErrorMessage(w io.Writer, text string) error {
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"method":  "window/showMessage",
		"params":  map[string]any{"type": messageTypeError, "message": text},
	})
	if err != nil {
		return fmt.Errorf("encode window/showMessage %q: %w", text, err)
	}
	return WriteMessage(w, body)
}
