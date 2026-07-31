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

type Relay struct {
	acp   *acp.Client
	store *session.Store

	mu      sync.RWMutex
	clients map[*client]bool
}

type client struct {
	conn *websocket.Conn
	send chan []byte
	wmu  sync.Mutex
}

func New() *Relay {
	return &Relay{store: session.New(), clients: map[*client]bool{}}
}

// Start 初始化 ACP（带 OnExit）并建默认会话。
func (r *Relay) Start() error {
	if os.Getenv("KIMI_CODE_HOME") == "" {
		log.Println("[relay] 警告：未设置 KIMI_CODE_HOME，可能 Authentication required")
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

func (r *Relay) onUpdate(sid string, update json.RawMessage) {
	var probe struct {
		SessionUpdate string          `json:"sessionUpdate"`
		ConfigOptions json.RawMessage `json:"configOptions"`
	}
	_ = json.Unmarshal(update, &probe)
	if probe.SessionUpdate == "config_option_update" && len(probe.ConfigOptions) > 0 {
		r.store.SetConfig(sid, probe.ConfigOptions)
	}
	r.store.AppendUpdate(sid, update) // 进环形缓冲，供重连/恢复补发
	r.broadcast(Env{Type: DownSessionUpdate, SessionID: sid, Payload: update})
}

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

// onKimiExit kimi 非预期退出：广播 degraded + 作废所有待批准。
func (r *Relay) onKimiExit() {
	log.Println("[relay] kimi 子进程退出（非预期）→ degraded")
	r.broadcast(Env{Type: DownPermInvalidate})
	r.broadcast(Env{Type: DownRelayState, Payload: mustJSON(DownRelayStatePayload{State: "degraded"})})
}

// restartKimi 重新拉起 kimi：Restart + initialize + 逐 sid resume 恢复上下文。
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
	// 逐 sid resume（带 cwd），恢复 Kimi 侧上下文
	for _, sid := range r.store.SIDs() {
		cwd := r.store.CWD(sid)
		m, err := r.acp.Request(ctx, "session/resume", map[string]any{"sessionId": sid, "cwd": cwd})
		if err != nil {
			log.Printf("[relay] resume %s 失败: %v", sid, err)
			r.sendErr(sid, "会话恢复失败，上下文可能丢失: "+err.Error())
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

// sendBlocking 阻塞写，供 snapshot 用（历史不丢帧）。
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

// snapshot 补发当前所有会话：created（含 config）+ 流尾部（历史）。阻塞写不丢帧。
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
}

// handleUp 分发上行。并发关键：会阻塞等 Kimi 的一律丢 goroutine。
func (r *Relay) handleUp(c *client, data []byte) {
	var e Env
	if err := json.Unmarshal(data, &e); err != nil {
		return
	}
	switch e.Type {
	case UpPermDecision:
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
	case UpRestartKimi:
		go r.restartKimi()
	case UpDebugKill:
		r.acp.DebugKill() // 仅开发期：模拟崩溃
	}
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
