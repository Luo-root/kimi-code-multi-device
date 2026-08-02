package relay

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Luo-root/kimi-code-multi-device/relay/internal/acp"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/bark"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/permit"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/replay"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/risk"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/session"
	"github.com/gorilla/websocket"
)

type Relay struct {
	acp      *acp.Client
	store    *session.Store
	kimiHome string

	bark   *bark.Notifier
	permit *permit.Manager

	// 许可裁决配置
	permTimeout         time.Duration // manual 模式超时阈值，默认 5 分钟
	autoPassNonCritical bool          // §10 3.5 非关键超时自动放行开关，默认关

	// kimi 健康（§08 ⑥ 心跳）：false=degraded。OnExit 置 false，Restart 置 true。
	kimiAlive bool

	mu      sync.RWMutex
	clients map[*client]bool
}

type client struct {
	conn *websocket.Conn
	send chan []byte
	wmu  sync.Mutex
}

func New() *Relay {
	r := &Relay{
		store:               session.New(),
		kimiHome:            replay.DefaultHome(),
		clients:             map[*client]bool{},
		bark:                bark.New(),
		permTimeout:         permTimeoutFromEnv(),
		autoPassNonCritical: os.Getenv("PERM_AUTO_PASS_NONCRITICAL") == "1",
	}
	r.permit = permit.New(r.onPermTimeout)
	return r
}

// permTimeoutFromEnv 读 PERM_TIMEOUT_SECONDS，默认 300s（5 分钟）。
func permTimeoutFromEnv() time.Duration {
	if v := os.Getenv("PERM_TIMEOUT_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return time.Duration(n) * time.Second
		}
	}
	return 5 * time.Minute
}

func (r *Relay) Start() error {
	if r.kimiHome == "" {
		log.Println("[relay] 警告：无法确定 KIMI_CODE_HOME，历史回放不可用")
	} else {
		log.Printf("[relay] KIMI_CODE_HOME = %s", r.kimiHome)
	}
	ac, err := acp.New(acp.Handlers{
		OnUpdate:     r.onUpdate,
		OnPermission: r.onPermission,
		OnExit:       r.onKimiExit,
	})
	if err != nil {
		return err
	}
	r.acp = ac

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if _, err := r.acp.Request(ctx, "initialize", map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": map[string]any{},
		"clientInfo":         map[string]any{"name": "sentinel-relay", "version": "0.1"},
	}); err != nil {
		return err
	}
	r.kimiAlive = true
	cwd, _ := os.Getwd()
	if _, err := r.newSession(ctx, cwd); err != nil {
		return err
	}
	if err := r.refreshHistory(ctx); err != nil {
		log.Printf("[relay] 启动拉取历史列表失败: %v", err)
	}
	return nil
}

func (r *Relay) Close() {
	if r.acp != nil {
		r.acp.Close()
	}
}

func (r *Relay) newSession(ctx context.Context, cwd string) (string, error) {
	m, err := r.acp.Request(ctx, "session/new", map[string]any{
		"cwd": cwd, "mcpServers": []any{},
	})
	if err != nil {
		return "", err
	}
	var res struct {
		SessionID     string          `json:"sessionId"`
		ConfigOptions json.RawMessage `json:"configOptions"`
	}
	_ = json.Unmarshal(m.Result, &res)
	r.store.SetCWD(res.SessionID, cwd)
	r.store.SetConfig(res.SessionID, res.ConfigOptions)
	r.broadcast(Env{
		Type:      DownSessionCreated,
		SessionID: res.SessionID,
		Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: res.ConfigOptions}),
	})
	return res.SessionID, nil
}

func (r *Relay) refreshHistory(ctx context.Context) error {
	m, err := r.acp.Request(ctx, "session/list", map[string]any{})
	if err != nil {
		return err
	}
	var res struct {
		Sessions []session.SessionMeta `json:"sessions"`
	}
	_ = json.Unmarshal(m.Result, &res)
	r.store.SetHistory(res.Sessions)
	return nil
}

