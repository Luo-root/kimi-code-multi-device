package main

// probe/slash/main.go — 实测 slash 命令的 ACP 发送方式（设计文档 §18 #2）
// 验证 session/prompt 发 "/status" 是否触发 Kimi 内置 slash 命令。
// 运行：go run .\probe\slash\main.go

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
	case <-time.After(30 * time.Second):
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
		if m.ID != nil && m.Method == "" {
			if ch, ok := c.pend[*m.ID]; ok {
				select {
				case ch <- m:
				default:
				}
			}
		}
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
	c.request("initialize", map[string]interface{}{
		"protocolVersion": 1, "clientCapabilities": map[string]interface{}{},
		"clientInfo": map[string]interface{}{"name": "probe-slash", "version": "0.1"},
	})
	m, _ := c.request("session/new", map[string]interface{}{"cwd": wd, "mcpServers": []interface{}{}})
	var nr struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(m.Result, &nr)
	sid := nr.SessionID
	fmt.Printf(">>> sessionId = %s\n\n", sid)

	// 命门 #2：发 slash 命令 /status（只读，安全）
	fmt.Println(">>> 发送 session/prompt，内容 = \"/status\"")
	m, ok := c.request("session/prompt", map[string]interface{}{
		"sessionId": sid,
		"prompt":    []interface{}{map[string]interface{}{"type": "text", "text": "/status"}},
	})
	if !ok {
		fmt.Println(">>> session/prompt (/status): 无响应（超时）")
	} else if len(m.Error) > 0 {
		fmt.Printf(">>> session/prompt (/status): ERROR %s\n", string(m.Error))
	} else {
		fmt.Printf(">>> session/prompt (/status): OK %s\n", string(m.Result))
	}

	time.Sleep(2 * time.Second)
	fmt.Println("\n>>> 实测完成。看上面 /status 是被当 slash 命令执行了（返回会话状态），还是被当普通 prompt 处理了。")
	_ = stdin.Close()
	_ = cmd.Wait()
}
