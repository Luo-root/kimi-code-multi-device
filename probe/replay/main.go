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
func (c *client) close() { _ = c.stdin.Close(); _ = c.cmd.Wait() }

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
	// 一句触发工具（产生 tool_call + tool_result，自动批准）
	c.request("session/prompt", map[string]interface{}{
		"sessionId": sid,
		"prompt":    []interface{}{map[string]interface{}{"type": "text", "text": "运行 shell 命令 echo REPLAY_TEST 并把输出告诉我"}},
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
		for i := 0; sc.Scan(); i++ {
			n++
			if i < 40 {
				line := sc.Text()
				if len(line) > 320 {
					line = line[:320] + "…"
				}
				fmt.Printf("  [%d] %s\n", i+1, line)
			}
		}
		f.Close()
		fmt.Printf(">>> wire.jsonl 共 %d 行（上面打印前 40 行）\n", n)
	}

	fmt.Println("\n========== state.json（元数据）==========")
	if statePath == "" {
		fmt.Println(">>> 没找到 state.json")
	} else {
		b, _ := os.ReadFile(statePath)
		s := string(b)
		if len(s) > 2500 {
			s = s[:2500] + "…"
		}
		fmt.Println(s)
	}
}
