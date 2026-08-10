// Package replay 从 Kimi 本地存储（wire.jsonl）解析历史会话用于回放。
// 路径策略依据官方 data-locations 文档：查 session_index.jsonl 拿 sessionDir，
// 再读 agents/main/wire.jsonl——Kimi 自己用于"会话恢复和回放"的公开契约文件。
package replay

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/Luo-root/kimi-code-multi-device/relay/internal/session"
)

// Block 是回放的一个内容块。
type Block struct {
	Kind       string `json:"kind"`           // user / think / text / tool
	Text       string `json:"text,omitempty"` // user/think/text 内容
	ToolName   string `json:"toolName,omitempty"`
	Command    string `json:"command,omitempty"`
	Desc       string `json:"desc,omitempty"`
	Output     string `json:"output,omitempty"`
	ToolCallID string `json:"toolCallId,omitempty"`
}

// Meta 是会话元数据（来自 state.json）。
type Meta struct {
	Title     string `json:"title"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
	WorkDir   string `json:"workDir"`
}

// DefaultHome 返回 KIMI_CODE_HOME：env 优先，否则平台默认 ~/.kimi-code。
func DefaultHome() string {
	if v := os.Getenv("KIMI_CODE_HOME"); v != "" {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".kimi-code")
}

// LoadHistory 读指定会话的历史块和元数据。
func LoadHistory(kimiHome, sid string) ([]Block, Meta, error) {
	dir, err := findSessionDir(kimiHome, sid)
	if err != nil {
		return nil, Meta{}, err
	}
	blocks, err := parseWire(filepath.Join(dir, "agents", "main", "wire.jsonl"))
	if err != nil {
		return nil, Meta{}, err
	}
	return blocks, readState(filepath.Join(dir, "state.json")), nil
}

// findSessionDir 查 session_index.jsonl 拿 sessionDir；查不到则遍历 sessions/ 兜底。
func findSessionDir(kimiHome, sid string) (string, error) {
	idx := filepath.Join(kimiHome, "session_index.jsonl")
	if f, err := os.Open(idx); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1024*1024), 1024*1024)
		for sc.Scan() {
			var rec struct {
				SessionID  string `json:"sessionId"`
				SessionDir string `json:"sessionDir"`
			}
			if json.Unmarshal(sc.Bytes(), &rec) == nil && rec.SessionID == sid && rec.SessionDir != "" {
				return rec.SessionDir, nil
			}
		}
	}
	// 兜底：遍历 sessions/ 找目录名等于 sid 的
	var found string
	_ = filepath.WalkDir(filepath.Join(kimiHome, "sessions"), func(path string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() && filepath.Base(path) == sid {
			found = path
			return filepath.SkipAll
		}
		return nil
	})
	if found != "" {
		return found, nil
	}
	return "", fmt.Errorf("找不到会话 %s 的存储目录", sid)
}

// wireEvent 是 wire.jsonl 一行的宽松结构（只取回放需要的字段，缺失字段为零值）。
type wireEvent struct {
	Type  string `json:"type"`
	Input []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"input"`
	Event *struct {
		Type        string `json:"type"`
		ToolCallID  string `json:"toolCallId"`
		Name        string `json:"name"`
		Description string `json:"description"`
		Part        *struct {
			Type  string `json:"type"`
			Think string `json:"think"`
			Text  string `json:"text"`
		} `json:"part"`
		Args   json.RawMessage `json:"args"`
		Result *struct {
			Output string `json:"output"`
		} `json:"result"`
	} `json:"event"`
}

// parseWire 顺序遍历 wire.jsonl，连续同类型 part 合并，tool.call/result 按 toolCallId 配对。
func parseWire(path string) ([]Block, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var blocks []Block
	var cur *Block // 当前累积的 think/text 块
	flush := func() {
		if cur != nil {
			blocks = append(blocks, *cur)
			cur = nil
		}
	}

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 8*1024*1024)
	for sc.Scan() {
		var ev wireEvent
		if json.Unmarshal(sc.Bytes(), &ev) != nil {
			continue
		}
		switch ev.Type {
		case "turn.prompt":
			flush()
			if len(ev.Input) > 0 && ev.Input[0].Text != "" {
				blocks = append(blocks, Block{Kind: "user", Text: ev.Input[0].Text})
			}
		case "context.append_loop_event":
			if ev.Event == nil {
				continue
			}
			e := ev.Event
			switch e.Type {
			case "content.part":
				if e.Part == nil {
					continue
				}
				switch e.Part.Type {
				case "think":
					if e.Part.Think == "" {
						continue
					}
					if cur != nil && cur.Kind == "think" {
						cur.Text += e.Part.Think
					} else {
						flush()
						cur = &Block{Kind: "think", Text: e.Part.Think}
					}
				case "text":
					if cur != nil && cur.Kind == "text" {
						cur.Text += e.Part.Text
					} else {
						flush()
						cur = &Block{Kind: "text", Text: e.Part.Text}
					}
				}
			case "tool.call":
				flush()
				cmd := commandFromArgs(e.Args)
				blocks = append(blocks, Block{
					Kind: "tool", ToolCallID: e.ToolCallID,
					ToolName: e.Name, Command: cmd, Desc: e.Description,
				})
			case "tool.result":
				if e.Result == nil {
					continue
				}
				for i := len(blocks) - 1; i >= 0; i-- {
					if blocks[i].Kind == "tool" && blocks[i].ToolCallID == e.ToolCallID {
						blocks[i].Output = e.Result.Output
						break
					}
				}
			}
		}
	}
	flush()
	return blocks, nil
}

