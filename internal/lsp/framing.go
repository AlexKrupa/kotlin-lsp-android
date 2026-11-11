package lsp

import (
	"bufio"
	"fmt"
	"io"
	"net/textproto"
	"strconv"
)

// ReadMessage returns io.EOF when the stream ends before a message starts.
func ReadMessage(r *bufio.Reader) ([]byte, error) {
	headers, err := textproto.NewReader(r).ReadMIMEHeader()
	if err != nil {
		if err == io.EOF && len(headers) == 0 {
			return nil, io.EOF
		}
		return nil, fmt.Errorf("read LSP headers: %w", err)
	}
	value := headers.Get("Content-Length")
	length, err := strconv.Atoi(value)
	if err != nil || length < 0 {
		return nil, fmt.Errorf("invalid LSP Content-Length %q", value)
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, fmt.Errorf("read LSP body of %d bytes: %w", length, err)
	}
	return body, nil
}

func WriteMessage(w io.Writer, body []byte) error {
	message := append([]byte(fmt.Sprintf("Content-Length: %d\r\n\r\n", len(body))), body...)
	if _, err := w.Write(message); err != nil {
		return fmt.Errorf("write LSP message of %d bytes: %w", len(body), err)
	}
	return nil
}
