package kimiweb

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeServer 记录最近一次请求并回放一个固定信封，便于断言信封构造。
type fakeServer struct {
	mu       sync.Mutex
	lastReq  *http.Request
	lastBody string
	// respCode / respData 控制回放的信封。
	respCode int
	respData string
	// respRaw 若非空则原样返回（绕过 code/data 包装）。
	respRaw string
}

func newFakeServer() *fakeServer {
	return &fakeServer{respCode: 0, respData: "null"}
}

func (f *fakeServer) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		f.mu.Lock()
		f.lastReq = r
		f.lastBody = string(body)
		f.mu.Unlock()

		w.Header().Set("content-type", "application/json")
		if f.respRaw != "" {
			_, _ = w.Write([]byte(f.respRaw))
			return
		}
		_ = json.NewEncoder(w).Encode(Envelope{
			Code:      f.respCode,
			Msg:       "ok",
			Data:      json.RawMessage(f.respData),
			RequestID: "req-1",
		})
	}
}

func (f *fakeServer) snapshot() (*http.Request, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.lastReq, f.lastBody
}

func staticClient(base string) *Client {
	return NewStatic(base, "tok-123")
}

func TestInvoke_BuildsURLAndBody(t *testing.T) {
	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	data, err := c.Invoke(context.Background(), "session/s1", "sessionLifecycle", "archive", "s1")
	if err != nil {
		t.Fatalf("Invoke: %v", err)
	}
	if string(data) != "null" {
		t.Fatalf("data = %s, want null", data)
	}
	req, body := srv.snapshot()
	wantPath := "/api/v1/debug/session/s1/sessionLifecycle/archive"
	if req.URL.Path != wantPath {
		t.Fatalf("path = %q, want %q", req.URL.Path, wantPath)
	}
	if req.Method != http.MethodPost {
		t.Fatalf("method = %q, want POST", req.Method)
	}
	if got := req.Header.Get("authorization"); got != "Bearer tok-123" {
		t.Fatalf("authorization = %q, want Bearer tok-123", got)
	}
	if ct := req.Header.Get("content-type"); ct != "application/json" {
		t.Fatalf("content-type = %q, want application/json", ct)
	}
	if body != `["s1"]` {
		t.Fatalf("body = %q, want [\"s1\"]", body)
	}
}

func TestInvoke_EmptyArgsNoBody(t *testing.T) {
	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	if _, err := c.Invoke(context.Background(), "", "sessionExport", "export"); err != nil {
		t.Fatalf("Invoke: %v", err)
	}
	req, body := srv.snapshot()
	if req.URL.Path != "/api/v1/debug/sessionExport/export" {
		t.Fatalf("path = %q", req.URL.Path)
	}
	if ct := req.Header.Get("content-type"); ct != "" {
		t.Fatalf("content-type = %q, want empty", ct)
	}
	if body != "" {
		t.Fatalf("body = %q, want empty", body)
	}
}

func TestInvoke_RPCError(t *testing.T) {
	srv := newFakeServer()
	srv.respCode = 7
	srv.respData = "null"
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	_, err := c.Invoke(context.Background(), "session/s1", "sessionLifecycle", "delete", "s1")
	if err == nil {
		t.Fatal("expected RPCError, got nil")
	}
	re, ok := IsRPCError(err)
	if !ok {
		t.Fatalf("err %v is not *RPCError", err)
	}
	if re.Code != 7 {
		t.Fatalf("code = %d, want 7", re.Code)
	}
}

func TestInvoke_AgentScope(t *testing.T) {
	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	if _, err := c.Invoke(context.Background(), "session/s1/agent/main", "agentRPC", "cancel", map[string]any{}); err != nil {
		t.Fatalf("Invoke: %v", err)
	}
	req, _ := srv.snapshot()
	if req.URL.Path != "/api/v1/debug/session/s1/agent/main/agentRPC/cancel" {
		t.Fatalf("path = %q", req.URL.Path)
	}
}

func TestArchive(t *testing.T) {
	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)
	if err := c.Archive(context.Background(), "session_x"); err != nil {
		t.Fatalf("Archive: %v", err)
	}
	req, body := srv.snapshot()
	if req.URL.Path != "/api/v1/debug/session/session_x/sessionLifecycle/archive" {
		t.Fatalf("path = %q", req.URL.Path)
	}
	if body != `["session_x"]` {
		t.Fatalf("body = %q", body)
	}
}

func TestRestore(t *testing.T) {
	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	if err := c.Restore(context.Background(), "session_x", nil); err != nil {
		t.Fatalf("Restore(nil): %v", err)
	}
	_, body := srv.snapshot()
	if body != `["session_x"]` {
		t.Fatalf("body(nil opts) = %q, want [\"session_x\"]", body)
	}

	if err := c.Restore(context.Background(), "session_x", &RestoreOpts{AdditionalDirs: []string{"/tmp"}}); err != nil {
		t.Fatalf("Restore(opts): %v", err)
	}
	_, body = srv.snapshot()
	want := `["session_x",{"additionalDirs":["/tmp"]}]`
	if body != want {
		t.Fatalf("body(opts) = %q, want %q", body, want)
	}
}