// commandFromArgs 保持 Bash 的简洁 command，同时完整保留 Edit/Read 等结构化参数。
// Flutter 端的 extract/diff 逻辑读取 Block.Command，因此这里不能丢弃未知字段。
func commandFromArgs(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var args map[string]interface{}
	if json.Unmarshal(raw, &args) != nil {
		return string(raw)
	}
	if command, ok := args["command"].(string); ok && command != "" {
		return command
	}
	compact, err := json.Marshal(args)
	if err != nil {
		return string(raw)
	}
	return string(compact)
}

func readState(path string) Meta {
	var m Meta
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &m)
	}
	return m
}

// ListSessionsFromDisk 从 kimi 本地存储的 session_index.jsonl + state.json 读取会话列表。
//
// 这是 ACP `ListSessions` 的兜底/替代方案：kimi 0.32.0 的 ACP 运行时在某些场景下
// 不返回磁盘已有会话（如进程未加载、索引未同步），导致端侧抽屉为空。直接从磁盘读
// 索引能确保列表与存储一致。
func ListSessionsFromDisk(kimiHome string) ([]session.SessionMeta, error) {
	idx := filepath.Join(kimiHome, "session_index.jsonl")
	f, err := os.Open(idx)
	if err != nil {
		return nil, fmt.Errorf("replay: 打开索引: %w", err)
	}
	defer f.Close()

	var metas []session.SessionMeta
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		var rec struct {
			SessionID  string `json:"sessionId"`
			SessionDir string `json:"sessionDir"`
		}
		if json.Unmarshal(sc.Bytes(), &rec) != nil || rec.SessionID == "" {
			continue
		}
		m := session.SessionMeta{SessionID: rec.SessionID}
		state := readState(filepath.Join(rec.SessionDir, "state.json"))
		if state.Title != "" {
			m.Title = state.Title
		}
		if state.WorkDir != "" {
			m.CWD = state.WorkDir
		} else if rec.SessionDir != "" {
			// 兜底：从 sessionDir 反推 workDir（旧索引可能没写 workDir）。
			m.CWD = rec.SessionDir
		}
		if state.UpdatedAt != "" {
			m.UpdatedAt = state.UpdatedAt
		} else if state.CreatedAt != "" {
			m.UpdatedAt = state.CreatedAt
		}
		metas = append(metas, m)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("replay: 扫描索引: %w", err)
	}
	return metas, nil
}

// ErrSessionNotFound 表示会话在存储中不存在（可能已被删除）。
var ErrSessionNotFound = errors.New("replay: 会话不存在或已被删除")

// DeleteSession 直接从 kimi 本地存储删除一个会话：删除其目录，并从
// session_index.jsonl 索引中移除对应行。
//
// 不走 kimi web 的 HTTP 接口——kimi 0.32.0 没有提供磁盘直读的删除接口
// （:delete 回 40001、DELETE 是 404 路由未找到）。这是 SENTINEL 在「kimi 自身
// 既无删除 API、UI 也没有删除入口」这一限制下的受控兜底：删除会话目录 +
// 清理索引，等价于 kimi 在 UI 里点删除应做的事。
//
// 调用方必须在调用前确认没有 kimi web 实例在运行（单写者独占写锁），
// 否则直接动存储文件会与运行中的实例冲突（50001 storage write failed / 索引损坏）。
func DeleteSession(kimiHome, sid string) error {
	dir, err := findSessionDir(kimiHome, sid)
	if err != nil {
		return fmt.Errorf("%w: %s", ErrSessionNotFound, sid)
	}
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("删除会话目录 %s: %w", dir, err)
	}
	if err := removeIndexEntry(kimiHome, sid); err != nil {
		return fmt.Errorf("更新会话索引: %w", err)
	}
	return nil
}

