package lsp

import (
	"bufio"
	"bytes"
	"encoding/json"
	"testing"
)

func TestWriteErrorMessageWritesShowMessageNotification(t *testing.T) {
	var out bytes.Buffer

	err := WriteErrorMessage(&out, "no Gradle root")

	if err != nil {
		t.Fatalf("WriteErrorMessage returned error: %v", err)
	}
	body, err := ReadMessage(bufio.NewReader(&out))
	if err != nil {
		t.Fatalf("ReadMessage returned error: %v", err)
	}
	var message struct {
		JSONRPC string `json:"jsonrpc"`
		Method  string `json:"method"`
		Params  struct {
			Type    int    `json:"type"`
			Message string `json:"message"`
		} `json:"params"`
	}
	if err := json.Unmarshal(body, &message); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	if message.JSONRPC != "2.0" || message.Method != "window/showMessage" || message.Params.Type != 1 || message.Params.Message != "no Gradle root" {
		t.Fatalf("message = %s, want a window/showMessage error with %q", body, "no Gradle root")
	}
}