func (r *Relay) listSessions() {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := r.refreshHistory(ctx); err != nil {
		r.sendErr("", "list_sessions: "+err.Error())
		return
	}
	r.broadcast(Env{Type: DownSessionList, Payload: mustJSON(DownSessionListPayload{Sessions: r.store.History()})})
}

// openHistory 打开历史会话：活跃则直接补发；否则 resume 恢复上下文 + 读 wire.jsonl 回放。
func (r *Relay) openHistory(sid, cwd string) {
	// 活跃会话（中继已有流尾部）：直接补发 created
	if len(r.store.Tail(sid)) > 0 {
		r.broadcast(Env{
			Type:      DownSessionCreated,
			SessionID: sid,
			Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: r.store.Snapshot()[sid]}),
		})
		return
	}
	// 历史会话：resume 恢复 Kimi 侧上下文
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	m, err := r.acp.Request(ctx, "session/resume", map[string]any{"sessionId": sid, "cwd": cwd})
	if err != nil {
		r.sendErr(sid, "恢复历史会话失败: "+err.Error())
		return
	}
	var res struct {
		ConfigOptions json.RawMessage `json:"configOptions"`
	}
	_ = json.Unmarshal(m.Result, &res)
	r.store.SetCWD(sid, cwd)
	if len(res.ConfigOptions) > 0 {
		r.store.SetConfig(sid, res.ConfigOptions)
	}
	// 读历史回放（先于 created 发送，前端按序处理：先渲染历史，再据 resumed 决定是否兜底）
	blocks, meta, herr := replay.LoadHistory(r.kimiHome, sid)
	if herr != nil {
		log.Printf("[relay] 读取历史回放失败 %s: %v", sid, herr)
	}
	if blocks == nil {
		blocks = []replay.Block{}
	}
	r.broadcast(Env{
		Type:      DownSessionHistory,
		SessionID: sid,
		Payload:   mustJSON(DownSessionHistoryPayload{Blocks: blocks, Title: meta.Title, Count: len(blocks)}),
	})
	r.broadcast(Env{
		Type:      DownSessionCreated,
		SessionID: sid,
		Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: res.ConfigOptions, Resumed: true}),
	})
}

func (r *Relay) onUpdate(sid string, update json.RawMessage) {
	var probe struct {
		SessionUpdate string          `json:"sessionUpdate"`
		ConfigOptions json.RawMessage `json:"configOptions"`
	}
	_ = json.Unmarshal(update, &probe)
	if probe.SessionUpdate == "config_option_update" && len(probe.ConfigOptions) > 0 {
		r.store.SetConfig(sid, probe.ConfigOptions)
	}
	r.store.AppendUpdate(sid, update)
	r.broadcast(Env{Type: DownSessionUpdate, SessionID: sid, Payload: update})
}

func (r *Relay) onPermission(sid string, id json.RawMessage, params json.RawMessage) {
	var p struct {
		ToolCall json.RawMessage `json:"toolCall"`
		Options  json.RawMessage `json:"options"`
	}
	_ = json.Unmarshal(params, &p)
	command := extractCommand(p.ToolCall)
	critical := risk.IsCritical(command)
	mode := r.store.Mode(sid)

	switch mode {
	case "yolo", "auto":
		// agent 自主决策：直接放行，不打扰人（哨兵退场）。
		log.Printf("[relay] %s 模式自动放行 sid=%s critical=%v", mode, sid, critical)
		r.respondPermission(id, "approve_once")
	case "plan":
		// 只读模式不应有工具调用，记异常并拒绝。
		log.Printf("[relay] plan 模式出现工具调用，拒绝 sid=%s: %s", sid, command)
		r.respondPermission(id, "reject")
	default: // manual / default —— 哨兵在场
		deadline := time.Now().Add(r.permTimeout)
		r.permit.Register(sid, id, deadline, critical)
		r.broadcast(Env{
			Type:      DownPermRequest,
			SessionID: sid,
			Payload: mustJSON(DownPermRequestPayload{
				PermissionID: id, ToolCall: p.ToolCall, Options: p.Options,
				DeadlineMs: deadline.UnixMilli(), Critical: critical,
			}),
		})
		// 门铃只当门铃，不传命令内容。
		r.bark.Notify("SENTINEL", "有命令等你批准")
	}
}