// ErrWorkspaceNotFound 表示工作区在存储中不存在（可能已被删除）。
var ErrWorkspaceNotFound = errors.New("replay: 工作区不存在或已被删除")

// DeleteWorkspace 直接从 kimi 本地存储删除一个工作区：删除其 sessions/<wdID> 目录，
// 并从 session_index.jsonl 中移除所有 workDir 匹配的行。
//
// 不走 kimi web 的 HTTP 接口——kimi 的「移除工作区」只是软隐藏（从注册表移除、
// 不动磁盘；已实测 DELETE /workspaces/{id} 返回 deleted=true 但磁盘目录与索引行
// 原封不动），真正的删除必须由 relay 直接动存储（删目录 + 清索引），等价于在
// 文件管理器里删掉 sessions/<wdID>/ 目录并清理索引。这与会话删除（DeleteSession）
// 是同一套 direct-storage 机制，仅在匹配维度上从 sessionId 换成 workDir。
//
// 调用方必须在调用前确认没有 kimi web 实例在运行（单写者独占写锁），否则直接动
// 存储文件会与运行中的实例冲突（50001 storage write failed / 索引损坏）。
func DeleteWorkspace(kimiHome, workDir string) error {
	idx := filepath.Join(kimiHome, "session_index.jsonl")
	lines, err := readIndexLines(idx)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	target := filepath.Clean(workDir)
	// 用 workDir 定位该工作区在磁盘上的 sessions/<wdID>/ 目录：取任一会话的
	// sessionDir 父目录即可（sessionDir = <home>/sessions/<wdID>/session_<uuid>）。
	var wsDir string
	for _, line := range lines {
		var rec struct {
			SessionDir string `json:"sessionDir"`
			WorkDir    string `json:"workDir"`
		}
		if json.Unmarshal([]byte(line), &rec) == nil &&
			rec.WorkDir != "" && strings.EqualFold(filepath.Clean(rec.WorkDir), target) {
			if rec.SessionDir != "" {
				if d := filepath.Dir(filepath.Clean(rec.SessionDir)); d != "" {
					wsDir = d
					break
				}
			}
		}
	}
	if wsDir == "" {
		return fmt.Errorf("%w: %s", ErrWorkspaceNotFound, workDir)
	}
	if err := os.RemoveAll(wsDir); err != nil {
		return fmt.Errorf("删除工作区目录 %s: %w", wsDir, err)
	}
	if err := removeWorkspaceIndexEntries(kimiHome, target); err != nil {
		return fmt.Errorf("更新会话索引: %w", err)
	}
	return nil
}

// readIndexLines 读取 session_index.jsonl 的全部非空行（每行一个 JSON 对象）。
func readIndexLines(idx string) ([]string, error) {
	data, err := os.ReadFile(idx)
	if err != nil {
		return nil, err
	}
	var lines []string
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		if line := strings.TrimSpace(sc.Text()); line != "" {
			lines = append(lines, line)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return lines, nil
}

// removeWorkspaceIndexEntries 从 session_index.jsonl 中删除 workDir 匹配的行，其余原样保留。
// 索引文件不存在时视为无需处理。
func removeWorkspaceIndexEntries(kimiHome, workDir string) error {
	idx := filepath.Join(kimiHome, "session_index.jsonl")
	data, err := os.ReadFile(idx)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	target := filepath.Clean(workDir)
	var out []byte
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		var rec struct {
			WorkDir string `json:"workDir"`
		}
		skip := false
		if json.Unmarshal(line, &rec) == nil && rec.WorkDir != "" &&
			strings.EqualFold(filepath.Clean(rec.WorkDir), target) {
			skip = true
		}
		if skip {
			continue
		}
		out = append(out, line...)
		out = append(out, '\n')
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return os.WriteFile(idx, out, 0644)
}

// removeIndexEntry 从 session_index.jsonl 中删除 sessionId == sid 的行，其余原样保留。
// 索引文件不存在时视为无需处理（会话可能只存在于目录兜底路径）。
func removeIndexEntry(kimiHome, sid string) error {
	idx := filepath.Join(kimiHome, "session_index.jsonl")
	data, err := os.ReadFile(idx)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var out []byte
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		var rec struct {
			SessionID string `json:"sessionId"`
		}
		if json.Unmarshal(line, &rec) == nil && rec.SessionID == sid {
			continue // 跳过待删除行
		}
		out = append(out, line...)
		out = append(out, '\n')
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return os.WriteFile(idx, out, 0644)
}
