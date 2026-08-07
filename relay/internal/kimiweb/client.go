// Package kimiweb 封装对 kimi-code 本地 `kimi web` 服务的会话管理调用。
//
// 背景：ACP（kimi acp）只覆盖实时对话能力（prompt/权限/流式/plan/task），
// 不暴露会话生命周期管理（archive/restore/fork/export）。这些能力由本机
// `kimi web` 服务补齐，即 docs/kimi-full-feature-plan.md 的「通道② 本机管理通道」。
//
// # 两套面，务必区分（2026-08-06 实机探针订正）
//
// ① REST `:action`（磁盘直读，本包管理方法实际使用的）：
//
//	POST {baseURL}/api/v1/sessions/{sessionID}:archive|:restore|:fork
//	POST {baseURL}/api/v1/sessions/{sessionID}/export   （返回 application/zip 二进制流）
//	响应 = { code, msg, data, request_id }；code != 0 视为 RPCError。
//
// 会话从磁盘解析，**不要求会话在 kimi web 运行时内已激活**，因此对 relay 代启的
// kimi web 可用。实测**无需 `--debug-endpoints`**（该 flag 只挂载 /api/v1/debug/*）。
//
// ② 调试 RPC（Invoke，保留作通用原语，但管理动作不再走它）：
//
//	POST {baseURL}/api/v1/debug[/{scope}]/{service}/{method}
//
// 其 `session/{sid}` scope 的解析器**只认 kimi web 运行时内已激活（WebSocket 挂载）
// 的会话**。relay 的会话活在独立的 `kimi acp` 进程里，与 relay 代启的 kimi web
// 运行时互不共享，故所有 session scope 调用必然返回 40401 session not found。
// 这就是早期实现（T2）管理功能全部失败的根因，勿再回退到该方案。
//
// # kimi 0.32.0 的能力边界
//
//	archive / restore / fork / export  -> REST :action 可用
//	rename                             -> REST /profile 可用（浏览器 UI 的「重命名」即走此端点）
//	delete                             -> 无磁盘直读方法（:delete 回 40001 unsupported
//	                                      action；DELETE 是 404 路由未找到）。本包返回 ErrUnsupported。
//
// # 单写者约束（重要）
//
// kimi 的会话存储是独占写锁：同时运行两个 `kimi web` 时，非持锁方的一切写操作
// （含 :archive/:restore/:fork 乃至建会话）都返回 50001
// "storage write failed: unrecognized I/O error"，读不受影响。
// 因此 relay 代启前必须优先复用已有实例（见 SpawnProvider.Endpoint）。
//
// 安全：默认绑定 127.0.0.1（loopback），鉴权用 Bearer token（启动横幅打印，
// 跨重启稳定）。请勿对外暴露，禁用 --dangerous-bypass-auth。详见 docs/probe/kimi-web-api.md。
package kimiweb

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 调试 RPC 的基础路径（不含 host/port）。
const debugBasePath = "/api/v1/debug"

// sessionsBasePath 是 REST 会话资源的基础路径（管理 :action 挂在其下）。
const sessionsBasePath = "/api/v1/sessions"

// ErrUnsupported 表示当前 kimi 版本没有提供该管理动作的可用接口。
// 调用方应转译为「此 kimi 版本不支持」而非当作故障重试。
var ErrUnsupported = errors.New("kimiweb: 当前 kimi 版本不支持该操作")

// CodeStorageWriteFailed 是 kimi 存储写锁被其他实例占用时返回的错误码。
// 语义：另一个 kimi web 正持有会话存储的独占写锁。
const CodeStorageWriteFailed = 50001

// CodeSessionNotFound 是会话解析失败的错误码。
const CodeSessionNotFound = 40401

// Endpoint 是 kimi web 的可达信息与鉴权凭据。
type Endpoint struct {
	// BaseURL 形如 http://127.0.0.1:58627（不含 /api/v1/debug 后缀）。
	BaseURL string
	// Token 是 Bearer token；空表示无鉴权（仅 loopback 调试可用）。
	Token string
}

// EndpointProvider 解析 kimi web 的 Endpoint。
// 实现多样：静态配置（StaticProvider）、relay 代启 kimi web 捕获 stdout（SpawnProvider）。
type EndpointProvider interface {
	Endpoint(ctx context.Context) (Endpoint, error)
}