// respondPermission 回 Kimi 一个许可决定。
func (r *Relay) respondPermission(id json.RawMessage, optionID string) {
	if err := r.acp.Respond(id, map[string]any{
		"outcome": map[string]any{"outcome": "selected", "optionId": optionID},
	}); err != nil {
		r.sendErr("", "permission respond: "+err.Error())
	}
}

// onPermTimeout 超时未决：按策略代答（默认拒绝；非关键+开关开则放行）+ 广播失效 + 门铃。
func (r *Relay) onPermTimeout(sid string, id json.RawMessage, critical bool) {
	optionID := "reject"
	note := "一条命令已超时拒绝"
	if !critical && r.autoPassNonCritical {
		optionID = "approve_once"
		note = "一条非关键命令已超时自动放行"
	}
	r.respondPermission(id, optionID)
	r.broadcast(Env{Type: DownPermInvalidate})
	r.bark.Notify("SENTINEL", note)
	log.Printf("[relay] 许可超时 sid=%s critical=%v → %s", sid, critical, optionID)
}

// extractCommand 从 toolCall 提取命令文本（与端 extractToolText 同源）。
func extractCommand(toolCall json.RawMessage) string {
	var tc struct {
		RawInput struct {
			Command string `json:"command"`
		} `json:"rawInput"`
		Content []struct {
			Content struct {
				Text string `json:"text"`
			} `json:"content"`
			Text string `json:"text"`
		} `json:"content"`
	}
	_ = json.Unmarshal(toolCall, &tc)
	if tc.RawInput.Command != "" {
		return stripCmdPrefix(tc.RawInput.Command)
	}
	var buf strings.Builder
	for _, c := range tc.Content {
		if c.Content.Text != "" {
			buf.WriteString(c.Content.Text)
		} else if c.Text != "" {
			buf.WriteString(c.Text)
		}
	}
	return stripCmdPrefix(buf.String())
}

func stripCmdPrefix(s string) string {
	for _, m := range []string{"Requesting approval to Running: ", "Running: "} {
		if strings.HasPrefix(s, m) {
			return strings.TrimPrefix(s, m)
		}
	}
	return s
}

func (r *Relay) onKimiExit() {
	log.Println("[relay] kimi 子进程退出（非预期）→ degraded")
	r.kimiAlive = false
	// kimi 没了，pending 许可 respond 无意义，只清定时器；端侧凭 invalidate 收尾。
	r.permit.InvalidateAll()
	r.broadcast(Env{Type: DownPermInvalidate})
	r.broadcast(Env{Type: DownRelayState, Payload: mustJSON(DownRelayStatePayload{State: "degraded"})})
}

