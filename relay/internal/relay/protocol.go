package relay

import (
	"encoding/json"

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
	DownSessionList    = "session.list" // 历史会话元信息列表
	DownRelayError     = "relay.error"
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
	UpListSessions = "list_sessions" // 拉取历史列表
	UpOpenHistory  = "open_history"  // 打开/恢复一个历史会话
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

// 下行 payload
type DownPermRequestPayload struct {
	PermissionID json.RawMessage `json:"permissionId"`
	ToolCall     json.RawMessage `json:"toolCall"`
	Options      json.RawMessage `json:"options"`
}
type DownSessionCreatedPayload struct {
	ConfigOptions json.RawMessage `json:"configOptions"`
	Resumed       bool            `json:"resumed,omitempty"` // true=历史会话经 resume 恢复，端应显示诚实卡
}
type DownSessionListPayload struct {
	Sessions []session.SessionMeta `json:"sessions"`
}
type DownRelayStatePayload struct {
	State string `json:"state"`
}
type DownRelayErrorPayload struct {
	Message string `json:"message"`
}
