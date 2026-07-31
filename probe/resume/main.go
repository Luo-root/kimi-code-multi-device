package main

// probe/resume/main.go — 实测 session/resume（第三刀"重试拉起+恢复"的地基）
// 验证三件事：① resume 参数格式 ② resume 后是否重放历史 update ③ 上下文是否真恢复
// 运行：go run .\probe\resume\main.go

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
	cmd    *exec.Cmd
	mu     sync.Mutex
	nextID int
	pend   map[int]chan rpcMsg
}

func spawn() *client {
	cmd := exec.Command("kimi", "acp")
	cmd.Env = os.Environ()
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		fmt.Println("启动失败:", err)
		os.Exit(1)
	}
	c := &client{stdin: stdin, cmd: cmd, pend: map[int]chan rpcMsg{}}
	go c.readLoop(stdout)
	go func() {
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			fmt.Printf("[stderr] %s\n", sc.Text())
		}
	}()
	return c
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
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	ch := make(chan rpcMsg, 1)
	c.pend[id] = ch
	c.mu.Unlock()
	p, _ := json.Marshal(params)
	_ = c.send(rpcMsg{JSONRPC: "2.0", ID: &id, Method: method, Params: p})
	select {
	case m := <-ch:
		return m, true
	case <-time.After(40 * time.Second):
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

func (c *client) close() {
	_ = c.stdin.Close()
	_ = c.cmd.Wait()
}

func initialize(c *client) {
	c.request("initialize", map[string]interface{}{
		"protocolVersion": 1, "clientCapabilities": map[string]interface{}{},
		"clientInfo": map[string]interface{}{"name": "probe-resume", "version": "0.1"},
	})
}

func prompt(c *client, sid, text string) {
	c.request("session/prompt", map[string]interface{}{
		"sessionId": sid,
		"prompt":    []interface{}{map[string]interface{}{"type": "text", "text": text}},
	})
}

func main() {
	wd, _ := os.Getwd()

	fmt.Println("========== 进程1：建会话 + 建立上下文 ==========")
	c1 := spawn()
	initialize(c1)
	m, _ := c1.request("session/new", map[string]interface{}{"cwd": wd, "mcpServers": []interface{}{}})
	var nr struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(m.Result, &nr)
	sid := nr.SessionID
	fmt.Printf(">>> 进程1 sessionId = %s\n", sid)

	fmt.Println(">>> 进程1 发 prompt：记住数字 42")
	prompt(c1, sid, "请记住数字 42，接下来只回复'已记住'两个字，不要做任何其他事")
	time.Sleep(1 * time.Second)
	fmt.Println(">>> 关闭进程1（模拟 kimi 重启）")
	c1.close()
	time.Sleep(1 * time.Second)

	fmt.Println("\n========== 进程2：resume 该会话 ==========")
	c2 := spawn()
	initialize(c2)
	fmt.Println(">>> 进程2 发 session/resume，参数 {sessionId, cwd}")
	m2, ok := c2.request("session/resume", map[string]interface{}{"sessionId": sid, "cwd": wd})
	if !ok {
		fmt.Println(">>> session/resume: 无响应（超时）")
	} else if len(m2.Error) > 0 {
		fmt.Printf(">>> session/resume: ERROR %s\n", string(m2.Error))
	} else {
		fmt.Printf(">>> session/resume: OK %s\n", string(m2.Result))
	}
	time.Sleep(1 * time.Second)

	fmt.Println(">>> 进程2 发 prompt：问刚才记住的数字（验证上下文是否恢复）")
	prompt(c2, sid, "我刚才让你记住的数字是几？只回答那个数字本身")
	time.Sleep(2 * time.Second)

	fmt.Println("\n>>> 实测完成。看三件事：")
	fmt.Println("    1. session/resume 是 OK 还是 ERROR（参数格式对不对，要不要别的字段）")
	fmt.Println("    2. resume 后有没有重放进程1的历史 update（agent_message_chunk 等又出现一遍）")
	fmt.Println("    3. 进程2问数字，agent 答不答得出 42（上下文是否真恢复）")
	c2.close()
}
