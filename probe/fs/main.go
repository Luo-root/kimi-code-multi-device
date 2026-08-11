package main

// probe/fs/main.go — 探 kimi acp fs/* reverse-RPC 的真实 schema（probe-first）。
//
// 为何存在：relay 当前未在 initialize 声明 clientCapabilities.fs，kimi 自行本地处理
// 文件 I/O，relay 永远收不到 fs/read_text_file / fs/write_text_file。官方 ACP
// 文档明确这两项"是"已实现、通过 clientCapabilities.fs 公告路由到客户端，但**没给
// param/result 的字段 schema**。动手写 fs 代理前，先用真实流量把"kimi 实际发
// 来的请求长什么样、它接受的回包长什么样"固化下来。
//
// 运行：cd <repo> && go run ./probe/fs
//
// 行为：
//  1) initialize 时声明 clientCapabilities.fs（read+write），触发 kimi
//     把 kaos 层文件 I/O 路由回客户端；
//  2) session/new（临时工作目录）+ session/set_mode → yolo（跳过权限打断）
//     + 一句会真实"写文件再读回"的 prompt；
//  3) 读循环拦截 fs/* reverse-RPC：完整打印原始 JSON（method/params/id），并真实
//     读写文件、回一个按 ACP 约定的合理 result，观察 kimi 是否接受（接受=result
//     形状对，否则会收到 error，同样打印出来）；
//  4) 若全程 fs/* 未出现，打印 gap（声明形状可能不对 / kimi 仍走本地 I/O）。
// 输出同时写 probe/fs/fs_schema_probe.log 留存，便于跨会话复盘。

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
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
	log    *os.File
	cmu    sync.Mutex
	counts map[string]int // session/update 子类型计数（静默统计，末尾汇总）
}

func (c *client) printf(format string, a ...any) {
	s := fmt.Sprintf(format, a...)
	fmt.Print(s)
	if c.log != nil {
		c.log.WriteString(s)
		c.log.Sync()
	}
}

