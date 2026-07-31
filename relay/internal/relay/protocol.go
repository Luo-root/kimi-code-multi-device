// Package relay 定义中继与端（手机/临时网页）之间的 WebSocket 协议。
// 设计取向：薄包装 + 透传。Kimi 的 session/update 原样塞进 session.update 的
// payload，端不依赖 ACP 细节也能渲染；中继自己的状态用独立 type。
package relay

import "encoding/json"

// Env 是上下行统一信封。Type 决定语义，SessionID 用于路由，Payload 是具体内容。
type Env struct {
	Type      string          `json:"type"`
	SessionID string          `json:"sessionId,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}

// 下行 type（中继 → 端）
const (
	DownSessionCreated = "session.created" // 新会话（含初始 configOptions）
	DownSessionUpdate  = "session.update"  // 透传 Kimi 的 update
	DownPermRequest    = "permission.request"
	DownRelayError     = "relay.error"
)

// 上行 type（端 → 中继）
const (
	UpNewSession   = "new_session"
	UpPrompt       = "prompt"
	UpCancel       = "cancel"
	UpPermDecision = "permission.decision"
	UpSetMode      = "set_mode"
	UpSetModel     = "set_model"
)

// ---- 上行 payload ----

type UpPromptPayload struct {
	Text string `json:"text"`
}
type UpPermDecisionPayload struct {
	// PermissionID 是 Kimi 的 request id，原样透传，类型无关（int/string 都行）。
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

// ---- 下行 payload ----

type DownPermRequestPayload struct {
	PermissionID json.RawMessage `json:"permissionId"`
	ToolCall     json.RawMessage `json:"toolCall"`
	Options      json.RawMessage `json:"options"`
}
type DownSessionCreatedPayload struct {
	ConfigOptions json.RawMessage `json:"configOptions"`
}
type DownRelayErrorPayload struct {
	Message string `json:"message"`
}
