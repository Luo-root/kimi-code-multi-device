package replay

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestParseWirePreservesStructuredEditArgs(t *testing.T) {
	path := writeWireFixture(t, []map[string]interface{}{
		{
			"type": "context.append_loop_event",
			"event": map[string]interface{}{
				"type":       "tool.call",
				"toolCallId": "edit-1",
				"name":       "Edit",
				"args": map[string]interface{}{
					"path":       "lib/a.dart",
					"old_string": "before",
					"new_string": "after",
				},
			},
		},
		{
			"type": "context.append_loop_event",
			"event": map[string]interface{}{
				"type":       "tool.result",
				"toolCallId": "edit-1",
				"result": map[string]interface{}{
					"output": "Replaced 1 occurrence",
				},
			},
		},
	})

	blocks, err := parseWire(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(blocks) != 1 {
		t.Fatalf("got %d blocks, want 1", len(blocks))
	}
	block := blocks[0]
	if block.ToolName != "Edit" || block.ToolCallID != "edit-1" {
		t.Fatalf("unexpected tool block: %+v", block)
	}
	var args map[string]interface{}
	if err := json.Unmarshal([]byte(block.Command), &args); err != nil {
		t.Fatalf("command is not preserved JSON: %q: %v", block.Command, err)
	}
	for key, want := range map[string]string{
		"path": "lib/a.dart", "old_string": "before", "new_string": "after",
	} {
		if got := args[key]; got != want {
			t.Errorf("args[%q] = %#v, want %q", key, got, want)
		}
	}
	if block.Output != "Replaced 1 occurrence" {
		t.Fatalf("output = %q", block.Output)
	}
}

func TestParseWireKeepsBashCommandConcise(t *testing.T) {
	path := writeWireFixture(t, []map[string]interface{}{
		{
			"type": "context.append_loop_event",
			"event": map[string]interface{}{
				"type":       "tool.call",
				"toolCallId": "bash-1",
				"name":       "Bash",
				"args": map[string]interface{}{
					"command":     "echo ok",
					"description": "probe",
				},
			},
		},
	})

	blocks, err := parseWire(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(blocks) != 1 || blocks[0].Command != "echo ok" {
		t.Fatalf("unexpected blocks: %+v", blocks)
	}
}

func writeWireFixture(t *testing.T, items []map[string]interface{}) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "wire.jsonl")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	encoder := json.NewEncoder(file)
	for _, item := range items {
		if err := encoder.Encode(item); err != nil {
			t.Fatal(err)
		}
	}
	return path
}
