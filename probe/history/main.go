package main

// probe/history/main.go — 探历史会话的两条路：① ACP session/list 的返回结构
// ② Kimi 落盘的 sessions 文件结构（为"读文件回看旧对话"探路）。
// 运行：go run .\probe\history\main.go

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
func (c *client) close() { _ = c.stdin.Close(); _ = c.cmd.Wait() }

func show(label string, m rpcMsg, ok bool) {
	if !ok {
		fmt.Printf("\n>>> %s: 无响应\n\n", label)
		return
	}
	if len(m.Error) > 0 {
		fmt.Printf("\n>>> %s: ERROR %s\n\n", label, string(m.Error))
	} else {
		fmt.Printf("\n>>> %s: OK %s\n\n", label, string(m.Result))
	}
}

func main() {
	home := os.Getenv("KIMI_CODE_HOME")
	wd, _ := os.Getwd()

	c := spawn()
	c.request("initialize", map[string]interface{}{
		"protocolVersion": 1, "clientCapabilities": map[string]interface{}{},
		"clientInfo": map[string]interface{}{"name": "probe-history", "version": "0.1"},
	})

	// 建一条会话 + 聊一句，让历史非空
	m, _ := c.request("session/new", map[string]interface{}{"cwd": wd, "mcpServers": []interface{}{}})
	var nr struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(m.Result, &nr)
	fmt.Printf(">>> 新建 sessionId = %s\n", nr.SessionID)
	c.request("session/prompt", map[string]interface{}{
		"sessionId": nr.SessionID,
		"prompt":    []interface{}{map[string]interface{}{"type": "text", "text": "只回复 ok 两个字"}},
	})
	time.Sleep(1 * time.Second)

	fmt.Println("========== ① session/list（空参） ==========")
	m, ok := c.request("session/list", map[string]interface{}{})
	show("list {}", m, ok)

	fmt.Println("========== ① session/list（带 cwd） ==========")
	m, ok = c.request("session/list", map[string]interface{}{"cwd": wd})
	show("list {cwd}", m, ok)

	c.close()

	// ② 看 Kimi 落盘的 sessions 文件结构
	fmt.Println("========== ② KIMI_CODE_HOME 里的 session 文件 ==========")
	if home == "" {
		fmt.Println(">>> 未设置 KIMI_CODE_HOME，跳过文件探查")
		return
	}
	fmt.Printf(">>> 根目录 = %s\n", home)
	jsonlSeen := 0
	_ = filepath.WalkDir(home, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		// 限制深度，避免走太深
		rel, _ := filepath.Rel(home, path)
		if strings.Count(rel, string(os.PathSeparator)) > 4 {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		low := strings.ToLower(path)
		if strings.Contains(low, "session") {
			kind := "file"
			if d.IsDir() {
				kind = "DIR "
			}
			fmt.Printf("    [%s] %s\n", kind, rel)
		}
		if !d.IsDir() && strings.HasSuffix(low, ".jsonl") && jsonlSeen < 2 {
			jsonlSeen++
			fmt.Printf("\n    ---- 样本 jsonl: %s （前 8 行）----\n", rel)
			f, e := os.Open(path)
			if e == nil {
				sc := bufio.NewScanner(f)
				sc.Buffer(make([]byte, 1024*1024), 1024*1024)
				for i := 0; i < 8 && sc.Scan(); i++ {
					line := sc.Text()
					if len(line) > 240 {
						line = line[:240] + "…"
					}
					fmt.Printf("      %s\n", line)
				}
				f.Close()
			}
			fmt.Println()
		}
		return nil
	})
	if jsonlSeen == 0 {
		fmt.Println("    （没找到 .jsonl，可能历史存在别处或格式不同——把上面 [DIR]/[file] 列表贴我）")
	}
	fmt.Println("\n>>> 完成。把 ① 的 list OK/ERROR 和 ② 的路径+jsonl 样本贴回来。")
}
