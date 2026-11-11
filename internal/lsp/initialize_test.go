package lsp

import (
	"encoding/json"
	"testing"
)

var twoProjects = []Project{
	{Type: "gradle", Path: "file:///root"},
	{Type: "json", Path: "file:///cache/workspace.json"},
}

func objectOf(t *testing.T, body []byte) map[string]json.RawMessage {
	t.Helper()
	var object map[string]json.RawMessage
	if err := json.Unmarshal(body, &object); err != nil {
		t.Fatalf("invalid JSON %s: %v", body, err)
	}
	return object
}

func optionsOf(t *testing.T, body []byte) map[string]json.RawMessage {
	t.Helper()
	params := objectOf(t, objectOf(t, body)["params"])
	return objectOf(t, params["initializationOptions"])
}

func projectsOf(t *testing.T, options map[string]json.RawMessage) []Project {
	t.Helper()
	var projects []Project
	if err := json.Unmarshal(options["projects"], &projects); err != nil {
		t.Fatalf("invalid projects %s: %v", options["projects"], err)
	}
	return projects
}

func TestRewriteInitializeAddsProjects(t *testing.T) {
	body := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":1}}`)

	rewritten, err := RewriteInitialize(body, twoProjects)

	if err != nil {
		t.Fatalf("RewriteInitialize returned error: %v", err)
	}
	projects := projectsOf(t, optionsOf(t, rewritten))
	if len(projects) != 2 || projects[0] != twoProjects[0] || projects[1] != twoProjects[1] {
		t.Fatalf("projects = %v, want %v", projects, twoProjects)
	}
}

func TestRewriteInitializeKeepsClientOptions(t *testing.T) {
	body := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"initializationOptions":` +
		`{"defaultSdk":"x","projects":[{"type":"maven","path":"file:///m"}]}}}`)

	rewritten, err := RewriteInitialize(body, twoProjects)

	if err != nil {
		t.Fatalf("RewriteInitialize returned error: %v", err)
	}
	options := optionsOf(t, rewritten)
	if string(options["defaultSdk"]) != `"x"` {
		t.Fatalf("defaultSdk = %s", options["defaultSdk"])
	}
	projects := projectsOf(t, options)
	want := []Project{{Type: "maven", Path: "file:///m"}, twoProjects[0], twoProjects[1]}
	if len(projects) != len(want) {
		t.Fatalf("projects = %v, want %v", projects, want)
	}
	for index := range want {
		if projects[index] != want[index] {
			t.Fatalf("projects = %v, want %v", projects, want)
		}
	}
}

func TestRewriteInitializeKeepsOtherMessages(t *testing.T) {
	body := []byte(`{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.kt"}}}`)

	rewritten, err := RewriteInitialize(body, twoProjects)

	if err != nil {
		t.Fatalf("RewriteInitialize returned error: %v", err)
	}
	if string(rewritten) != string(body) {
		t.Fatalf("rewritten = %s, want %s", rewritten, body)
	}
}

func TestRewriteInitializeKeepsUnknownFields(t *testing.T) {
	body := []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","extra":true,"params":{"x":{"y":1}}}`)

	rewritten, err := RewriteInitialize(body, twoProjects)

	if err != nil {
		t.Fatalf("RewriteInitialize returned error: %v", err)
	}
	top := objectOf(t, rewritten)
	if string(top["extra"]) != "true" {
		t.Fatalf("extra = %s", top["extra"])
	}
	params := objectOf(t, top["params"])
	if string(params["x"]) != `{"y":1}` {
		t.Fatalf("x = %s", params["x"])
	}
}
