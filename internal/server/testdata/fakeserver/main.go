// Command fakeserver is a stand-in for kotlin-lsp in tests. It accepts the server arguments of
// server.Ensure and echoes each LSP message back to its sender.
//
// In the --system-path folder, it adds one line to `starts` for each start and writes its
// environment to `env`. With FAKE_SERVER_SILENT set, it never listens.
package main

import (
	"bufio"
	"flag"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/AlexKrupa/kotlin-lsp-android/internal/lsp"
)

func main() {
	socket := flag.String("socket", "", "address to listen on")
	portFile := flag.String("port-file", "", "file for the bound port")
	systemPath := flag.String("system-path", "", "folder for the test records")
	flag.Bool("multi-client", false, "ignored")
	flag.Parse()

	starts, err := os.OpenFile(filepath.Join(*systemPath, "starts"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Fatal(err)
	}
	if _, err := starts.WriteString("start\n"); err != nil {
		log.Fatal(err)
	}
	starts.Close()
	if err := os.WriteFile(filepath.Join(*systemPath, "env"), []byte(strings.Join(os.Environ(), "\n")), 0o644); err != nil {
		log.Fatal(err)
	}

	if os.Getenv("FAKE_SERVER_SILENT") != "" {
		time.Sleep(time.Hour)
		return
	}
	listener, err := net.Listen("tcp", *socket)
	if err != nil {
		log.Fatal(err)
	}
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	if err := os.WriteFile(*portFile, []byte(port), 0o644); err != nil {
		log.Fatal(err)
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go echo(conn)
	}
}

func echo(conn net.Conn) {
	defer conn.Close()
	reader := bufio.NewReader(conn)
	for {
		body, err := lsp.ReadMessage(reader)
		if err != nil {
			return
		}
		if err := lsp.WriteMessage(conn, body); err != nil {
			return
		}
	}
}
