package relay

import "encoding/json"

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
	DownPermInvalidate = "permission.invalidate" // kimi 崩溃：所有待批准作废
	DownRelayState     = "relay.state"           // ok / degraded
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
	UpDebugKill    = "debug_kill_kimi" // 仅开发期
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

// 下行 payload
type DownPermRequestPayload struct {
	PermissionID json.RawMessage `json:"permissionId"`
	ToolCall     json.RawMessage `json:"toolCall"`
	Options      json.RawMessage `json:"options"`
}
type DownSessionCreatedPayload struct {
	ConfigOptions json.RawMessage `json:"configOptions"`
}
type DownRelayStatePayload struct {
	State string `json:"state"` // "ok" | "degraded"
}
type DownRelayErrorPayload struct {
	Message string `json:"message"`
}
