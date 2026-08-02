// Package session 持有每会话的配置快照、cwd、流尾部环形缓冲，以及历史会话元信息缓存。
package session

import (
	"encoding/json"
	"sync"
)

const tailCap = 200

// SessionMeta 是 session/list 返回的一条历史会话元信息。
type SessionMeta struct {
	SessionID string `json:"sessionId"`
	CWD       string `json:"cwd"`
	Title     string `json:"title"`
	UpdatedAt string `json:"updatedAt"`
}

type sessState struct {
	config json.RawMessage
	cwd    string
	tail   []json.RawMessage
	busy   bool // session/prompt 进行中（AI 还在输出），驱动端「停」可见性
}

type Store struct {
	mu      sync.RWMutex
	m       map[string]*sessState
	history []SessionMeta
}

func New() *Store { return &Store{m: map[string]*sessState{}} }

func (s *Store) ensureLocked(sid string) *sessState {
	st, ok := s.m[sid]
	if !ok {
		st = &sessState{}
		s.m[sid] = st
	}
	return st
}

func (s *Store) SetConfig(sid string, config json.RawMessage) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureLocked(sid).config = config
}

func (s *Store) SetCWD(sid, cwd string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureLocked(sid).cwd = cwd
}

// SetBusy 标记某会话是否有 session/prompt 在进行。
func (s *Store) SetBusy(sid string, busy bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureLocked(sid).busy = busy
}

// Busy 返回某会话是否在跑。
func (s *Store) Busy(sid string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if st, ok := s.m[sid]; ok {
		return st.busy
	}
	return false
}

// BusySIDs 返回所有在跑的会话（供 snapshot 补发 busy）。
func (s *Store) BusySIDs() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []string
	for k, st := range s.m {
		if st.busy {
			out = append(out, k)
		}
	}
	return out
}

func (s *Store) AppendUpdate(sid string, update json.RawMessage) {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := s.ensureLocked(sid)
	st.tail = append(st.tail, update)
	if len(st.tail) > tailCap {
		st.tail = st.tail[len(st.tail)-tailCap:]
	}
}

func (s *Store) CWD(sid string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if st, ok := s.m[sid]; ok {
		return st.cwd
	}
	return ""
}

// Mode 解析该会话 configOptions 里的当前模式（default/plan/auto/yolo）。
// 缺失返回 default（manual），与 Kimi 默认一致。
func (s *Store) Mode(sid string) string {
	s.mu.RLock()
	cfg := s.m[sid].config
	s.mu.RUnlock()
	if len(cfg) == 0 {
		return "default"
	}
	var arr []struct {
		ID           string `json:"id"`
		CurrentValue string `json:"currentValue"`
	}
	if json.Unmarshal(cfg, &arr) != nil {
		return "default"
	}
	for _, c := range arr {
		if c.ID == "mode" && c.CurrentValue != "" {
			return c.CurrentValue
		}
	}
	return "default"
}

func (s *Store) Tail(sid string) []json.RawMessage {
	s.mu.RLock()
	defer s.mu.RUnlock()
	st, ok := s.m[sid]
	if !ok {
		return nil
	}
	out := make([]json.RawMessage, len(st.tail))
	copy(out, st.tail)
	return out
}

func (s *Store) SIDs() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]string, 0, len(s.m))
	for k := range s.m {
		out = append(out, k)
	}
	return out
}

// Has 报告该会话是否仍在中继活跃表（即 Kimi 侧已知或已成功恢复）。
// 用于上行 prompt 前的防御性校验，避免把失效 sid 透传给 Kimi 报 Unknown sessionId。
func (s *Store) Has(sid string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.m[sid]
	return ok
}

func (s *Store) Snapshot() map[string]json.RawMessage {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]json.RawMessage, len(s.m))
	for k, v := range s.m {
		out[k] = v.config
	}
	return out
}

// SetHistory 缓存 session/list 的结果（覆盖式）。
func (s *Store) SetHistory(h []SessionMeta) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.history = h
}

// History 返回历史元信息副本。
func (s *Store) History() []SessionMeta {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]SessionMeta, len(s.history))
	copy(out, s.history)
	return out
}

// Remove 移除一个活跃会话（端侧关闭后调用）。ta 与历史列表由 Kimi 侧真正删除。
func (s *Store) Remove(sid string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, sid)
}