func (r *Relay) restartKimi() {
	log.Println("[relay] 重试拉起 kimi …")
	if err := r.acp.Restart(); err != nil {
		r.sendErr("", "restart spawn: "+err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := r.acp.Request(ctx, "initialize", map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": map[string]any{},
		"clientInfo":         map[string]any{"name": "sentinel-relay", "version": "0.1"},
	}); err != nil {
		r.sendErr("", "restart initialize: "+err.Error())
		return
	}
	for _, sid := range r.store.SIDs() {
		cwd := r.store.CWD(sid)
		m, err := r.acp.Request(ctx, "session/resume", map[string]any{"sessionId": sid, "cwd": cwd})
		if err != nil {
			log.Printf("[relay] resume %s 失败: %v", sid, err)
			r.sendErr(sid, "会话恢复失败，上下文可能丢失: "+err.Error())
			// 失效会话从活跃表摘除：否则 snapshot() 会把它再次广播给端侧，
			// 造成死 tab，用户一发消息就被 Kimi 拒（Unknown sessionId）。
			r.store.Remove(sid)
			r.broadcast(Env{Type: DownSessionClosed, SessionID: sid})
			continue
		}
		var res struct {
			ConfigOptions json.RawMessage `json:"configOptions"`
		}
		_ = json.Unmarshal(m.Result, &res)
		if len(res.ConfigOptions) > 0 {
			r.store.SetConfig(sid, res.ConfigOptions)
		}
	}
	r.kimiAlive = true
	r.broadcast(Env{Type: DownRelayState, Payload: mustJSON(DownRelayStatePayload{State: "ok"})})
	log.Println("[relay] kimi 已恢复 → ok")
}

func (r *Relay) broadcast(e Env) {
	b, err := json.Marshal(e)
	if err != nil {
		return
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for c := range r.clients {
		select {
		case c.send <- b:
		default:
			log.Printf("[relay] 端发送缓冲满，丢帧 type=%s", e.Type)
		}
	}
}

func (r *Relay) sendBlocking(c *client, e Env) {
	b, _ := json.Marshal(e)
	c.send <- b
}

func (r *Relay) sendErr(sid, msg string) {
	r.broadcast(Env{Type: DownRelayError, SessionID: sid, Payload: mustJSON(DownRelayErrorPayload{Message: msg})})
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func (r *Relay) HandleWS(w http.ResponseWriter, req *http.Request) {
	conn, err := upgrader.Upgrade(w, req, nil)
	if err != nil {
		return
	}
	c := &client{conn: conn, send: make(chan []byte, 512)}
	r.mu.Lock()
	r.clients[c] = true
	r.mu.Unlock()

	go r.writePump(c)
	r.readPump(c)
}

func (r *Relay) writePump(c *client) {
	defer func() {
		r.mu.Lock()
		delete(r.clients, c)
		r.mu.Unlock()
		_ = c.conn.Close()
	}()
	for msg := range c.send {
		c.wmu.Lock()
		_ = c.conn.WriteMessage(websocket.TextMessage, msg)
		c.wmu.Unlock()
	}
}

func (r *Relay) readPump(c *client) {
	defer func() {
		close(c.send)
		_ = c.conn.Close()
	}()
	r.snapshot(c)
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		r.handleUp(c, data)
	}
}

func (r *Relay) snapshot(c *client) {
	for _, sid := range r.store.SIDs() {
		opts := r.store.Snapshot()[sid]
		r.sendBlocking(c, Env{
			Type:      DownSessionCreated,
			SessionID: sid,
			Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: opts}),
		})
		for _, u := range r.store.Tail(sid) {
			r.sendBlocking(c, Env{Type: DownSessionUpdate, SessionID: sid, Payload: u})
		}
	}
	if h := r.store.History(); len(h) > 0 {
		r.sendBlocking(c, Env{Type: DownSessionList, Payload: mustJSON(DownSessionListPayload{Sessions: h})})
	}
	// 下发当前 kimi 健康态，重连客户端立即知是否 degraded。
	state := "ok"
	if !r.kimiAlive {
		state = "degraded"
	}
	r.sendBlocking(c, Env{Type: DownRelayState, Payload: mustJSON(DownRelayStatePayload{State: state})})
	// 补发在跑会话的 busy，重连后「停」可见性正确。
	for _, sid := range r.store.BusySIDs() {
		r.sendBlocking(c, Env{Type: DownSessionBusy, SessionID: sid, Payload: mustJSON(DownSessionBusyPayload{Busy: true})})
	}
}

