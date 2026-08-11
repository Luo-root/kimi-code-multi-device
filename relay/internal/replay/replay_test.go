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

func TestListSessionsFromDisk(t *testing.T) {
	home := t.TempDir()
	sessionsDir := filepath.Join(home, "sessions", "wd_test_abc123")
	if err := os.MkdirAll(sessionsDir, 0o755); err != nil {
		t.Fatal(err)
	}

	sid := "session_11111111-1111-1111-1111-111111111111"
	sDir := filepath.Join(sessionsDir, sid)
	if err := os.MkdirAll(sDir, 0o755); err != nil {
		t.Fatal(err)
	}
	state := map[string]interface{}{
		"title":     "disk session",
		"createdAt": "2026-08-10T17:27:38.722Z",
		"updatedAt": "2026-08-10T17:29:47.810Z",
		"workDir":   "D:/project/relay",
	}
	if err := os.WriteFile(filepath.Join(sDir, "state.json"), mustJSON(t, state), 0o644); err != nil {
		t.Fatal(err)
	}

	idxRec := map[string]interface{}{
		"sessionId":  sid,
		"sessionDir": sDir,
		"workDir":    "D:/project/relay",
	}
	if err := os.WriteFile(filepath.Join(home, "session_index.jsonl"), mustJSON(t, idxRec), 0o644); err != nil {
		t.Fatal(err)
	}

	metas, err := ListSessionsFromDisk(home)
	if err != nil {
		t.Fatal(err)
	}
	if len(metas) != 1 {
		t.Fatalf("got %d metas, want 1", len(metas))
	}
	m := metas[0]
	if m.SessionID != sid || m.Title != "disk session" || m.CWD != "D:/project/relay" || m.UpdatedAt != "2026-08-10T17:29:47.810Z" {
		t.Fatalf("unexpected meta: %+v", m)
	}
}

func mustJSON(t *testing.T, v interface{}) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return append(b, '\n')
}
