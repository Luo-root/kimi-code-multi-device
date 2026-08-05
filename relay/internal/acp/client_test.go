package acp

import (
	"encoding/json"
	"strings"
	"testing"

	acpsdk "github.com/coder/acp-go-sdk"
)

// 防回归：session/cancel 必须是无 id 的 notification。
// 实测 kimi 0.32.0：带 id 的 request 形式返回 -32601 Method not found，
// notification 形式才能中断当前轮（prompt 以 stopReason=cancelled 返回）。
func TestCancelNotificationHasNoID(t *testing.T) {
	b, err := json.Marshal(acpsdk.CancelNotification{SessionId: acpsdk.SessionId("x")})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(b)
	if strings.Contains(s, `"id"`) {
		t.Errorf("CancelNotification 序列化不应含 id 字段: %s", s)
	}
	if !strings.Contains(s, `"sessionId"`) {
		t.Errorf("CancelNotification 应含 sessionId: %s", s)
	}
}

// relayClient 必须实现 acp.Client 接口；此测试在编译期锁定该契约，
// 一旦 SDK 的 Client 接口变更（新增方法）即可立即发现。
func TestRelayClientImplementsACPClient(t *testing.T) {
	var _ acpsdk.Client = (*relayClient)(nil)
	_ = relayClient{}
}

// ConfigOptionsToRaw 必须保留 id / currentValue / type，使 store.Mode() 解析兼容。
func TestConfigOptionsToRawPreservesFields(t *testing.T) {
	// 模拟 kimi 真实下发的 mode 选项（options 为 name/value 对象数组，ACP 规范形态）。
	opts := []acpsdk.SessionConfigOption{
		{Select: &acpsdk.SessionConfigOptionSelect{
			Id:           acpsdk.SessionConfigId("mode"),
			CurrentValue: acpsdk.SessionConfigValueId("auto"),
			Type:         "select",
			Name:         "Mode",
			Options: acpsdk.SessionConfigSelectOptions{
				Ungrouped: &acpsdk.SessionConfigSelectOptionsUngrouped{
					{Name: "YOLO", Value: "yolo"},
					{Name: "Auto", Value: "auto"},
					{Name: "Plan", Value: "plan"},
				},
			},
		}},
	}
	raw := ConfigOptionsToRaw(opts)
	s := string(raw)
	if !strings.Contains(s, `"id":"mode"`) {
		t.Errorf("缺少 id 字段: %s", s)
	}
	if !strings.Contains(s, `"currentValue":"auto"`) {
		t.Errorf("缺少 currentValue 字段: %s", s)
	}
	if !strings.Contains(s, `"type":"select"`) {
		t.Errorf("缺少 type 字段: %s", s)
	}
}

// ConfigOptionsToRaw 在 options 为空（union 子类型 marshal 退化）时应兜底，不丢 id/type。
func TestConfigOptionsToRawEmptyOptionsFallback(t *testing.T) {
	opts := []acpsdk.SessionConfigOption{
		{Select: &acpsdk.SessionConfigOptionSelect{
			Id:           acpsdk.SessionConfigId("mode"),
			CurrentValue: acpsdk.SessionConfigValueId("auto"),
			Type:         "select",
			Name:         "Mode",
		}},
	}
	raw := ConfigOptionsToRaw(opts)
	s := string(raw)
	if s == "[]" || s == "null" {
		t.Fatalf("空 options 不应退化为空数组: %s", s)
	}
	if !strings.Contains(s, `"id":"mode"`) {
		t.Errorf("兜底仍应保留 id 字段: %s", s)
	}
	if !strings.Contains(s, `"type":"select"`) {
		t.Errorf("兜底仍应保留 type 字段: %s", s)
	}
}
