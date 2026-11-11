package lsp

import (
	"encoding/json"
	"fmt"
)

// Project is an entry of the initializationOptions.projects list of kotlin-lsp.
// Path is a file:// URI.
type Project struct {
	Type string `json:"type"`
	Path string `json:"path"`
}

// RewriteInitialize appends projects to initializationOptions.projects of an initialize request.
// It keeps all other fields. For any other method it returns body with no change.
func RewriteInitialize(body []byte, projects []Project) ([]byte, error) {
	var message map[string]json.RawMessage
	if err := json.Unmarshal(body, &message); err != nil {
		return nil, fmt.Errorf("decode LSP message: %w", err)
	}
	var method string
	if err := json.Unmarshal(message["method"], &method); err != nil || method != "initialize" {
		return body, nil
	}

	params, err := decodeObject(message["params"], "params")
	if err != nil {
		return nil, err
	}
	options, err := decodeObject(params["initializationOptions"], "initializationOptions")
	if err != nil {
		return nil, err
	}
	var existing []json.RawMessage
	if raw, found := options["projects"]; found && string(raw) != "null" {
		if err := json.Unmarshal(raw, &existing); err != nil {
			return nil, fmt.Errorf("decode initializationOptions.projects: %w", err)
		}
	}
	for _, project := range projects {
		encoded, err := json.Marshal(project)
		if err != nil {
			return nil, fmt.Errorf("encode project %+v: %w", project, err)
		}
		existing = append(existing, encoded)
	}

	if options["projects"], err = json.Marshal(existing); err != nil {
		return nil, fmt.Errorf("encode projects: %w", err)
	}
	if params["initializationOptions"], err = json.Marshal(options); err != nil {
		return nil, fmt.Errorf("encode initializationOptions: %w", err)
	}
	if message["params"], err = json.Marshal(params); err != nil {
		return nil, fmt.Errorf("encode params: %w", err)
	}
	return json.Marshal(message)
}

// decodeObject returns an empty object for a missing or null value.
func decodeObject(raw json.RawMessage, name string) (map[string]json.RawMessage, error) {
	object := map[string]json.RawMessage{}
	if len(raw) == 0 || string(raw) == "null" {
		return object, nil
	}
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, fmt.Errorf("decode %s as object: %w", name, err)
	}
	return object, nil
}
