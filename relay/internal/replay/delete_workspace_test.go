package replay

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDeleteWorkspace verifies deleting a workspace directly from storage:
// the workspace directory (sessions/<wdID>) is removed, all index entries
// whose workDir matches are dropped, and other workspaces are untouched.
func TestDeleteWorkspace(t *testing.T) {
	home := t.TempDir()
	wdA := "C:/work/projA"
	wdB := "C:/work/projB"
	s1 := filepath.Join(home, "sessions", "wd_a", "session_s1")
	s2 := filepath.Join(home, "sessions", "wd_a", "session_s2")
	s3 := filepath.Join(home, "sessions", "wd_b", "session_s3")
	for _, d := range []string{s1, s2, s3} {
		if err := os.MkdirAll(filepath.Join(d, "agents", "main"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "state.json"), []byte(`{"title":"t"}`), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	idx := filepath.Join(home, "session_index.jsonl")
	type idxRec struct {
		SessionID  string `json:"sessionId"`
		SessionDir string `json:"sessionDir"`
		WorkDir    string `json:"workDir"`
	}
	recs := []idxRec{
		{SessionID: "session_s1", SessionDir: s1, WorkDir: wdA},
		{SessionID: "session_s2", SessionDir: s2, WorkDir: wdA},
		{SessionID: "session_s3", SessionDir: s3, WorkDir: wdB},
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

	if err := DeleteWorkspace(home, wdA); err != nil {
		t.Fatalf("DeleteWorkspace: %v", err)
	}
	// workspace A directory removed entirely
	if _, err := os.Stat(filepath.Join(home, "sessions", "wd_a")); !os.IsNotExist(err) {
		t.Fatalf("workspace A dir should be removed")
	}
	// workspace B untouched
	if _, err := os.Stat(s3); err != nil {
		t.Fatalf("workspace B session should remain: %v", err)
	}
	data, err := os.ReadFile(idx)
	if err != nil {
		t.Fatal(err)
	}
	if containsSession(string(data), "session_s1") || containsSession(string(data), "session_s2") {
		t.Fatalf("index should drop workspace A sessions, got: %q", string(data))
	}
	if !containsSession(string(data), "session_s3") {
		t.Fatalf("index should keep workspace B session, got: %q", string(data))
	}
}

// TestDeleteWorkspace_NotFound verifies deleting a missing workspace returns ErrWorkspaceNotFound.
func TestDeleteWorkspace_NotFound(t *testing.T) {
	home := t.TempDir()
	if err := DeleteWorkspace(home, "C:/work/missing"); !errors.Is(err, ErrWorkspaceNotFound) {
		t.Fatalf("err = %v, want ErrWorkspaceNotFound", err)
	}
}
