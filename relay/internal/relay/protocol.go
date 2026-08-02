package relay

import (
	"encoding/json"

	"github.com/Luo-root/kimi-code-multi-device/relay/internal/replay"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/session"
)

type Env struct {
	Type      string          `json:"type"`
	SessionID string          `json:"sessionId,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}

// 下行 type
const (
	DownSessionCreated = "session.created"
	DownSessionUpdate  = "session.update"
	DownPermRequest    = "permission.request"
	DownPermInvalidate = "permission.invalidate"
	DownRelayState     = "relay.state"
	DownSessionList    = "session.list"
	DownSessionHistory = "session.history" // 历史回放内容块
	DownRelayError     = "relay.error"
	DownSessionBusy    = "session.busy"   // 该会话是否有 prompt 进行中（驱动「停」）
	DownSessionClosed  = "session.closed" // 某活跃会话被关闭，端侧移除 tab
)

// 上行 type
const (
	UpNewSession   = "new_session"
	UpPrompt       = "prompt"
	UpCancel       = "cancel"
	UpPermDecision = "permission.decision"
	UpSetMode      = "set_mode"
	UpSetModel     = "set_model"
	UpRestartKimi  = "restart_kimi"
	UpDebugKill    = "debug_kill_kimi"
	UpListSessions = "list_sessions"
	UpOpenHistory  = "open_history"
	UpCloseSession = "close_session"
)

// 上行 payload
type UpPromptPayload struct {
	Text string `json:"text"`
}
type UpPermDecisionPayload struct {
	PermissionID json.RawMessage `json:"permissionId"`
	OptionID     string          `json:"optionId"`
}
type UpSetModePayload struct {
	ModeID string `json:"modeId"`
}
type UpSetModelPayload struct {
	Value string `json:"value"`
}
type UpNewSessionPayload struct {
	CWD string `json:"cwd,omitempty"`
}
type UpOpenHistoryPayload struct {
	SessionID string `json:"sessionId"`
	CWD       string `json:"cwd"`
}

// DownPermRequestPayload 下行 payload
type DownPermRequestPayload struct {
	PermissionID json.RawMessage `json:"permissionId"`
	ToolCall     json.RawMessage `json:"toolCall"`
	Options      json.RawMessage `json:"options"`
	DeadlineMs   int64           `json:"deadlineMs,omitempty"` // 超时截止（ms），端据此倒计时
	Critical     bool            `json:"critical,omitempty"`   // §10 3.4 命中关键命令清单
}
type DownSessionCreatedPayload struct {
	ConfigOptions json.RawMessage `json:"configOptions"`
	Resumed       bool            `json:"resumed,omitempty"`
}
type DownSessionListPayload struct {
	Sessions []session.SessionMeta `json:"sessions"`
}
type DownSessionHistoryPayload struct {
	Blocks []replay.Block `json:"blocks"`
	Title  string         `json:"title,omitempty"`
	Count  int            `json:"count"`
}
type DownRelayStatePayload struct {
	State string `json:"state"`
}
type DownSessionBusyPayload struct {
	Busy bool `json:"busy"`
}
type DownRelayErrorPayload struct {
	Message string `json:"message"`
}
