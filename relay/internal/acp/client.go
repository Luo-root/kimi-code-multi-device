// Package acp 是 Kimi Code 的 ACP 客户端：spawn `kimi acp`，over stdio 跑
// newline-delimited JSON-RPC。它是 v0 探针的工程化版本，把"读循环分发"和
// "request/response 路由"做成可复用的内核。
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
)

// rpcMsg 是 JSON-RPC 一帧。ID 用 RawMessage 透传，int/string 都不在乎。
type rpcMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   json.RawMessage `json:"error,omitempty"`
}

// Handlers 是中继注入的回调。acp 只负责"看见"，怎么反应由中继决定。
type Handlers struct {
	// OnUpdate 收到 session/update（流式思考/回复/工具调用/config 变更…）。
	// update 是 params.update 原样。
	OnUpdate func(sessionID string, update json.RawMessage)
	// OnPermission 收到 session/request_permission（一个 JSON-RPC request）。
	// id 是 Kimi 的 request id，中继必须用它回 Respond；params 含 options/toolCall。
	OnPermission func(sessionID string, id json.RawMessage, params json.RawMessage)
}

// Client 持有一个 kimi acp 子进程。
type Client struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser

	mu     sync.Mutex
	nextID int
	pend   map[string]chan rpcMsg // key = string(id)，等我们自己发出去的 request 的 response
	wmu    sync.Mutex             // stdin 串行写

	h Handlers
}

// New 启动子进程并起读循环。env 透传当前进程环境（含 KIMI_CODE_HOME 登录态）。
func New(h Handlers) (*Client, error) {
	cmd := exec.Command("kimi", "acp")
	cmd.Env = os.Environ() // 继承 KIMI_CODE_HOME 登录态
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("spawn kimi acp: %w", err)
	}
	c := &Client{cmd: cmd, stdin: stdin, pend: map[string]chan rpcMsg{}, h: h}
	go c.readLoop(stdout)
	go c.drainStderr(stderr)
	return c, nil
}

func (c *Client) send(m rpcMsg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err = c.stdin.Write(b)
	return err
}

// Request 发一个带 id 的 request，等 response 或 ctx 取消。
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

// Respond 回一个 Kimi 发来的 request（目前只有 request_permission）。id 原样回。
func (c *Client) Respond(id json.RawMessage, result any) error {
	r, _ := json.Marshal(result)
	return c.send(rpcMsg{JSONRPC: "2.0", ID: id, Result: r})
}

// Close 关 stdin 并等子进程退出。
func (c *Client) Close() {
	_ = c.stdin.Close()
	_ = c.cmd.Wait()
}

func (c *Client) readLoop(r io.Reader) {
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
			// 其它 Kimi 发起的 request/notification，这一刀不处理，留日志。
		default:
			// response 给我们发出去的 request。
			if ch, ok := c.pend[string(m.ID)]; ok {
				select {
				case ch <- m:
				default:
				}
			}
		}
	}
}

func (c *Client) drainStderr(r io.Reader) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		// Kimi 的 stderr 是它的内部日志，转发出来便于排错；生产可降级。
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
