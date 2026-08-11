package kimiweb

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

// 以下管理动作走 REST :action（磁盘直读），不是调试 RPC。
// 回归意图：任何人把实现改回 /api/v1/debug/session/{sid}/... 都会在这里失败——
// 那条路对 relay 代启的 kimi web 必然 40401（会话未加载进其运行时）。

func TestArchive_UsesRESTAction(t *testing.T) {
	srv := newFakeServer()
	srv.respData = `{"archived":true}`
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	if err := c.Archive(context.Background(), "session_x"); err != nil {
		t.Fatalf("Archive: %v", err)
	}
	req, body := srv.snapshot()
	if want := "/api/v1/sessions/session_x:archive"; req.URL.Path != want {
		t.Fatalf("path = %q, want %q", req.URL.Path, want)
	}
	if req.Method != http.MethodPost {
		t.Fatalf("method = %q, want POST", req.Method)
	}
	if body != "" {
		t.Fatalf("body = %q, want empty", body)
	}
	if got := req.Header.Get("authorization"); got != "Bearer tok-123" {
		t.Fatalf("authorization = %q", got)
	}
}

func TestRestore_UsesRESTAction(t *testing.T) {
	srv := newFakeServer()
	srv.respData = `{"id":"session_x","archived":false}`
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	// opts 在 0.32.0 的 REST :restore 中无对应参数，传与不传都不应改变请求。
	for _, opts := range []*RestoreOpts{nil, {AdditionalDirs: []string{"/tmp"}}} {
		if err := c.Restore(context.Background(), "session_x", opts); err != nil {
			t.Fatalf("Restore(%v): %v", opts, err)
		}
		req, body := srv.snapshot()
		if want := "/api/v1/sessions/session_x:restore"; req.URL.Path != want {
			t.Fatalf("path = %q, want %q", req.URL.Path, want)
		}
		if body != "" {
			t.Fatalf("body = %q, want empty", body)
		}
	}
}

func TestFork_UsesRESTActionAndReadsDataID(t *testing.T) {
	srv := newFakeServer()
	// 实测 :fork 返回新 session 的完整对象，新 ID 在 data.id。
	srv.respData = `{"id":"session_new","title":"Forked","archived":false}`
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
	if want := "/api/v1/sessions/session_src:fork"; req.URL.Path != want {
		t.Fatalf("path = %q, want %q", req.URL.Path, want)
	}
	// SourceSessionID 只进 URL，不应出现在 body 里。
	if want := `{"title":"Forked"}`; body != want {
		t.Fatalf("body = %q, want %q", body, want)
	}
}

func TestFork_NoOptsSendsNoBody(t *testing.T) {
	srv := newFakeServer()
	srv.respData = `{"id":"session_new"}`
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	if _, err := c.Fork(context.Background(), ForkOpts{SourceSessionID: "session_src"}); err != nil {
		t.Fatalf("Fork: %v", err)
	}
	req, body := srv.snapshot()
	if body != "" {
		t.Fatalf("body = %q, want empty", body)
	}
	if ct := req.Header.Get("content-type"); ct != "" {
		t.Fatalf("content-type = %q, want empty", ct)
	}
}

// TestRename_UsesRESTProfile 锁定重命名走 POST /profile（而非不受支持的 :rename）：
// 浏览器 UI 的「重命名」即此端点，body 为 {"title": newTitle}。
func TestRename_UsesRESTProfile(t *testing.T) {
	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	if err := c.Rename(context.Background(), "session_x", "新标题"); err != nil {
		t.Fatalf("Rename: %v", err)
	}
	req, body := srv.snapshot()
	if req == nil {
		t.Fatal("Rename 未发出请求")
	}
	if want := "/api/v1/sessions/session_x/profile"; req.URL.Path != want {
		t.Fatalf("path = %q, want %q", req.URL.Path, want)
	}
	if req.Method != http.MethodPost {
		t.Fatalf("method = %q, want POST", req.Method)
	}
	if req.Header.Get("content-type") != "application/json" {
		t.Fatalf("content-type = %q, want application/json", req.Header.Get("content-type"))
	}
	var got struct {
		Title string `json:"title"`
	}
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatalf("decode body %q: %v", body, err)
	}
	if got.Title != "新标题" {
		t.Fatalf("body title = %q, want 新标题", got.Title)
	}
}