func spawn(logPath string) *client {
	cmd := exec.Command("kimi", "acp")
	cmd.Env = os.Environ()
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	_ = cmd.Start()
	var lf *os.File
	if p, err := filepath.Abs(logPath); err == nil {
		if f, err := os.Create(p); err == nil {
			lf = f
		}
	}
	c := &client{stdin: stdin, cmd: cmd, pend: map[int]chan rpcMsg{}, log: lf, counts: map[string]int{}}
	go c.readLoop(stdout)
	go func() {
		sc := bufio.NewScanner(stderr)
		sc.Buffer(make([]byte, 1024*1024), 1024*1024)
		for sc.Scan() {
			c.printf("[stderr] %s\n", sc.Text())
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

func (c *client) request(method string, params any) (rpcMsg, bool) {
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

func (c *client) respond(id *int, result any) {
	r, _ := json.Marshal(result)
	_ = c.send(rpcMsg{JSONRPC: "2.0", ID: id, Result: r})
}

func (c *client) respondError(id *int, code int, msg string) {
	e, _ := json.Marshal(map[string]any{"code": code, "message": msg})
	_ = c.send(rpcMsg{JSONRPC: "2.0", ID: id, Error: e})
}

func (c *client) readLoop(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 4*1024*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		var m rpcMsg
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			continue
		}
		switch {
		case m.Method == "fs/read_text_file":
			c.handleFsRead(m)
		case m.Method == "fs/write_text_file":
			c.handleFsWrite(m)
		case m.Method == "session/request_permission":
			c.handlePermission(m)
		case m.Method == "session/update":
			// session/update 的 sessionUpdate 类型在 params.update.sessionUpdate（不在 params 顶层）
			var u struct {
				Update struct {
					SessionUpdate string `json:"sessionUpdate"`
				} `json:"update"`
			}
			_ = json.Unmarshal(m.Params, &u)
			c.printf("[update] %s\n", u.Update.SessionUpdate)
		case m.Method != "":
			c.printf("[agent][unknown-method] %s\n", line)
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

// handleFsRead：完整打印 kimi 发来的请求，真实读文件，回一个按 ACP 约定的 result。
func (c *client) handleFsRead(m rpcMsg) {
	c.printf("\n[FS] >>>>> fs/read_text_file 原始请求 <<<<<\n%s\n", string(m.Params))
	var p struct {
		Path   string `json:"path"`
		Offset *int   `json:"offset"`
		Limit  *int   `json:"limit"`
	}
	_ = json.Unmarshal(m.Params, &p)
	data, err := os.ReadFile(p.Path)
	if err != nil {
		c.printf("[FS] 读文件失败: %v → 回 error\n", err)
		c.respondError(m.ID, -32000, "read failed: "+err.Error())
		return
	}
	// ACP 约定：read_text_file result 为 { "content": string }（必要时带 range）。
	result := map[string]any{"content": string(data)}
	if p.Offset != nil {
		result["offset"] = *p.Offset
	}
	if p.Limit != nil {
		result["limit"] = *p.Limit
	}
	c.printf("[FS] <<<<< fs/read_text_file 回包(result) >>>>>\n%s\n", mustJSON(result))
	c.respond(m.ID, result)
}

func (c *client) handleFsWrite(m rpcMsg) {
	c.printf("\n[FS] >>>>> fs/write_text_file 原始请求 <<<<<\n%s\n", string(m.Params))
	var p struct {
		Path    string `json:"path"`
		Content string `json:"content"`
		Mode    string `json:"mode"`
	}
	_ = json.Unmarshal(m.Params, &p)
	if p.Mode == "append" {
		f, err := os.OpenFile(p.Path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			c.respondError(m.ID, -32000, "write failed: "+err.Error())
			return
		}
		_, _ = f.WriteString(p.Content)
		f.Close()
	} else {
		// overwrite（默认）；insert 暂不实现，先按 overwrite 处理并标注 gap。
		if p.Mode == "insert" {
			c.printf("[FS] gap: write mode=insert 未实现，按 overwrite 处理\n")
		}
		if err := os.WriteFile(p.Path, []byte(p.Content), 0o644); err != nil {
			c.respondError(m.ID, -32000, "write failed: "+err.Error())
			return
		}
	}
	result := map[string]any{"ok": true, "bytesWritten": len(p.Content)}
	c.printf("[FS] <<<<< fs/write_text_file 回包(result) >>>>>\n%s\n", mustJSON(result))
	c.respond(m.ID, result)
}

// handlePermission：yolo 模式下本应不触发；若触发则批准"允许"选项，避免误选 reject。
func (c *client) handlePermission(m rpcMsg) {
	var p struct {
		Options []struct {
			OptionID string `json:"optionId"`
			Name     string `json:"name"`
		} `json:"options"`
	}
	_ = json.Unmarshal(m.Params, &p)
	c.printf("[perm] session/request_permission options=%d\n", len(p.Options))
	if len(p.Options) == 0 {
		c.respondError(m.ID, -32602, "no options to approve")
		return
	}
	// 择优：优先选名字/optionId 暗示"允许"的选项；否则退回第一个。
	for _, o := range p.Options {
		low := strings.ToLower(o.OptionID + " " + o.Name)
		if strings.Contains(low, "approve") || strings.Contains(low, "allow") ||
			strings.Contains(low, "accept") || strings.Contains(low, "yes") {
			c.respond(m.ID, map[string]any{"optionId": o.OptionID})
			return
		}
	}
	c.respond(m.ID, map[string]any{"optionId": p.Options[0].OptionID})
}

func mustJSON(v any) string {
	b, _ := json.MarshalIndent(v, "", "  ")
	return string(b)
}

func main() {
	repo, _ := os.Getwd()
	// 注意：go run . 时 cwd 已是 probe/fs，日志直接落当前目录，避免重复拼接路径。
	logPath := filepath.Join(repo, "fs_schema_probe.log")
	c := spawn(logPath)
	defer func() { _ = c.stdin.Close(); _ = c.cmd.Wait(); if c.log != nil { c.log.Close() } }()

	// 1) initialize — 关键：声明 clientCapabilities.fs 触发文件 I/O 路由回客户端
	c.printf("========== initialize（声明 clientCapabilities.fs） ==========\n")
	initRes, initOK := c.request("initialize", map[string]any{
		"protocolVersion": 1,
		"clientCapabilities": map[string]any{
			"fs": map[string]any{
				"read_text_file":  true,
				"write_text_file": true,
			},
		},
		"clientInfo": map[string]any{"name": "probe-fs", "version": "0.1"},
	})
	if initOK {
		c.printf(">>> initialize 响应: %s\n", string(initRes.Result))
	} else {
		c.printf(">>> initialize 无响应\n")
	}

	// 临时工作目录（用系统临时目录，避免仓库嵌套路径导致 kimi 索引异常）
	work := filepath.Join(os.TempDir(), "kimi_fs_probe")
	_ = os.MkdirAll(work, 0o755)
	defer os.RemoveAll(work)

	// 预建一个读入文件，确保 fs/read_text_file 有东西可读
	inPath := filepath.Join(work, "probe_in.txt")
	_ = os.WriteFile(inPath, []byte("hello from fs probe\nsecond line\n"), 0o644)

	// 2) session/new
	m, ok := c.request("session/new", map[string]any{
		"cwd":         work,
		"mcpServers":  []any{},
	})
	if !ok {
		c.printf(">>> session/new 无响应，退出\n")
		return
	}
	var nr struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(m.Result, &nr)
	c.printf("\n>>> sessionId = %s\n", nr.SessionID)

	// 3) yolo 模式跳过权限打断（注意：正确键是 modeId，不是 mode）
	_, _ = c.request("session/set_mode", map[string]any{"sessionId": nr.SessionID, "modeId": "yolo"})

	// 4) 触发：先读 probe_in.txt（→ fs/read_text_file），再写 probe_out.txt（→ fs/write_text_file）
	c.printf("\n========== session/prompt（读文件再写文件） ==========\n")
	_, _ = c.request("session/prompt", map[string]any{
		"sessionId": nr.SessionID,
		"prompt": []any{map[string]any{
			"type": "text",
			"text": "请先用文件系统读取当前目录下的 probe_in.txt，把它的内容原样告诉我。" +
				"然后在同一目录新建 probe_out.txt，内容也写成 probe_in.txt 的第一行。",
		}},
	})

	// 等待 kimi 完成（写+读+回复）。若 fs/* 出现会被读循环拦截并打印。
	c.printf("\n>>> 等待 kimi 完成（最多 70s）...\n")
	time.Sleep(70 * time.Second)

	c.printf("\n========== 探针结束 ==========\n")
	c.cmu.Lock()
	if len(c.counts) > 0 {
		c.printf(">>> session/update 子类型计数: ")
		first := true
		for k, v := range c.counts {
			if !first {
				c.printf(", ")
			}
			c.printf("%s=%d", k, v)
			first = false
		}
		c.printf("\n")
	} else {
		c.printf(">>> 本回合未收到任何 session/update（kimi 可能未处理 prompt）\n")
	}
	c.cmu.Unlock()
	c.printf(">>> 若上方未出现 [FS] >>>>> fs/read|write_text_file 原始请求，说明 fs/* 未路由到客户端（gap：fsCapabilities 声明形状或 kimi 仍走本地 I/O）。\n")
	c.printf(">>> 完整原始流量见 probe/fs/fs_schema_probe.log\n")
}
