// Package acp 是 Kimi Code 的 ACP 客户端。第三刀新增：Restart / DebugKill / OnExit，
// 用 generation 计数区分"主动重启"与"kimi 真崩"。
package acp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"sync/atomic"
)

type rpcMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   json.RawMessage `json:"error,omitempty"`
}

// Handlers 是中继注入的回调。
type Handlers struct {
	OnUpdate     func(sessionID string, update json.RawMessage)
	OnPermission func(sessionID string, id json.RawMessage, params json.RawMessage)
	// OnExit 在 kimi 子进程"非预期退出"时调用（主动 Restart/DebugKill 之外的崩溃）。
	OnExit func()
}

// Client 持有一个 kimi acp 子进程，可 Restart 重建。
type Client struct {
	h Handlers

	mu     sync.Mutex
	nextID int
	pend   map[string]chan rpcMsg
	wmu    sync.Mutex // stdin 串行写

	life   sync.RWMutex // 保护 cmd/stdin/exitCh 的替换与读取
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	exitCh chan struct{}
	gen    atomic.Int64 // generation：spawn 时读取当前值，Restart 前先 +1
}

// New 启动子进程并起读循环。
func New(h Handlers) (*Client, error) {
	c := &Client{h: h, pend: map[string]chan rpcMsg{}}
	if err := c.spawn(); err != nil {
		return nil, err
	}
	return c, nil
}

// spawn 启动一个新 kimi acp 进程并起读/排错循环。myGen 取当前 gen（不在此 +1）。
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

	myGen := c.gen.Load() // 当前 generation；Restart 已在此之前 +1

	c.life.Lock()
	c.cmd = cmd
	c.stdin = stdin
	c.exitCh = exitCh
	c.life.Unlock()

	go c.readLoop(stdout, myGen)
	go c.drainStderr(stderr)
	return nil
}

func (c *Client) send(m rpcMsg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	c.life.RLock()
	in := c.stdin
	c.life.RUnlock()
	if in == nil {
		return fmt.Errorf("acp: stdin closed")
	}
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err = in.Write(b)
	return err
}

// Request 发带 id 的 request，等 response 或 ctx 取消。
func (c *Client) Request(ctx context.Context, method string, params any) (rpcMsg, error) {
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	idRaw, _ := json.Marshal(id)
	key := string(idRaw)
	ch := make(chan rpcMsg, 1)
	c.pend[key] = ch
	c.mu.Unlock()

	var p json.RawMessage
	if params != nil {
		p, _ = json.Marshal(params)
	}
	if err := c.send(rpcMsg{JSONRPC: "2.0", ID: idRaw, Method: method, Params: p}); err != nil {
		c.mu.Lock()
		delete(c.pend, key)
		c.mu.Unlock()
		return rpcMsg{}, err
	}
	select {
	case m := <-ch:
		c.mu.Lock()
		delete(c.pend, key)
		c.mu.Unlock()
		if len(m.Error) > 0 {
			return m, fmt.Errorf("acp %s: %s", method, string(m.Error))
		}
		return m, nil
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pend, key)
		c.mu.Unlock()
		return rpcMsg{}, ctx.Err()
	}
}

// Respond 回 Kimi 发来的 request（permission）。
func (c *Client) Respond(id json.RawMessage, result any) error {
	r, _ := json.Marshal(result)
	return c.send(rpcMsg{JSONRPC: "2.0", ID: id, Result: r})
}

// Notify 发一条无 id 的 notification（如 session/cancel），不等待响应。
// 注意：notification 不能带 id——ACP 的 session/cancel 是 notification，
// 带 id 的 request 形式会被 kimi 拒为 -32601 Method not found（实测 0.32.0）。
func (c *Client) Notify(method string, params any) error {
	var p json.RawMessage
	if params != nil {
		p, _ = json.Marshal(params)
	}
	return c.send(rpcMsg{JSONRPC: "2.0", Method: method, Params: p})
}

// Restart 关闭当前 kimi 进程并重新 spawn（同步：返回时新进程已起，但未 initialize）。
// 关键：先 gen+1，使旧 readLoop 退出时 myGen != 当前 gen，从而不触发 OnExit。
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
	c.mu.Lock()
	c.pend = map[string]chan rpcMsg{}
	c.nextID = 0
	c.mu.Unlock()
	return c.spawn()
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

func (c *Client) readLoop(r io.Reader, myGen int64) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		var m rpcMsg
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			continue
		}
		switch {
		case m.Method == "session/update":
			var p struct {
				SessionID string          `json:"sessionId"`
				Update    json.RawMessage `json:"update"`
			}
			_ = json.Unmarshal(m.Params, &p)
			if c.h.OnUpdate != nil {
				c.h.OnUpdate(p.SessionID, p.Update)
			}
		case m.Method == "session/request_permission":
			sid := extractSessionID(m.Params)
			if c.h.OnPermission != nil {
				c.h.OnPermission(sid, m.ID, m.Params)
			}
		case m.Method != "":
			// 其它 Kimi 发起的 request/notification，暂不处理。
		default:
			if ch, ok := c.pend[string(m.ID)]; ok {
				select {
				case ch <- m:
				default:
				}
			}
		}
	}
	// 仅当自己仍是当前 generation 才报 OnExit。
	// 真崩：gen 未变，myGen==gen → 报。主动 Restart：gen 已 +1，myGen!=gen → 不报。
	if c.gen.Load() == myGen {
		if c.h.OnExit != nil {
			c.h.OnExit()
		}
	}
}

func (c *Client) drainStderr(r io.Reader) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		fmt.Printf("[kimi:stderr] %s\n", sc.Text())
	}
}

func extractSessionID(params json.RawMessage) string {
	var p struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(params, &p)
	return p.SessionID
}
