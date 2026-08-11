// Package acp 是 Kimi Code 的 ACP 客户端，基于官方 Go SDK
// (github.com/coder/acp-go-sdk) 实现。
//
// 设计要点：
//   - 所有 ACP 能力的解析 / 序列化由 SDK 的强类型结构承担，本包只负责三件事：
//     1) 拉起 / 重启 kimi 子进程（stdin/stdout 管道）；
//     2) 把 SDK 的 ClientSideConnection 接到子进程；
//     3) 实现 acp.Client 接口，将 kimi 下发的 update / permission 投递给中继回调。
//   - kimi 未实现的能力（session/close）与中继未声明的能力（fs/*、terminal/*）
//     由 SDK 自动返回 methodNotFound，与既有策略一致。
//   - 重写后，中继在结构上覆盖 ACP 的全部能力项（client 端方法 + session/update
//     联合类型的所有 arm），未启用者自动 methodNotFound，不会因"手搓漏判"而缺能力。
package acp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"sync"
	"sync/atomic"

	acpsdk "github.com/coder/acp-go-sdk"
)

// Handlers 是中继注入的回调。
type Handlers struct {
	// OnUpdate 收到 kimi 下发的任意 session/update（已提取出 update 负载，强类型）。
	OnUpdate func(sessionID string, update json.RawMessage)
	// OnPermission 是 kimi 请求权限时的同步回调：必须阻塞并返回给 kimi 的决定。
	// 中继在此实现 yolo/auto/plan 的自动裁决，或挂起等待端侧（Flutter）用户拍板。
	OnPermission func(ctx context.Context, req acpsdk.RequestPermissionRequest) (acpsdk.RequestPermissionResponse, error)
	// OnExit 在 kimi 子进程"非预期退出"时调用（主动 Restart/DebugKill 之外的崩溃）。
	OnExit func()
}

// Client 持有一个 kimi acp 子进程，可 Restart 重建。
type Client struct {
	h Handlers

	life    sync.RWMutex // 保护 cmd/stdin/sdkConn/exitCh 的替换与读取
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	stderr  io.Reader
	exitCh  chan struct{}
	sdkConn *acpsdk.ClientSideConnection

	gen atomic.Int64 // generation：spawn 时读取当前值，Restart 前先 +1
}

// New 启动子进程并建 SDK 连接。
func New(h Handlers) (*Client, error) {
	c := &Client{h: h}
	if err := c.spawn(); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *Client) conn() *acpsdk.ClientSideConnection {
	c.life.RLock()
	defer c.life.RUnlock()
	return c.sdkConn
}

// spawn 启动一个新 kimi acp 进程并建 SDK 连接。myGen 取当前 gen（不在此 +1）。
func (c *Client) spawn() error {
	cmd := exec.Command("kimi", "acp")
	cmd.Env = os.Environ()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("spawn kimi acp: %w", err)
	}
	exitCh := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exitCh) }()

	myGen := c.gen.Load()

	c.life.Lock()
	c.cmd = cmd
	c.stdin = stdin
	c.stderr = stderr
	c.exitCh = exitCh
	rc := &relayClient{h: c.h}
	c.sdkConn = acpsdk.NewClientSideConnection(rc, stdin, stdout)
	c.life.Unlock()

	go c.drainStderr(stderr)
	// 捕获本次 spawn 的 exitCh，避免 Restart 后误读新进程的 exitCh。
	go func(ec chan struct{}) {
		<-ec
		if c.gen.Load() == myGen && c.h.OnExit != nil {
			c.h.OnExit()
		}
	}(exitCh)
	return nil
}

func (c *Client) drainStderr(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		log.Printf("[kimi:stderr] %s", sc.Text())
	}
}

// ---- 生命周期 ----

// Close 关 stdin 并等子进程退出。
func (c *Client) Close() {
	c.life.RLock()
	exitCh := c.exitCh
	stdin := c.stdin
	c.life.RUnlock()
	if stdin != nil {
		_ = stdin.Close()
	}
	if exitCh != nil {
		<-exitCh
	}
}

// DebugKill 仅开发期：强杀 kimi 子进程，模拟崩溃（不 bump gen，故会触发 OnExit）。
func (c *Client) DebugKill() {
	c.life.RLock()
	cmd := c.cmd
	c.life.RUnlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}

// Restart 关闭当前 kimi 进程并重新 spawn（同步：返回时新进程已起，但未 initialize）。
// 关键：先 gen+1，使旧 watchExit goroutine退出时 myGen != 当前 gen，从而不触发 OnExit。
func (c *Client) Restart() error {
	c.gen.Add(1)
	c.life.RLock()
	exitCh := c.exitCh
	stdin := c.stdin
	c.life.RUnlock()
	if stdin != nil {
		_ = stdin.Close()
	}
	if exitCh != nil {
		<-exitCh // 等旧进程退出
	}
	return c.spawn()
}