// Envelope 是调试 RPC 的响应信封（kap-server 统一包裹）。
type Envelope struct {
	Code      int             `json:"code"`
	Msg       string          `json:"msg"`
	Data      json.RawMessage `json:"data"`
	RequestID string          `json:"request_id"`
	Details   json.RawMessage `json:"details,omitempty"`
}

// RPCError 是 code != 0 的远程调用错误。
type RPCError struct {
	Code    int
	Msg     string
	Details json.RawMessage
}

func (e *RPCError) Error() string {
	if e.Details != nil {
		return fmt.Sprintf("kimiweb rpc error code=%d msg=%q details=%s", e.Code, e.Msg, string(e.Details))
	}
	return fmt.Sprintf("kimiweb rpc error code=%d msg=%q", e.Code, e.Msg)
}

// IsRPCError 提取 *RPCError（若存在），便于调用方按 code 分支处理。
func IsRPCError(err error) (*RPCError, bool) {
	var r *RPCError
	if errors.As(err, &r) {
		return r, true
	}
	return nil, false
}

// Client 封装对 kimi web 调试 RPC 的调用。
type Client struct {
	ep EndpointProvider
	hc *http.Client
}

// New 用给定的 EndpointProvider 构造 Client。
func New(ep EndpointProvider) *Client {
	return &Client{ep: ep, hc: &http.Client{Timeout: 30 * time.Second}}
}

// NewStatic 用固定 BaseURL + Token 构造 Client（来自配置或环境变量）。
func NewStatic(baseURL, token string) *Client {
	return New(StaticProvider{BaseURL: baseURL, Token: token})
}

// Invoke 调用一个调试 RPC 方法。
//
// scopePath 是 /api/v1/debug 之后的 scope 层级（每段会被 URL 转义），例如：
//
//	""                  -> /api/v1/debug/{service}/{method}            （core / App 域）
//	"session/s1"        -> /api/v1/debug/session/s1/{service}/{method}
//	"session/s1/agent/m"-> /api/v1/debug/session/s1/agent/m/{service}/{method}
//
// args 是方法的位置参数数组，原样序列化为 JSON body；空数组则不发送 body。
// 返回信封中的 data 字段（可能是 null）。
func (c *Client) Invoke(ctx context.Context, scopePath, service, method string, args ...any) (json.RawMessage, error) {
	ep, err := c.ep.Endpoint(ctx)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: resolve endpoint: %w", err)
	}

	var b strings.Builder
	b.WriteString(strings.TrimRight(ep.BaseURL, "/"))
	b.WriteString(debugBasePath)
	for _, seg := range strings.Split(scopePath, "/") {
		if seg == "" {
			continue
		}
		b.WriteString("/")
		b.WriteString(url.PathEscape(seg))
	}
	b.WriteString("/")
	b.WriteString(url.PathEscape(service))
	b.WriteString("/")
	b.WriteString(url.PathEscape(method))
	u := b.String()

	var body io.Reader
	if len(args) > 0 {
		raw, err := json.Marshal(args)
		if err != nil {
			return nil, fmt.Errorf("kimiweb: marshal args: %w", err)
		}
		body = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, body)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: build request: %w", err)
	}
	if len(args) > 0 {
		req.Header.Set("content-type", "application/json")
	}
	if ep.Token != "" {
		req.Header.Set("authorization", "Bearer "+ep.Token)
	}

	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: do request: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: read body: %w", err)
	}

	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("kimiweb: decode envelope (http %d, body %q): %w", resp.StatusCode, string(raw), err)
	}
	if env.Code != 0 {
		return nil, &RPCError{Code: env.Code, Msg: env.Msg, Details: env.Details}
	}
	return env.Data, nil
}

// ---------------------------------------------------------------------------
// REST 会话管理原语（磁盘直读，不要求会话在 kimi web 运行时内激活）
// ---------------------------------------------------------------------------

