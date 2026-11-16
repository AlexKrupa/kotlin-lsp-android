package lsp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
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

// kotlin-lsp sends this text only to the client whose initialize started the import.
const importFailurePrefix = "Unable to import a Gradle project: "

// ImportFailed reports whether body is the error log message of kotlin-lsp about a failed Gradle
// import.
func ImportFailed(body []byte) bool {
	// Most messages are responses, some of them large. The search skips their decode.
	if !bytes.Contains(body, []byte(importFailurePrefix)) {
		return false
	}
	var message struct {
		Method string `json:"method"`
		Params struct {
			Type    int    `json:"type"`
			Message string `json:"message"`
		} `json:"params"`
	}
	if err := json.Unmarshal(body, &message); err != nil {
		return false
	}
	return message.Method == "window/logMessage" &&
		message.Params.Type == messageTypeError &&
		strings.HasPrefix(message.Params.Message, importFailurePrefix)
}