func (r *Relay) handleUp(c *client, data []byte) {
	var e Env
	if err := json.Unmarshal(data, &e); err != nil {
		return
	}
	switch e.Type {
	case UpPermDecision:
		var d UpPermDecisionPayload
		_ = json.Unmarshal(e.Payload, &d)
		// 仅当尚未超时才 respond；超时已由中继代答，迟到决定忽略。
		if !r.permit.Resolve(d.PermissionID) {
			log.Printf("[relay] 许可决定迟到（已超时代答）: %s", d.OptionID)
			return
		}
		if err := r.acp.Respond(d.PermissionID, map[string]any{
			"outcome": map[string]any{"outcome": "selected", "optionId": d.OptionID},
		}); err != nil {
			r.sendErr(e.SessionID, "permission respond: "+err.Error())
		}
	case UpPrompt:
		var p UpPromptPayload
		_ = json.Unmarshal(e.Payload, &p)
		sid := e.SessionID
		// 防御：sid 不在活跃表（Kimi 不认识 / 已失效）时不再透传给 Kimi，
		// 否则 Kimi 报 Unknown sessionId 且端侧还卡在死 tab。直接报错并通知端侧移除。
		if sid == "" || !r.store.Has(sid) {
			r.sendErr(sid, "会话不存在或已失效，消息未发送")
			r.broadcast(Env{Type: DownSessionClosed, SessionID: sid})
			return
		}
		go func() {
			// busy 开始：AI 还在输出，驱动端「停」可见。
			r.store.SetBusy(sid, true)
			r.broadcast(Env{Type: DownSessionBusy, SessionID: sid, Payload: mustJSON(DownSessionBusyPayload{Busy: true})})
			start := time.Now()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()
			_, err := r.acp.Request(ctx, "session/prompt", map[string]any{
				"sessionId": sid,
				"prompt":    []any{map[string]any{"type": "text", "text": p.Text}},
			})
			elapsed := time.Since(start)
			// busy 结束：输出完毕（成功或出错都算跑完），「停」退场。
			r.store.SetBusy(sid, false)
			r.broadcast(Env{Type: DownSessionBusy, SessionID: sid, Payload: mustJSON(DownSessionBusyPayload{Busy: false})})
			if err != nil {
				r.sendErr(sid, "prompt: "+err.Error())
				// §04 支柱02 时刻②：跑完（出错）也告知。
				r.bark.Notify("SENTINEL", "一轮跑完（出错）")
				return
			}
			// 长任务跑完才叫（短任务频繁打扰没意义）。
			if elapsed > time.Minute {
				r.bark.Notify("SENTINEL", "长任务跑完了")
			}
		}()
	case UpCancel:
		sid := e.SessionID
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_, _ = r.acp.Request(ctx, "session/cancel", map[string]any{"sessionId": sid})
		}()
	case UpSetMode:
		var s UpSetModePayload
		_ = json.Unmarshal(e.Payload, &s)
		sid := e.SessionID
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_, _ = r.acp.Request(ctx, "session/set_mode", map[string]any{"sessionId": sid, "modeId": s.ModeID})
		}()
	case UpSetModel:
		var s UpSetModelPayload
		_ = json.Unmarshal(e.Payload, &s)
		sid := e.SessionID
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_, _ = r.acp.Request(ctx, "session/set_config_option", map[string]any{
				"sessionId": sid, "configId": "model", "value": s.Value,
			})
		}()
	case UpNewSession:
		var n UpNewSessionPayload
		_ = json.Unmarshal(e.Payload, &n)
		cwd := n.CWD
		if cwd == "" {
			cwd, _ = os.Getwd()
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			if _, err := r.newSession(ctx, cwd); err != nil {
				r.sendErr("", "new_session: "+err.Error())
			}
		}()
	case UpRestartKimi:
		go r.restartKimi()
	case UpDebugKill:
		r.acp.DebugKill()
	case UpListSessions:
		go r.listSessions()
	case UpOpenHistory:
		var o UpOpenHistoryPayload
		_ = json.Unmarshal(e.Payload, &o)
		go r.openHistory(o.SessionID, o.CWD)
	case UpCloseSession:
		sid := e.SessionID
		if sid == "" {
			return
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			// 尽力关闭 Kimi 侧会话（ACP 不支持则忽略错误，端侧 tab 仍移除）。
			if _, err := r.acp.Request(ctx, "session/close", map[string]any{"sessionId": sid}); err != nil {
				log.Printf("[relay] session/close %s 失败（忽略）: %v", sid, err)
			}
			r.store.Remove(sid)
			r.broadcast(Env{Type: DownSessionClosed, SessionID: sid})
		}()
	}
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