// doSessionPost 向会话 REST 子路径发 POST，返回原始 http 响应（调用方负责 Close）。
// suffix 直接拼在 URL 转义后的 sessionID 之后，例如 ":archive" 或 "/export"。
func (c *Client) doSessionPost(ctx context.Context, sessionID, suffix string, body any) (*http.Response, error) {
	if sessionID == "" {
		return nil, fmt.Errorf("kimiweb: sessionID 为空")
	}
	ep, err := c.ep.Endpoint(ctx)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: resolve endpoint: %w", err)
	}

	u := strings.TrimRight(ep.BaseURL, "/") + sessionsBasePath + "/" + url.PathEscape(sessionID) + suffix

	var rdr io.Reader
	hasBody := body != nil
	if hasBody {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("kimiweb: marshal body: %w", err)
		}
		rdr = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, rdr)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: build request: %w", err)
	}
	if hasBody {
		req.Header.Set("content-type", "application/json")
	}
	if ep.Token != "" {
		req.Header.Set("authorization", "Bearer "+ep.Token)
	}

	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: do request: %w", err)
	}
	return resp, nil
}

// SessionInfo 是会话列表条目。
//
// 相比 ACP 的 ListSessions，kimi web 的列表额外带 archived 标志，
// 这是 ACP 侧缺失的字段（gap #1）。
type SessionInfo struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Archived    bool   `json:"archived"`
	WorkspaceID string `json:"workspace_id"`
}

// ListSessions 列出磁盘上的会话：GET /api/v1/sessions。
// 该端点是只读的，不受单写者写锁影响。
func (c *Client) ListSessions(ctx context.Context) ([]SessionInfo, error) {
	ep, err := c.ep.Endpoint(ctx)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: resolve endpoint: %w", err)
	}
	u := strings.TrimRight(ep.BaseURL, "/") + sessionsBasePath
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: build request: %w", err)
	}
	if ep.Token != "" {
		req.Header.Set("authorization", "Bearer "+ep.Token)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: do request: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: read body: %w", err)
	}
	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("kimiweb: decode envelope (http %d, body %q): %w", resp.StatusCode, truncate(raw, 300), err)
	}
	if env.Code != 0 {
		return nil, &RPCError{Code: env.Code, Msg: env.Msg, Details: env.Details}
	}
	// 实测形状：data.items[]
	var payload struct {
		Items []SessionInfo `json:"items"`
	}
	if err := json.Unmarshal(env.Data, &payload); err != nil {
		return nil, fmt.Errorf("kimiweb: decode session list: %w", err)
	}
	return payload.Items, nil
}

// sessionAction 调用 REST 冒号动作 `POST /api/v1/sessions/{id}:{action}`，
// 解析统一信封并返回 data。body 为 nil 时不发送请求体。
//
// 实测响应：
//
//	:archive -> data {"archived": true}
//	:restore -> data <完整 session 对象>（archived 翻回 false）
//	:fork    -> data <新 session 完整对象>，新 ID 在 data.id
func (c *Client) sessionAction(ctx context.Context, sessionID, action string, body any) (json.RawMessage, error) {
	resp, err := c.doSessionPost(ctx, sessionID, ":"+action, body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: read body: %w", err)
	}
	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("kimiweb: decode envelope (http %d, body %q): %w", resp.StatusCode, truncate(raw, 300), err)
	}
	if env.Code != 0 {
		return nil, &RPCError{Code: env.Code, Msg: env.Msg, Details: env.Details}
	}
	return env.Data, nil
}

// truncate 截断响应体用于错误信息，避免把整包内容塞进日志。
func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "…"
}

// ---------------------------------------------------------------------------
// 类型化封装（便捷方法）
// ---------------------------------------------------------------------------

// Archive 归档会话：POST /api/v1/sessions/{id}:archive。
// 实测响应 data = {"archived": true}。
func (c *Client) Archive(ctx context.Context, sessionID string) error {
	_, err := c.sessionAction(ctx, sessionID, "archive", nil)
	return err
}

// RestoreOpts 是 restore 的可选参数。kimi 0.32.0 的 REST `:restore` 不接受额外参数，
// 保留该类型是为了不破坏调用方签名；非空字段当前会被忽略。
type RestoreOpts struct {
	AdditionalDirs []string       `json:"additionalDirs,omitempty"`
	McpServers     map[string]any `json:"mcpServers,omitempty"`
}

// Restore 取消归档：POST /api/v1/sessions/{id}:restore。
// 实测响应 data = 完整 session 对象（archived 翻回 false）。
func (c *Client) Restore(ctx context.Context, sessionID string, _ *RestoreOpts) error {
	_, err := c.sessionAction(ctx, sessionID, "restore", nil)
	return err
}

