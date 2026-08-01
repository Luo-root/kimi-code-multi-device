// Package permit 是 §08 ③ 许可裁决器的超时部分：按 ACP request id 追踪待批准，
// 到期未决则触发回调（由中继回 reject/allow + 广播 + 门铃）。
//
// 设计要点：
//   - kimi 的 request_permission 同步阻塞，一条 id 在任一时刻只对应一个未决许可。
//   - manual 模式注册定时器；yolo/auto 由中继直接 allow，不经此注册。
//   - kimi 崩溃（OnExit）时 InvalidateAll：进程已没，无法 respond，只清定时器。
package permit

import (
	"encoding/json"
	"sync"
	"time"
)

// Pending 是一条待批准许可。
type Pending struct {
	SID      string
	ID       json.RawMessage
	Deadline time.Time
	Critical bool
	timer    *time.Timer
}

// TimeoutFn 在超时触发时回调：中继据此 respond + 广播 + 门铃。
type TimeoutFn func(sid string, id json.RawMessage, critical bool)

// Manager 管理所有未决许可的定时器。
type Manager struct {
	mu        sync.Mutex
	pending   map[string]*Pending // key = string(id)
	onTimeout TimeoutFn
}

func New(onTimeout TimeoutFn) *Manager {
	return &Manager{
		pending:   map[string]*Pending{},
		onTimeout: onTimeout,
	}
}

// keyOf 把 json.RawMessage 转成稳定字符串键。
func keyOf(id json.RawMessage) string {
	return string(id)
}

// Register 记录一条待批准并启动超时定时器。
func (m *Manager) Register(sid string, id json.RawMessage, deadline time.Time, critical bool) {
	k := keyOf(id)
	p := &Pending{
		SID:      sid,
		ID:       id,
		Deadline: deadline,
		Critical: critical,
	}
	// 清理同 id 旧条目（不应发生，但防串味）——在锁内完成。
	m.mu.Lock()
	if old, ok := m.pending[k]; ok && old.timer != nil {
		old.timer.Stop()
	}
	m.pending[k] = p
	m.mu.Unlock()
	dur := time.Until(deadline)
	if dur < 0 {
		dur = 0
	}
	p.timer = time.AfterFunc(dur, func() {
		m.mu.Lock()
		// 仍在册且仍是本条才触发（可能已被 Resolve 取消或替换）。
		cur, ok := m.pending[k]
		if !ok || cur != p {
			m.mu.Unlock()
			return
		}
		delete(m.pending, k)
		m.mu.Unlock()
		if m.onTimeout != nil {
			m.onTimeout(sid, id, critical)
		}
	})
}

// Resolve 取消并移除一条许可（用户已拍板）。返回是否命中（命中=true 说明尚未超时）。
func (m *Manager) Resolve(id json.RawMessage) bool {
	k := keyOf(id)
	m.mu.Lock()
	p, ok := m.pending[k]
	if ok {
		delete(m.pending, k)
	}
	m.mu.Unlock()
	if ok && p.timer != nil {
		p.timer.Stop()
	}
	return ok
}

// InvalidateAll 清空所有待批准（kimi 崩溃：进程没了，respond 无意义，只清定时器）。
func (m *Manager) InvalidateAll() {
	m.mu.Lock()
	for k, p := range m.pending {
		if p.timer != nil {
			p.timer.Stop()
		}
		delete(m.pending, k)
	}
	m.mu.Unlock()
}

// PendingCount 返回当前未决许可数（供状态/调试）。
func (m *Manager) PendingCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.pending)
}
