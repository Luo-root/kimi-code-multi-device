package relay

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/Luo-root/kimi-code-multi-device/relay/internal/acp"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/session"
	"github.com/gorilla/websocket"
)

// Relay 把 Kimi（acp）与若干端（websocket）缝在一起，是"单一真相"的持有者。
type Relay struct {
	acp   *acp.Client
	store *session.Store

	mu      sync.RWMutex
	clients map[*client]bool
}

type client struct {
	conn *websocket.Conn
	send chan []byte
	wmu  sync.Mutex // 单连接串行写
}

func New() *Relay {
	return &Relay{store: session.New(), clients: map[*client]bool{}}
}

// Start 初始化 ACP 并建一个默认会话，方便连上来即可测试。
func (r *Relay) Start() error {
	if os.Getenv("KIMI_CODE_HOME") == "" {
		log.Println("[relay] 警告：未设置 KIMI_CODE_HOME，可能 Authentication required")
	}
	ac, err := acp.New(acp.Handlers{
		OnUpdate:     r.onUpdate,
		OnPermission: r.onPermission,
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
	cwd, _ := os.Getwd()
	if _, err := r.newSession(ctx, cwd); err != nil {
		return err
	}
	return nil
}

func (r *Relay) Close() {
	if r.acp != nil {
		r.acp.Close()
	}
}

// newSession 建会话，存快照，广播 created。返回 sid。
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
	r.store.Set(res.SessionID, res.ConfigOptions)
	r.broadcast(Env{
		Type:      DownSessionCreated,
		SessionID: res.SessionID,
		Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: res.ConfigOptions}),
	})
	return res.SessionID, nil
}

// onUpdate 透传流，并旁路记录 config 快照（供新连接补发）。
func (r *Relay) onUpdate(sid string, update json.RawMessage) {
	var probe struct {
		SessionUpdate string          `json:"sessionUpdate"`
		ConfigOptions json.RawMessage `json:"configOptions"`
	}
	_ = json.Unmarshal(update, &probe)
	if probe.SessionUpdate == "config_option_update" && len(probe.ConfigOptions) > 0 {
		r.store.Set(sid, probe.ConfigOptions)
	}
	r.broadcast(Env{Type: DownSessionUpdate, SessionID: sid, Payload: update})
}

// onPermission 把 Kimi 的许可请求转成端能渲染的卡，permissionId 透传 Kimi 的 id。
func (r *Relay) onPermission(sid string, id json.RawMessage, params json.RawMessage) {
	var p struct {
		ToolCall json.RawMessage `json:"toolCall"`
		Options  json.RawMessage `json:"options"`
	}
	_ = json.Unmarshal(params, &p)
	r.broadcast(Env{
		Type:      DownPermRequest,
		SessionID: sid,
		Payload: mustJSON(DownPermRequestPayload{
			PermissionID: id, ToolCall: p.ToolCall, Options: p.Options,
		}),
	})
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
		default: // 端太慢，丢这一帧并记日志；生产可改为断开慢端
			log.Printf("[relay] 端发送缓冲满，丢帧 type=%s", e.Type)
		}
	}
}

func (r *Relay) sendErr(sid, msg string) {
	r.broadcast(Env{Type: DownRelayError, SessionID: sid, Payload: mustJSON(DownRelayErrorPayload{Message: msg})})
}

// ---- websocket ----

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true }, // 本地开发用
}

func (r *Relay) HandleWS(w http.ResponseWriter, req *http.Request) {
	conn, err := upgrader.Upgrade(w, req, nil)
	if err != nil {
		return
	}
	c := &client{conn: conn, send: make(chan []byte, 64)}
	r.mu.Lock()
	r.clients[c] = true
	r.mu.Unlock()

	go r.writePump(c)
	r.readPump(c) // 在当前 goroutine 读，连接断开后清理
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
		close(c.send) // 触发 writePump 退出 + 移除
		_ = c.conn.Close()
	}()
	r.snapshot(c) // 补发当前所有会话状态
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		r.handleUp(c, data)
	}
}

// snapshot 让新连上来的端立刻看到"现在有哪些会话、各自什么配置"。
func (r *Relay) snapshot(c *client) {
	for sid, opts := range r.store.Snapshot() {
		b, _ := json.Marshal(Env{
			Type:      DownSessionCreated,
			SessionID: sid,
			Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: opts}),
		})
		select {
		case c.send <- b:
		default:
		}
	}
}

// handleUp 分发上行意图。
// 并发关键：凡是会阻塞等 Kimi 的（Request），一律丢进 goroutine，绝不阻塞读循环；
// 否则 permission 决策上行会被堵死，造成"中继等端、端等中继"的死锁。
func (r *Relay) handleUp(c *client, data []byte) {
	var e Env
	if err := json.Unmarshal(data, &e); err != nil {
		return
	}
	switch e.Type {
	case UpPermDecision:
		// Respond 只写 stdin，不阻塞，可同步。
		var d UpPermDecisionPayload
		_ = json.Unmarshal(e.Payload, &d)
		if err := r.acp.Respond(d.PermissionID, map[string]any{
			"outcome": map[string]any{"outcome": "selected", "optionId": d.OptionID},
		}); err != nil {
			r.sendErr(e.SessionID, "permission respond: "+err.Error())
		}
	case UpPrompt:
		var p UpPromptPayload
		_ = json.Unmarshal(e.Payload, &p)
		sid := e.SessionID
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()
			if _, err := r.acp.Request(ctx, "session/prompt", map[string]any{
				"sessionId": sid,
				"prompt":    []any{map[string]any{"type": "text", "text": p.Text}},
			}); err != nil {
				r.sendErr(sid, "prompt: "+err.Error())
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
	}
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