// ---- ACP 强类型方法（供中继调用） ----

// Initialize 完成 initialize 握手（protocolVersion 协商为 1，与 kimi 钉死值一致）。
func (c *Client) Initialize(ctx context.Context) (acpsdk.InitializeResponse, error) {
	return c.conn().Initialize(ctx, acpsdk.InitializeRequest{
		ProtocolVersion:    acpsdk.ProtocolVersionNumber,
		ClientCapabilities: acpsdk.ClientCapabilities{},
		ClientInfo:         &acpsdk.Implementation{Name: "sentinel-relay", Version: "0.1"},
	})
}

// Authenticate 补鉴权握手。已登录环境通常直接成功；
// 返回 authRequired(-32000) 时由调用方 best-effort 忽略，不阻断启动。
func (c *Client) Authenticate(ctx context.Context, req acpsdk.AuthenticateRequest) (acpsdk.AuthenticateResponse, error) {
	return c.conn().Authenticate(ctx, req)
}

// NewSession 创建会话，返回 sessionId 与 configOptions（强类型）。
func (c *Client) NewSession(ctx context.Context, cwd string) (acpsdk.SessionId, []acpsdk.SessionConfigOption, error) {
	resp, err := c.conn().NewSession(ctx, acpsdk.NewSessionRequest{
		Cwd:        cwd,
		McpServers: []acpsdk.McpServer{},
	})
	if err != nil {
		return "", nil, err
	}
	return resp.SessionId, resp.ConfigOptions, nil
}

// ListSessions 拉取历史会话列表。
func (c *Client) ListSessions(ctx context.Context) ([]acpsdk.SessionInfo, error) {
	resp, err := c.conn().ListSessions(ctx, acpsdk.ListSessionsRequest{})
	if err != nil {
		return nil, err
	}
	return resp.Sessions, nil
}

// ResumeSession 恢复历史会话，返回其 configOptions。
func (c *Client) ResumeSession(ctx context.Context, sid, cwd string) ([]acpsdk.SessionConfigOption, error) {
	resp, err := c.conn().ResumeSession(ctx, acpsdk.ResumeSessionRequest{
		SessionId: acpsdk.SessionId(sid),
		Cwd:       cwd,
	})
	if err != nil {
		return nil, err
	}
	return resp.ConfigOptions, nil
}

// Prompt 发送一轮对话并等待完成（流式 update 由 SDK 回调投递）。
func (c *Client) Prompt(ctx context.Context, sid, text string) error {
	_, err := c.conn().Prompt(ctx, acpsdk.PromptRequest{
		SessionId: acpsdk.SessionId(sid),
		Prompt:    []acpsdk.ContentBlock{acpsdk.TextBlock(text)},
	})
	return err
}

// Cancel 取消当前轮（notification，无 id，kimi 以 stopReason=cancelled 返回）。
func (c *Client) Cancel(ctx context.Context, sid string) error {
	return c.conn().Cancel(ctx, acpsdk.CancelNotification{SessionId: acpsdk.SessionId(sid)})
}

// SetMode 切换会话模式。
func (c *Client) SetMode(ctx context.Context, sid, modeID string) error {
	_, err := c.conn().SetSessionMode(ctx, acpsdk.SetSessionModeRequest{
		SessionId: acpsdk.SessionId(sid),
		ModeId:    acpsdk.SessionModeId(modeID),
	})
	return err
}

// SetConfigOption 设置会话配置项（如 model）。
func (c *Client) SetConfigOption(ctx context.Context, sid, configID, value string) error {
	_, err := c.conn().SetSessionConfigOption(ctx, acpsdk.SetSessionConfigOptionRequest{
		ValueId: &acpsdk.SetSessionConfigOptionValueId{
			SessionId: acpsdk.SessionId(sid),
			ConfigId:  acpsdk.SessionConfigId(configID),
			Value:     acpsdk.SessionConfigValueId(value),
		},
	})
	return err
}

// ---- acp.Client 实现（kimi → 中继） ----

// relayClient 实现 acp.Client：把 kimi 下发的 update / permission 投递给中继回调。
// 未实现的 client 方法（fs/*、terminal/*）显式返回 methodNotFound；由于中继在
// Initialize 时未声明这些能力，kimi 正常不会触发，这里是防御性兜底。
type relayClient struct {
	h Handlers
}

var _ acpsdk.Client = (*relayClient)(nil)

