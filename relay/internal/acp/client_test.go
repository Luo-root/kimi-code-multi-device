package acp

import (
	"encoding/json"
	"strings"
	"testing"
)

// 防回归：session/cancel 必须是无 id 的 notification。
// 实测 kimi 0.32.0：带 id 的 request 形式返回 -32601 Method not found，
// notification 形式才能中断当前轮（prompt 以 stopReason=cancelled 返回）。
func TestCancelNotificationHasNoID(t *testing.T) {
	m := rpcMsg{
		JSONRPC: "2.0",
		Method:  "session/cancel",
		Params:  json.RawMessage(`{"sessionId":"x"}`),
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(b), `"id"`) {
		t.Errorf("notification 不应携带 id 字段，序列化结果: %s", b)
	}
	if !strings.Contains(string(b), `"session/cancel"`) {
		t.Errorf("缺少方法名: %s", b)
	}
}
