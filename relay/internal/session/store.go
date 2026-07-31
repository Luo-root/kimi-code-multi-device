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
