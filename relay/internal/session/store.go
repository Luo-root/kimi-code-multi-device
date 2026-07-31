// Package session 持有每会话的配置快照、cwd、流尾部环形缓冲。
package session

import (
	"encoding/json"
	"sync"
)

const tailCap = 200 // 每会话缓存最近 N 条 update，供重连/恢复补发

type sessState struct {
	config json.RawMessage
	cwd    string
	tail   []json.RawMessage
}

type Store struct {
	mu sync.RWMutex
	m  map[string]*sessState
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

// AppendUpdate 追加一条 update 到环形缓冲（onUpdate 热路径，持写锁，开发期可接受）。
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

// Tail 返回 sid 的流尾部副本。
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

// Snapshot 返回 sid->config 副本，供新连接补发 created。
func (s *Store) Snapshot() map[string]json.RawMessage {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]json.RawMessage, len(s.m))
	for k, v := range s.m {
		out[k] = v.config
	}
	return out
}