// TestDelete_DirectStorage 验证：Delete 走 replay.DeleteSession 直接删存储，
// 不发出任何 HTTP 请求。用独立临时 KIMI_CODE_HOME 隔离，避免触碰真实数据。
func TestDelete_DirectStorage(t *testing.T) {
	home := t.TempDir()
	t.Setenv("KIMI_CODE_HOME", home)

	sid := "session_abc"
	sessionDir := filepath.Join(home, "sessions", "wd_test", sid)
	if err := os.MkdirAll(filepath.Join(sessionDir, "agents", "main"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sessionDir, "state.json"), []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	idx := filepath.Join(home, "session_index.jsonl")
	if err := os.WriteFile(idx, []byte(`{"sessionId":"session_other","sessionDir":"x"}`+"\n"+
		`{"sessionId":"`+sid+`","sessionDir":"`+sessionDir+`"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	srv := newFakeServer()
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	if err := c.Delete(context.Background(), sid); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := os.Stat(sessionDir); !os.IsNotExist(err) {
		t.Fatalf("会话目录应已删除")
	}
	if req, _ := srv.snapshot(); req != nil {
		t.Fatalf("删除不应发出 HTTP 请求，却命中了 %s", req.URL.Path)
	}
}

// zipServer 回放一个 application/zip 二进制流，模拟真实的 /export。
func zipServer(payload []byte, disposition string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/zip")
		if disposition != "" {
			w.Header().Set("content-disposition", disposition)
		}
		_, _ = w.Write(payload)
	}))
}

func TestExport_WritesZipStreamToDisk(t *testing.T) {
	payload := []byte("PK\x03\x04fake-zip-body")
	ts := zipServer(payload, `attachment; filename="kimi-session-session_x.zip"`)
	defer ts.Close()
	c := staticClient(ts.URL)

	dir := t.TempDir()
	res, err := c.Export(context.Background(), "session_x", ExportOpts{OutputPath: dir})
	if err != nil {
		t.Fatalf("Export: %v", err)
	}
	want := filepath.Join(dir, "kimi-session-session_x.zip")
	if res.ZipPath != want {
		t.Fatalf("ZipPath = %q, want %q", res.ZipPath, want)
	}
	if res.SizeBytes != int64(len(payload)) {
		t.Fatalf("SizeBytes = %d, want %d", res.SizeBytes, len(payload))
	}
	got, err := os.ReadFile(res.ZipPath)
	if err != nil {
		t.Fatalf("读取导出文件: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("落盘内容 = %q, want %q", got, payload)
	}
}

func TestExport_UsesPOSTOnExportPath(t *testing.T) {
	var gotPath, gotMethod, gotBody, gotCT string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotPath, gotMethod, gotBody, gotCT = r.URL.Path, r.Method, string(b), r.Header.Get("content-type")
		w.Header().Set("content-type", "application/zip")
		_, _ = w.Write([]byte("PK"))
	}))
	defer ts.Close()

	c := staticClient(ts.URL)
	if _, err := c.Export(context.Background(), "session_x", ExportOpts{OutputPath: t.TempDir()}); err != nil {
		t.Fatalf("Export: %v", err)
	}
	if want := "/api/v1/sessions/session_x/export"; gotPath != want {
		t.Fatalf("path = %q, want %q", gotPath, want)
	}
	// 实测 GET 是 404，必须 POST。
	if gotMethod != http.MethodPost {
		t.Fatalf("method = %q, want POST", gotMethod)
	}
	// 探针 export_body_probe.py 验证：kimi 要求请求体是 JSON 对象（哪怕是空对象）。
	// 发 nil 会报 code=40001 "expected object, received undefined"。
	if gotBody != "{}" {
		t.Fatalf("body = %q, want {}", gotBody)
	}
	if gotCT != "application/json" {
		t.Fatalf("content-type = %q, want application/json", gotCT)
	}
}

func TestExport_JSONEnvelopeIsError(t *testing.T) {
	srv := newFakeServer()
	srv.respCode = CodeStorageWriteFailed
	ts := httptest.NewServer(srv.handler())
	defer ts.Close()
	c := staticClient(ts.URL)

	_, err := c.Export(context.Background(), "session_x", ExportOpts{OutputPath: t.TempDir()})
	if err == nil {
		t.Fatal("期望错误，得到 nil")
	}
	re, ok := IsRPCError(err)
	if !ok {
		t.Fatalf("err %v 不是 *RPCError", err)
	}
	if re.Code != CodeStorageWriteFailed {
		t.Fatalf("code = %d, want %d", re.Code, CodeStorageWriteFailed)
	}
}

// TestExport_DispositionPathTraversal 确保服务端返回的文件名无法逃逸出目标目录。
func TestExport_DispositionPathTraversal(t *testing.T) {
	ts := zipServer([]byte("PK"), `attachment; filename="../../evil.zip"`)
	defer ts.Close()
	c := staticClient(ts.URL)

	dir := t.TempDir()
	res, err := c.Export(context.Background(), "session_x", ExportOpts{OutputPath: dir})
	if err != nil {
		t.Fatalf("Export: %v", err)
	}
	if got := filepath.Dir(res.ZipPath); got != dir {
		t.Fatalf("落盘目录 = %q, 逃逸出了 %q", got, dir)
	}
	if got := filepath.Base(res.ZipPath); got != "evil.zip" {
		t.Fatalf("文件名 = %q, want evil.zip", got)
	}
}

func TestFilenameFromDisposition(t *testing.T) {
	cases := []struct{ in, want string }{
		{`attachment; filename="kimi-session-s1.zip"`, "kimi-session-s1.zip"},
		{`attachment; filename=plain.zip`, "plain.zip"},
		{`attachment; filename="a.zip"; charset=utf-8`, "a.zip"},
		{`attachment; filename="../../etc/passwd"`, "passwd"},
		{`attachment`, ""},
		{``, ""},
	}
	for _, tc := range cases {
		if got := filenameFromDisposition(tc.in); got != tc.want {
			t.Errorf("filenameFromDisposition(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestExportDestPath_DefaultsToTempDir(t *testing.T) {
	got, err := exportDestPath("", "session_x", "")
	if err != nil {
		t.Fatalf("exportDestPath: %v", err)
	}
	want := filepath.Join(os.TempDir(), "sentinel-export", "kimi-session-session_x.zip")
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
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