func (c *relayClient) SessionUpdate(ctx context.Context, params acpsdk.SessionNotification) error {
	if c.h.OnUpdate != nil {
		c.h.OnUpdate(string(params.SessionId), mustJSON(params.Update))
	}
	return nil
}

func (c *relayClient) RequestPermission(ctx context.Context, params acpsdk.RequestPermissionRequest) (acpsdk.RequestPermissionResponse, error) {
	if c.h.OnPermission != nil {
		return c.h.OnPermission(ctx, params)
	}
	// 兜底：未注入回调时直接放行（不应发生）。
	return acpsdk.RequestPermissionResponse{Outcome: acpsdk.RequestPermissionOutcome{
		Selected: &acpsdk.RequestPermissionOutcomeSelected{OptionId: "approve_once", Outcome: "selected"},
	}}, nil
}

func (c *relayClient) ReadTextFile(ctx context.Context, params acpsdk.ReadTextFileRequest) (acpsdk.ReadTextFileResponse, error) {
	return acpsdk.ReadTextFileResponse{}, acpsdk.NewMethodNotFound("fs/read_text_file")
}
func (c *relayClient) WriteTextFile(ctx context.Context, params acpsdk.WriteTextFileRequest) (acpsdk.WriteTextFileResponse, error) {
	return acpsdk.WriteTextFileResponse{}, acpsdk.NewMethodNotFound("fs/write_text_file")
}
func (c *relayClient) CreateTerminal(ctx context.Context, params acpsdk.CreateTerminalRequest) (acpsdk.CreateTerminalResponse, error) {
	return acpsdk.CreateTerminalResponse{}, acpsdk.NewMethodNotFound("terminal/create")
}
func (c *relayClient) KillTerminal(ctx context.Context, params acpsdk.KillTerminalRequest) (acpsdk.KillTerminalResponse, error) {
	return acpsdk.KillTerminalResponse{}, acpsdk.NewMethodNotFound("terminal/kill")
}
func (c *relayClient) TerminalOutput(ctx context.Context, params acpsdk.TerminalOutputRequest) (acpsdk.TerminalOutputResponse, error) {
	return acpsdk.TerminalOutputResponse{}, acpsdk.NewMethodNotFound("terminal/output")
}
func (c *relayClient) ReleaseTerminal(ctx context.Context, params acpsdk.ReleaseTerminalRequest) (acpsdk.ReleaseTerminalResponse, error) {
	return acpsdk.ReleaseTerminalResponse{}, acpsdk.NewMethodNotFound("terminal/release")
}
func (c *relayClient) WaitForTerminalExit(ctx context.Context, params acpsdk.WaitForTerminalExitRequest) (acpsdk.WaitForTerminalExitResponse, error) {
	return acpsdk.WaitForTerminalExitResponse{}, acpsdk.NewMethodNotFound("terminal/wait_for_exit")
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// ConfigOptionsToRaw 把 SDK 的强类型 configOptions 转回 ACP 原始 JSON 数组，
// 保留 id / currentValue / type 等字段，使 store.Mode() 等既有解析保持兼容。
// （SessionConfigOption 是 union 类型，直接 json.Marshal 会得到 [{},{}]，故逐臂展开。）
//
// 兜底：union 子类型（如 options 为空）的 MarshalJSON 可能返回空/非法字节，此时退化为
// 仅保留 id / currentValue / type / name 的最小对象，确保 store.Mode() 仍可解析（不丢能力）。
func ConfigOptionsToRaw(opts []acpsdk.SessionConfigOption) json.RawMessage {
	arr := make([]json.RawMessage, 0, len(opts))
	for _, o := range opts {
		var v any
		switch {
		case o.Select != nil:
			v = o.Select
		case o.Boolean != nil:
			v = o.Boolean
		default:
			continue
		}
		b, err := json.Marshal(v)
		if err != nil || len(b) == 0 {
			if fb := configOptionFallback(v); fb != nil {
				b = fb
			} else {
				continue
			}
		}
		arr = append(arr, b)
	}
	b, _ := json.Marshal(arr)
	return b
}

// configOptionFallback 在 union 子类型 marshal 失败时，退化为最小 JSON 对象。
func configOptionFallback(v any) json.RawMessage {
	switch x := v.(type) {
	case *acpsdk.SessionConfigOptionSelect:
		b, _ := json.Marshal(map[string]any{
			"id":           string(x.Id),
			"currentValue": string(x.CurrentValue),
			"type":         x.Type,
			"name":         x.Name,
		})
		return b
	case *acpsdk.SessionConfigOptionBoolean:
		b, _ := json.Marshal(map[string]any{
			"id":           string(x.Id),
			"currentValue": x.CurrentValue,
			"type":         x.Type,
			"name":         x.Name,
		})
		return b
	}
	return nil
}
