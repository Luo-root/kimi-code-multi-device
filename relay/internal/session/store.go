// Package session 持有"每个会话的最新配置快照"，用于新端连上来时补发当前状态
// （连续性：连上来不该看到一片空白）。这一刀只存 configOptions；流尾部、待批准
// 队列的快照后续加持久化时再补。
package session

import (
	"encoding/json"
	"sync"
)

type Store struct {
	mu sync.RWMutex
	m  map[string]json.RawMessage // sid -> 最新 configOptions
}

func New() *Store { return &Store{m: map[string]json.RawMessage{}} }

func (s *Store) Set(sid string, configOptions json.RawMessage) {
	s.mu.Lock()
	s.m[sid] = configOptions
	s.mu.Unlock()
}

// Snapshot 返回 sid->configOptions 的副本，供新连接补发。
func (s *Store) Snapshot() map[string]json.RawMessage {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]json.RawMessage, len(s.m))
	for k, v := range s.m {
		out[k] = v
	}
	return out
}
