package lsp

import (
	"bufio"
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestReadMessageReadsBodyOfContentLength(t *testing.T) {
	reader := bufio.NewReader(strings.NewReader("Content-Length: 2\r\nContent-Type: x\r\n\r\n{}"))

	body, err := ReadMessage(reader)

	if err != nil {
		t.Fatalf("ReadMessage returned error: %v", err)
	}
	if string(body) != "{}" {
		t.Fatalf("body = %q, want %q", body, "{}")
	}
}

func TestReadMessageReturnsEOFAtEnd(t *testing.T) {
	reader := bufio.NewReader(strings.NewReader(""))

	_, err := ReadMessage(reader)

	if err != io.EOF {
		t.Fatalf("err = %v, want io.EOF", err)
	}
}

func TestWriteMessageAddsContentLength(t *testing.T) {
	var out bytes.Buffer

	err := WriteMessage(&out, []byte("{}"))

	if err != nil {
		t.Fatalf("WriteMessage returned error: %v", err)
	}
	if out.String() != "Content-Length: 2\r\n\r\n{}" {
		t.Fatalf("output = %q", out.String())
	}
}
