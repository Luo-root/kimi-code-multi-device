package main

// probe/setmode/main.go — 实测 ACP 会话级配置切换（设计文档 §18 命门 #1）
// 验证 session/set_mode 与 session/set_config_option 是否可用、参数格式。
// 运行：go run .\probe\setmode\main.go

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

type rpcMsg struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      *int            `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   json.RawMessage `json:"error,omitempty"`
}

type client struct {
	stdin  io.WriteCloser
	mu     sync.Mutex
	nextID int
	pend   map[int]chan rpcMsg
}

func newClient(stdin io.WriteCloser) *client {
	return &client{stdin: stdin, pend: map[int]chan rpcMsg{}}
}

func (c *client) send(m rpcMsg) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	b, _ := json.Marshal(m)
	b = append(b, '\n')
	_, err := c.stdin.Write(b)
	return err
}

func (c *client) request(method string, params interface{}) (rpcMsg, bool) {
	c.nextID++
	id := c.nextID
	ch := make(chan rpcMsg, 1)
	c.pend[id] = ch
	p, _ := json.Marshal(params)
	_ = c.send(rpcMsg{JSONRPC: "2.0", ID: &id, Method: method, Params: p})
	select {
	case m := <-ch:
		return m, true
	case <-time.After(20 * time.Second):
		return rpcMsg{}, false
	}
}

func (c *client) readLoop(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		fmt.Printf("[agent] %s\n", line)
		var m rpcMsg
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			continue
		}
		if m.ID != nil && m.Method == "" { // 这是给我们某个 request 的 response
			if ch, ok := c.pend[*m.ID]; ok {
				select {
				case ch <- m:
				default:
				}
			}
		}
	}
}

func show(label string, m rpcMsg, ok bool) {
	if !ok {
		fmt.Printf("\n>>> %s: 无响应（超时）\n\n", label)
		return
	}
	if len(m.Error) > 0 {
		fmt.Printf("\n>>> %s: ERROR %s\n\n", label, string(m.Error))
	} else {
		fmt.Printf("\n>>> %s: OK %s\n\n", label, string(m.Result))
	}
}

func main() {
	cmd := exec.Command("kimi", "acp")
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		fmt.Println("启动 kimi acp 失败:", err)
		os.Exit(1)
	}
	c := newClient(stdin)
	go c.readLoop(stdout)
	go func() {
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			fmt.Printf("[stderr] %s\n", sc.Text())
		}
	}()

	wd, _ := os.Getwd()

	// initialize
	m, ok := c.request("initialize", map[string]interface{}{
		"protocolVersion":    1,
		"clientCapabilities": map[string]interface{}{},
		"clientInfo":         map[string]interface{}{"name": "probe-set", "version": "0.1"},
	})
	show("initialize", m, ok)

	// session/new
	m, ok = c.request("session/new", map[string]interface{}{
		"cwd": wd, "mcpServers": []interface{}{},
	})
	show("session/new", m, ok)
	var nr struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(m.Result, &nr)
	sid := nr.SessionID
	fmt.Printf(">>> sessionId = %s\n", sid)

	// 命门 #1a：切 mode
	m, ok = c.request("session/set_mode", map[string]interface{}{
		"sessionId": sid, "mode": "plan",
	})
	show("session/set_mode (plan)", m, ok)

	m, ok = c.request("session/set_mode", map[string]interface{}{
		"sessionId": sid, "mode": "default",
	})
	show("session/set_mode (default 切回)", m, ok)

	// 命门 #1b：切 model（config option）
	m, ok = c.request("session/set_config_option", map[string]interface{}{
		"sessionId": sid, "configId": "model", "value": "myprovider/my-model",
	})
	show("session/set_config_option (model)", m, ok)

	fmt.Println(">>> 实测完成。把上面每个 >>> 的 OK / ERROR 结果贴回来。")
	time.Sleep(1 * time.Second)
	_ = stdin.Close()
	_ = cmd.Wait()
}
