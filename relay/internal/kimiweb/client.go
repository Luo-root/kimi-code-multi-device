// Package kimiweb 封装对 kimi-code 本地 `kimi web` 服务 HTTP 调试 RPC 的调用。
//
// 背景：ACP（kimi acp）只覆盖实时对话能力（prompt/权限/流式/plan/task），
// 不暴露会话生命周期管理（archive/fork/delete/restore/rename/export）。
// kimi 在终端/TUI 中提供的这些操作，实际通过 `kimi web` 的调试 RPC 完成：
//
//	POST {baseURL}/api/v1/debug[/{scope}]/{service}/{method}
//	body = JSON 参数数组（args 为空则不带 body）
//	响应 = { code, msg, data, request_id }；code != 0 视为 RPCError。
//
// 本包把该信封封装为类型安全的 Go API，供 relay 在 ACP 之外补齐管理缺口
// （即 docs/kimi-full-feature-plan.md 的「通道② 本机管理通道」）。
//
// 该调试面需 `kimi web --debug-endpoints` 启动；默认绑定 127.0.0.1（loopback），
// 鉴权用 Bearer token（启动横幅打印，跨重启稳定）。请勿对外暴露该调试面。
// 详见 docs/probe/kimi-web-api.md。
//
// 设计要点（可拓展性）：
//   - 底层 Invoke 是通用原语，新增任意 service/method 无需改接口；
//   - 类型化封装（Archive/Rename/...）只是 Invoke 的便捷包装；
//   - EndpointProvider 抽象端点来源：静态配置（StaticProvider）或 relay 代启
//     kimi web 捕获 stdout 横幅（SpawnProvider），后续可加「探测运行中实例」等。
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
	"strings"
	"time"
)

// 调试 RPC 的基础路径（不含 host/port）。
const debugBasePath = "/api/v1/debug"

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
// 类型化封装（便捷方法）
// ---------------------------------------------------------------------------

// Archive 归档会话（sessionLifecycle.archive）。
func (c *Client) Archive(ctx context.Context, sessionID string) error {
	_, err := c.Invoke(ctx, scopeSession(sessionID), "sessionLifecycle", "archive", sessionID)
	return err
}

// RestoreOpts 是 restore 的可选参数（对应 ResumeSessionOptions 的调试 RPC 子集）。
type RestoreOpts struct {
	AdditionalDirs []string       `json:"additionalDirs,omitempty"`
	McpServers     map[string]any `json:"mcpServers,omitempty"`
}

// Restore 取消归档并恢复（sessionLifecycle.restore）。
func (c *Client) Restore(ctx context.Context, sessionID string, opts *RestoreOpts) error {
	args := []any{sessionID}
	if opts != nil {
		args = append(args, opts)
	}
	_, err := c.Invoke(ctx, scopeSession(sessionID), "sessionLifecycle", "restore", args...)
	return err
}

// Delete 删除会话目录（sessionLifecycle.delete）。
func (c *Client) Delete(ctx context.Context, sessionID string) error {
	_, err := c.Invoke(ctx, scopeSession(sessionID), "sessionLifecycle", "delete", sessionID)
	return err
}

// ForkOpts 是 fork 的参数（对应 ForkSessionOptions）。
type ForkOpts struct {
	SourceSessionID string         `json:"sourceSessionId"`
	NewSessionID    string         `json:"newSessionId,omitempty"`
	Title           string         `json:"title,omitempty"`
	Metadata        map[string]any `json:"metadata,omitempty"`
}

// Fork 分叉会话，返回新会话 ID（sessionLifecycle.fork）。
// 若返回 ("", nil) 表示调用成功但响应中无法解析出 sessionId（调用方应自行刷新列表）。
func (c *Client) Fork(ctx context.Context, opts ForkOpts) (string, error) {
	data, err := c.Invoke(ctx, scopeSession(opts.SourceSessionID), "sessionLifecycle", "fork", opts)
	if err != nil {
		return "", err
	}
	var res struct {
		SessionID string `json:"sessionId"`
		ID        string `json:"id"`
	}
	if err := json.Unmarshal(data, &res); err != nil {
		return "", fmt.Errorf("kimiweb: decode fork result: %w", err)
	}
	if res.SessionID != "" {
		return res.SessionID, nil
	}
	return res.ID, nil
}

// Rename 重命名（sessionMetadata.setTitle）。
func (c *Client) Rename(ctx context.Context, sessionID, title string) error {
	_, err := c.Invoke(ctx, scopeSession(sessionID), "sessionMetadata", "setTitle", title)
	return err
}

// ShellEnv 对应导出 payload 的 shellEnv（仅诊断信息，可空）。
type ShellEnv struct {
	Term               string `json:"term,omitempty"`
	TermProgram        string `json:"termProgram,omitempty"`
	TermProgramVersion string `json:"termProgramVersion,omitempty"`
	Multiplexer        string `json:"multiplexer,omitempty"`
	Shell              string `json:"shell,omitempty"`
}

// ExportOpts 是 export 的参数（对应 ExportSessionPayload/Options）。
// Version 必填（kimi 要求 host 版本）；其余可选。
type ExportOpts struct {
	Version           string
	OutputPath        string
	IncludeGlobalLog  bool
	IncludeDesktopLog bool
	DesktopVersion    string
	InstallSource     string
	ShellEnv          *ShellEnv
	MaxArchiveBytes   int
	WebLog            string
}

// ExportResult 是 export 的返回（对应 ExportSessionResult）。
type ExportResult struct {
	ZipPath    string          `json:"zipPath"`
	SessionDir string          `json:"sessionDir"`
	Entries    []string        `json:"entries"`
	Manifest   json.RawMessage `json:"manifest"`
}

// Export 导出会话诊断 zip（sessionExport.export，App/core 域，sessionId 在 payload 中）。
func (c *Client) Export(ctx context.Context, sessionID string, opts ExportOpts) (*ExportResult, error) {
	if opts.Version == "" {
		return nil, fmt.Errorf("kimiweb: export requires Version (host version)")
	}
	input := map[string]any{
		"sessionId": sessionID,
		"version":   opts.Version,
	}
	if opts.OutputPath != "" {
		input["outputPath"] = opts.OutputPath
	}
	if opts.IncludeGlobalLog {
		input["includeGlobalLog"] = true
	}
	if opts.IncludeDesktopLog {
		input["includeDesktopLog"] = true
	}
	if opts.DesktopVersion != "" {
		input["desktopVersion"] = opts.DesktopVersion
	}
	if opts.InstallSource != "" {
		input["installSource"] = opts.InstallSource
	}
	if opts.ShellEnv != nil {
		input["shellEnv"] = opts.ShellEnv
	}
	options := map[string]any{}
	if opts.MaxArchiveBytes > 0 {
		options["maxArchiveBytes"] = opts.MaxArchiveBytes
	}
	if opts.WebLog != "" {
		options["webLog"] = opts.WebLog
	}

	data, err := c.Invoke(ctx, "", "sessionExport", "export", input, options)
	if err != nil {
		return nil, err
	}
	var res ExportResult
	if err := json.Unmarshal(data, &res); err != nil {
		return nil, fmt.Errorf("kimiweb: decode export result: %w", err)
	}
	return &res, nil
}

// scopeSession 构造 session scope 路径段（每段在 Invoke 中被单独转义）。
func scopeSession(sessionID string) string {
	return "session/" + sessionID
}
