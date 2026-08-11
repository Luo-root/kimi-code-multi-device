package replay

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDeleteSession verifies deleting a session directly from storage:
// the session directory is removed, the index entry is dropped, and other
// sessions are untouched.
func TestDeleteSession(t *testing.T) {
	home := t.TempDir()
	sid := "session_abc123"
	wdHash := "wd_test"
	sessionDir := filepath.Join(home, "sessions", wdHash, sid)
	if err := os.MkdirAll(filepath.Join(sessionDir, "agents", "main"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sessionDir, "state.json"), []byte(`{"title":"t"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sessionDir, "agents", "main", "wire.jsonl"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	otherDir := filepath.Join(home, "sessions", wdHash, "session_other")
	if err := os.MkdirAll(otherDir, 0o755); err != nil {
		t.Fatal(err)
	}
	idx := filepath.Join(home, "session_index.jsonl")
	// Build a valid index via json.Marshal (real kimi does the same; backslashes
	// in Windows paths are correctly escaped).
	type idxRec struct {
		SessionID  string `json:"sessionId"`
		SessionDir string `json:"sessionDir"`
	}
	recs := []idxRec{
		{SessionID: "session_other", SessionDir: otherDir},
		{SessionID: sid, SessionDir: sessionDir},
	}
	var ib strings.Builder
	for _, r := range recs {
		line, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		ib.Write(line)
		ib.WriteByte('\n')
	}
	if err := os.WriteFile(idx, []byte(ib.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := DeleteSession(home, sid); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
	if _, err := os.Stat(sessionDir); !os.IsNotExist(err) {
		t.Fatalf("session dir should be removed")
	}
	if _, err := os.Stat(otherDir); err != nil {
		t.Fatalf("other session dir should remain: %v", err)
	}
	data, err := os.ReadFile(idx)
	if err != nil {
		t.Fatal(err)
	}
	if containsSession(string(data), sid) {
		t.Fatalf("index should drop %s, got: %q", sid, string(data))
	}
	if !containsSession(string(data), "session_other") {
		t.Fatalf("index should keep other session, got: %q", string(data))
	}
}

// TestDeleteSession_NotFound verifies deleting a missing session returns ErrSessionNotFound.
func TestDeleteSession_NotFound(t *testing.T) {
	home := t.TempDir()
	if err := DeleteSession(home, "session_missing"); !errors.Is(err, ErrSessionNotFound) {
		t.Fatalf("err = %v, want ErrSessionNotFound", err)
	}
}

func containsSession(idx, sid string) bool {
	return strings.Contains(idx, `"sessionId":"`+sid+`"`)
}