// Delete 删除会话。
//
// kimi 0.32.0 没有磁盘直读的删除接口：`:delete` 返回 40001 unsupported action，
// `DELETE /api/v1/sessions/{id}` 是 404 路由未找到。唯一的 sessionLifecycle/delete
// 调试 RPC 要求会话已加载进 kimi web 运行时，对 relay 代启的实例不可用。
func (c *Client) Delete(ctx context.Context, sessionID string) error {
	return fmt.Errorf("%w：删除会话（kimi 未提供磁盘直读的删除接口）", ErrUnsupported)
}

// ForkOpts 是 fork 的参数。
type ForkOpts struct {
	SourceSessionID string         `json:"-"`
	NewSessionID    string         `json:"newSessionId,omitempty"`
	Title           string         `json:"title,omitempty"`
	Metadata        map[string]any `json:"metadata,omitempty"`
}

// Fork 分叉会话：POST /api/v1/sessions/{id}:fork，返回新会话 ID。
// 实测响应 data = 新 session 的完整对象，新 ID 在 data.id。
// 若返回 ("", nil) 表示调用成功但响应中无法解析出 ID（调用方应自行刷新列表）。
func (c *Client) Fork(ctx context.Context, opts ForkOpts) (string, error) {
	var body any
	if opts.NewSessionID != "" || opts.Title != "" || len(opts.Metadata) > 0 {
		body = opts
	}
	data, err := c.sessionAction(ctx, opts.SourceSessionID, "fork", body)
	if err != nil {
		return "", err
	}
	var res struct {
		ID        string `json:"id"`
		SessionID string `json:"sessionId"`
	}
	if err := json.Unmarshal(data, &res); err != nil {
		return "", fmt.Errorf("kimiweb: decode fork result: %w", err)
	}
	if res.ID != "" {
		return res.ID, nil
	}
	return res.SessionID, nil
}

// Rename 重命名会话：POST /api/v1/sessions/{id}/profile，body {"title": newTitle}。
//
// 实测（kimi 0.32.0，探针 _rename_shape_probe.py，对真实运行实例验证）确认：浏览器 UI 的
// 「重命名」走的就是这个端点；`:rename` 返回 40001 unsupported action、PATCH 是 404，
// 唯独 /profile 可用，且同样是磁盘直读、不要求会话在 kimi web 运行时已激活，对 relay
// 代启实例可用。
func (c *Client) Rename(ctx context.Context, sessionID, title string) error {
	resp, err := c.doSessionPost(ctx, sessionID, "/profile", map[string]any{"title": title})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("kimiweb: read body: %w", err)
	}
	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return fmt.Errorf("kimiweb: decode envelope (http %d, body %q): %w", resp.StatusCode, truncate(raw, 300), err)
	}
	if env.Code != 0 {
		return &RPCError{Code: env.Code, Msg: env.Msg, Details: env.Details}
	}
	return nil
}

// ShellEnv 对应导出 payload 的 shellEnv（仅诊断信息，可空）。
type ShellEnv struct {
	Term               string `json:"term,omitempty"`
	TermProgram        string `json:"termProgram,omitempty"`
	TermProgramVersion string `json:"termProgramVersion,omitempty"`
	Multiplexer        string `json:"multiplexer,omitempty"`
	Shell              string `json:"shell,omitempty"`
}

// ExportOpts 是 export 的参数。
//
// 注意：kimi 0.32.0 的 `POST /api/v1/sessions/{id}/export` 直接返回 zip 二进制流，
// 不接受 version/shellEnv 等 payload，也不返回落盘路径。OutputPath 由本包决定
// 把流写到哪里；其余字段保留仅为兼容既有调用方签名，当前不参与请求。
type ExportOpts struct {
	// OutputPath 指定 zip 落盘路径；为空则写入 os.TempDir()/sentinel-export/。
	// 若指向已存在的目录，则在该目录下按 kimi 建议的文件名落盘。
	OutputPath string

	// 以下字段在 0.32.0 的 REST export 中无对应参数，保留以兼容调用方。
	Version           string
	IncludeGlobalLog  bool
	IncludeDesktopLog bool
	DesktopVersion    string
	InstallSource     string
	ShellEnv          *ShellEnv
	MaxArchiveBytes   int
	WebLog            string
}