func TestDelete(t *testing.T) {
	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)
	if err := c.Delete(context.Background(), "session_x"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	req, body := srv.snapshot()
	if req.URL.Path != "/api/v1/debug/session/session_x/sessionLifecycle/delete" {
		t.Fatalf("path = %q", req.URL.Path)
	}
	if body != `["session_x"]` {
		t.Fatalf("body = %q", body)
	}
}

func TestFork(t *testing.T) {
	srv := newFakeServer()
	srv.respData = `{"sessionId":"session_new","id":"session_new"}`
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	newID, err := c.Fork(context.Background(), ForkOpts{SourceSessionID: "session_src", Title: "Forked"})
	if err != nil {
		t.Fatalf("Fork: %v", err)
	}
	if newID != "session_new" {
		t.Fatalf("newID = %q, want session_new", newID)
	}
	req, body := srv.snapshot()
	if req.URL.Path != "/api/v1/debug/session/session_src/sessionLifecycle/fork" {
		t.Fatalf("path = %q", req.URL.Path)
	}
	want := `[{"sourceSessionId":"session_src","title":"Forked"}]`
	if body != want {
		t.Fatalf("body = %q, want %q", body, want)
	}
}

func TestRename(t *testing.T) {
	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)
	if err := c.Rename(context.Background(), "session_x", "新标题"); err != nil {
		t.Fatalf("Rename: %v", err)
	}
	req, body := srv.snapshot()
	if req.URL.Path != "/api/v1/debug/session/session_x/sessionMetadata/setTitle" {
		t.Fatalf("path = %q", req.URL.Path)
	}
	if body != `["新标题"]` {
		t.Fatalf("body = %q", body)
	}
}

func TestExport(t *testing.T) {
	srv := newFakeServer()
	srv.respData = `{"zipPath":"/tmp/k.zip","sessionDir":"/home/s","entries":["a","b"]}`
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	res, err := c.Export(context.Background(), "session_x", ExportOpts{
		Version:          "0.32.0",
		IncludeGlobalLog: true,
	})
	if err != nil {
		t.Fatalf("Export: %v", err)
	}
	if res.ZipPath != "/tmp/k.zip" {
		t.Fatalf("zipPath = %q", res.ZipPath)
	}
	req, body := srv.snapshot()
	if req.URL.Path != "/api/v1/debug/sessionExport/export" {
		t.Fatalf("path = %q (core scope)", req.URL.Path)
	}
	// 校验 input 含 sessionId/version/includeGlobalLog，options 为空对象
	var arr []map[string]any
	if err := json.Unmarshal([]byte(body), &arr); err != nil {
		t.Fatalf("body not array: %v", err)
	}
	if len(arr) != 2 {
		t.Fatalf("args len = %d, want 2", len(arr))
	}
	input := arr[0]
	if input["sessionId"] != "session_x" || input["version"] != "0.32.0" || input["includeGlobalLog"] != true {
		t.Fatalf("input = %v", input)
	}
	opts := arr[1]
	if len(opts) != 0 {
		t.Fatalf("options = %v, want empty", opts)
	}
}

func TestExport_RequiresVersion(t *testing.T) {
	c := staticClient("http://example.invalid")
	if _, err := c.Export(context.Background(), "s", ExportOpts{}); err == nil {
		t.Fatal("expected error for missing Version")
	}
}

func TestStaticProvider(t *testing.T) {
	p := StaticProvider{BaseURL: "http://127.0.0.1:58627", Token: "abc"}
	ep, err := p.Endpoint(context.Background())
	if err != nil {
		t.Fatalf("Endpoint: %v", err)
	}
	if ep.BaseURL != "http://127.0.0.1:58627" || ep.Token != "abc" {
		t.Fatalf("ep = %+v", ep)
	}
	empty := StaticProvider{}
	if _, err := empty.Endpoint(context.Background()); err == nil {
		t.Fatal("expected error for empty BaseURL")
	}
}

func TestParseBanner(t *testing.T) {
	cases := []struct {
		name  string
		line  string
		base  string
		token string
		ok    bool
	}{
		{
			name:  "standard",
			line:  "Kimi server: http://127.0.0.1:58627/#token=m2A48i3rabRy",
			base:  "http://127.0.0.1:58627",
			token: "m2A48i3rabRy",
			ok:    true,
		},
		{
			name:  "with trailing spaces",
			line:  "Kimi server: http://127.0.0.1:58628/#token=abcd   ",
			base:  "http://127.0.0.1:58628",
			token: "abcd",
			ok:    true,
		},
		{
			name: "no token",
			line: "Kimi server: http://127.0.0.1:58627/",
			ok:   false,
		},
		{
			name: "unrelated",
			line: "loading modules...",
			ok:   false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ep, ok := parseBanner(tc.line)
			if ok != tc.ok {
				t.Fatalf("ok = %v, want %v", ok, tc.ok)
			}
			if !tc.ok {
				return
			}
			if ep.BaseURL != tc.base || ep.Token != tc.token {
				t.Fatalf("ep = %+v, want base=%q token=%q", ep, tc.base, tc.token)
			}
			if strings.Contains(ep.Token, " ") {
				t.Fatalf("token has trailing space: %q", ep.Token)
			}
		})
	}
}
