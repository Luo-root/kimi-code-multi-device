package main

// probe/replay/main.go — dump 官方文档化的会话回放数据源 wire.jsonl + state.json
// 目的：看清 wire.jsonl 的 schema，为"历史回放"解析器探路。
// 运行：go run .\probe\replay\main.go

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	stdin       io.WriteCloser
	cmd         *exec.Cmd
	mu          sync.Mutex
	nextID      int
	pend        map[int]chan rpcMsg
	updateCount int
}

func spawn() *client {
	cmd := exec.Command("kimi", "acp")
	cmd.Env = os.Environ()
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	_ = cmd.Start()
	c := &client{stdin: stdin, cmd: cmd, pend: map[int]chan rpcMsg{}}
	go c.readLoop(stdout)
	go func() {
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
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
		var m rpcMsg
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			continue
		}
		switch {
		case m.Method == "session/update":
			c.printUpdateShape(m.Params)
		case m.Method == "session/request_permission":
			// 自动批准，让工具真跑，使 wire.jsonl 里有完整的工具调用+结果
			var p struct {
				Options []struct {
					OptionID string `json:"optionId"`
					Kind     string `json:"kind"`
				} `json:"options"`
			}
			_ = json.Unmarshal(m.Params, &p)
			opt := "approve_once"
			for _, o := range p.Options {
				if o.Kind == "allow_once" {
					opt = o.OptionID
					break
				}
			}
			rid := m.ID
			res, _ := json.Marshal(map[string]interface{}{
				"outcome": map[string]interface{}{"outcome": "selected", "optionId": opt},
			})
			_ = c.send(rpcMsg{JSONRPC: "2.0", ID: rid, Result: res})
		case m.Method != "":
			// 其它 notification/update，忽略
		default:
			if m.ID != nil {
				if ch, ok := c.pend[*m.ID]; ok {
					select {
					case ch <- m:
					default:
					}
				}
			}
		}
	}
}
func (c *client) printUpdateShape(params json.RawMessage) {
	var p struct {
		SessionID string                 `json:"sessionId"`
		Update    map[string]interface{} `json:"update"`
	}
	if json.Unmarshal(params, &p) != nil || p.Update == nil {
		return
	}
	c.updateCount++
	u := p.Update
	kind, _ := u["sessionUpdate"].(string)
	fmt.Printf("[live %03d] sessionUpdate=%q fields=", c.updateCount, kind)
	keys := make([]string, 0, len(u))
	for key := range u {
		keys = append(keys, key)
	}
	for i := 0; i < len(keys); i++ {
		for j := i + 1; j < len(keys); j++ {
			if keys[j] < keys[i] {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	fmt.Print("{")
	for i, key := range keys {
		if i > 0 {
			fmt.Print(", ")
		}
		value := u[key]
		fmt.Printf("%s:%s", key, valueShape(value))
	}
	fmt.Println("}")
}

func valueShape(value interface{}) string {
	return valueShapeAt(value, 0)
}

func valueShapeAt(value interface{}, depth int) string {
	switch v := value.(type) {
	case nil:
		return "null"
	case string:
		return fmt.Sprintf("string(len=%d)", len(v))
	case bool:
		return "bool"
	case float64:
		return "number"
	case []interface{}:
		if len(v) == 0 || depth >= 2 {
			return fmt.Sprintf("list(len=%d)", len(v))
		}
		return fmt.Sprintf("list(len=%d,item=%s)", len(v), valueShapeAt(v[0], depth+1))
	case map[string]interface{}:
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		for i := 0; i < len(keys); i++ {
			for j := i + 1; j < len(keys); j++ {
				if keys[j] < keys[i] {
					keys[i], keys[j] = keys[j], keys[i]
				}
			}
		}
		if depth >= 2 {
			return fmt.Sprintf("map(keys=%s)", strings.Join(keys, "|"))
		}
		parts := make([]string, 0, len(keys))
		for _, key := range keys {
			parts = append(parts, key+":"+valueShapeAt(v[key], depth+1))
		}
		return "map{" + strings.Join(parts, ",") + "}"
	default:
		return fmt.Sprintf("%T", value)
	}
}

func (c *client) close() {
	_ = c.stdin.Close()
	done := make(chan struct{})
	go func() {
		_ = c.cmd.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = c.cmd.Process.Kill()
		<-done
	}
}

func main() {
	home := os.Getenv("KIMI_CODE_HOME")
	wd, _ := os.Getwd()
	if home == "" {
		fmt.Println("未设置 KIMI_CODE_HOME")
		return
	}

	c := spawn()
	c.request("initialize", map[string]interface{}{
		"protocolVersion": 1, "clientCapabilities": map[string]interface{}{},
		"clientInfo": map[string]interface{}{"name": "probe-replay", "version": "0.1"},
	})
	m, _ := c.request("session/new", map[string]interface{}{"cwd": wd, "mcpServers": []interface{}{}})
	var nr struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(m.Result, &nr)
	sid := nr.SessionID
	fmt.Printf(">>> sessionId = %s\n", sid)

	// 一句纯回复（产生 agent message）
	c.request("session/prompt", map[string]interface{}{
		"sessionId": sid,
		"prompt":    []interface{}{map[string]interface{}{"type": "text", "text": "用一句话介绍你自己"}},
	})
	// 触发 Bash、Read 和 Edit，记录真实 session/update 字段形状。
	c.request("session/prompt", map[string]interface{}{
		"sessionId": sid,
		"prompt":    []interface{}{map[string]interface{}{"type": "text", "text": "运行 shell 命令 echo REPLAY_TEST 并把输出告诉我"}},
	})
	c.request("session/prompt", map[string]interface{}{
		"sessionId": sid,
		"prompt":    []interface{}{map[string]interface{}{"type": "text", "text": "请用 Read 工具读取 probe/replay/main.go 的前 3 行，只汇报读取成功"}},
	})
	probeFile := filepath.Join(os.TempDir(), "sentinel-acp-probe.txt")
	_ = os.WriteFile(probeFile, []byte("before\n"), 0o600)
	defer os.Remove(probeFile)
	c.request("session/prompt", map[string]interface{}{
		"sessionId": sid,
		"prompt": []interface{}{map[string]interface{}{
			"type": "text",
			"text": "请用 Edit 工具把文件 " + probeFile + " 中的 before 精确替换为 after，只执行一次编辑并汇报成功",
		}},
	})
	time.Sleep(1 * time.Second)
	c.close() // 关闭让 wire.jsonl flush 落盘
	time.Sleep(500 * time.Millisecond)

	// 定位该会话的 wire.jsonl 和 state.json
	var wirePath, statePath string
	_ = filepath.WalkDir(filepath.Join(home, "sessions"), func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if !strings.Contains(path, sid) {
			return nil
		}
		if strings.HasSuffix(path, "wire.jsonl") && strings.Contains(path, "agents") {
			wirePath = path
		}
		if strings.HasSuffix(path, "state.json") {
			statePath = path
		}
		return nil
	})

	fmt.Println("\n========== wire.jsonl（回放数据源）==========")
	if wirePath == "" {
		fmt.Println(">>> 没找到 wire.jsonl，列出 sessions 下所有文件帮你定位：")
		_ = filepath.WalkDir(filepath.Join(home, "sessions"), func(path string, d fs.DirEntry, err error) error {
			if err == nil && !d.IsDir() {
				rel, _ := filepath.Rel(home, path)
				fmt.Println("    " + rel)
			}
			return nil
		})
	} else {
		rel, _ := filepath.Rel(home, wirePath)
		fmt.Printf(">>> 路径 = %s\n", rel)
		f, _ := os.Open(wirePath)
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1024*1024), 1024*1024)
		n := 0
		for sc.Scan() {
			n++
			var item map[string]interface{}
			if json.Unmarshal(sc.Bytes(), &item) != nil {
				fmt.Printf("  [%d] invalid_json\n", n)
				continue
			}
			event, _ := item["event"].(map[string]interface{})
			eventType, _ := event["type"].(string)
			if n <= 15 || eventType == "tool.call" || eventType == "tool.result" {
				fmt.Printf("  [%d] %s\n", n, valueShape(item))
			}
		}
		f.Close()
		fmt.Printf(">>> wire.jsonl 共 %d 行（仅打印 schema，不打印正文）\n", n)
	}

	fmt.Println("\n========== state.json（元数据 schema）==========")
	if statePath == "" {
		fmt.Println(">>> 没找到 state.json")
	} else {
		b, _ := os.ReadFile(statePath)
		var state map[string]interface{}
		if json.Unmarshal(b, &state) != nil {
			fmt.Println(">>> state.json 不是合法 JSON")
		} else {
			fmt.Println(valueShape(state))
		}
	}
}