// ExportResult 是 export 的返回。ZipPath 是 relay 落盘后的本地绝对路径
// （kimi 只回二进制流，路径由本包生成）。
type ExportResult struct {
	ZipPath    string          `json:"zipPath"`
	SizeBytes  int64           `json:"sizeBytes"`
	SessionDir string          `json:"sessionDir,omitempty"`
	Entries    []string        `json:"entries,omitempty"`
	Manifest   json.RawMessage `json:"manifest,omitempty"`
}

// Export 导出会话为 zip：POST /api/v1/sessions/{id}/export。
//
// 实测该端点**仅支持 POST**（GET 返回 404），且**请求体必须是 JSON 对象**
// （哪怕是空对象 `{}`）。发 nil body 时 kimi 报
// `code=40001 expected object, received undefined`，故此处显式传 `map[string]any{}`。
// 成功响应是 Content-Type: application/zip 的二进制流，带
// Content-Disposition: attachment; filename="kimi-session-{sid}.zip"。
// 失败时才返回 JSON 信封。本方法负责把流落盘并回传本地路径。
func (c *Client) Export(ctx context.Context, sessionID string, opts ExportOpts) (*ExportResult, error) {
	// 必须发送一个空 JSON 对象而非 nil（探针 export_body_probe.py 验证）。
	resp, err := c.doSessionPost(ctx, sessionID, "/export", map[string]any{})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// 失败路径：kimi 会回 JSON 信封而非 zip。
	ctype := resp.Header.Get("content-type")
	if strings.Contains(ctype, "application/json") {
		raw, _ := io.ReadAll(resp.Body)
		var env Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			return nil, fmt.Errorf("kimiweb: export 失败 (http %d, body %q)", resp.StatusCode, truncate(raw, 300))
		}
		if env.Code != 0 {
			return nil, &RPCError{Code: env.Code, Msg: env.Msg, Details: env.Details}
		}
		return nil, fmt.Errorf("kimiweb: export 返回 JSON 而非 zip 流: %s", truncate(raw, 300))
	}
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("kimiweb: export http %d: %s", resp.StatusCode, truncate(raw, 300))
	}

	dst, err := exportDestPath(opts.OutputPath, sessionID, resp.Header.Get("content-disposition"))
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return nil, fmt.Errorf("kimiweb: 创建导出目录: %w", err)
	}
	f, err := os.Create(dst)
	if err != nil {
		return nil, fmt.Errorf("kimiweb: 创建导出文件: %w", err)
	}
	n, err := io.Copy(f, resp.Body)
	cerr := f.Close()
	if err != nil {
		_ = os.Remove(dst)
		return nil, fmt.Errorf("kimiweb: 写入导出文件: %w", err)
	}
	if cerr != nil {
		return nil, fmt.Errorf("kimiweb: 关闭导出文件: %w", cerr)
	}
	return &ExportResult{ZipPath: dst, SizeBytes: n}, nil
}

// exportDestPath 计算 zip 落盘路径。
// outputPath 为空 -> os.TempDir()/sentinel-export/{filename}；
// outputPath 是已存在目录 -> 该目录下 {filename}；否则原样作为文件路径。
func exportDestPath(outputPath, sessionID, contentDisposition string) (string, error) {
	name := filenameFromDisposition(contentDisposition)
	if name == "" {
		name = "kimi-session-" + sessionID + ".zip"
	}
	if outputPath == "" {
		return filepath.Join(os.TempDir(), "sentinel-export", name), nil
	}
	if st, err := os.Stat(outputPath); err == nil && st.IsDir() {
		return filepath.Join(outputPath, name), nil
	}
	abs, err := filepath.Abs(outputPath)
	if err != nil {
		return "", fmt.Errorf("kimiweb: 解析导出路径 %q: %w", outputPath, err)
	}
	return abs, nil
}

// filenameFromDisposition 从 Content-Disposition 提取 filename，并剥掉任何路径成分，
// 防止服务端返回的名字逃逸出目标目录。
func filenameFromDisposition(v string) string {
	idx := strings.Index(strings.ToLower(v), "filename=")
	if idx < 0 {
		return ""
	}
	name := strings.TrimSpace(v[idx+len("filename="):])
	if i := strings.Index(name, ";"); i >= 0 {
		name = name[:i]
	}
	name = strings.Trim(strings.TrimSpace(name), `"'`)
	name = filepath.Base(filepath.FromSlash(name))
	if name == "." || name == string(filepath.Separator) || name == ".." {
		return ""
	}
	return name
}
