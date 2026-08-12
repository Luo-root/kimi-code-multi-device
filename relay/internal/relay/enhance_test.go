package relay

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/Luo-root/kimi-code-multi-device/relay/internal/acp"
	acpsdk "github.com/coder/acp-go-sdk"
)

// enhanceFakeACP 在 Prompt 时通过注入的 stream 回调模拟 kimi 流式回写，
// 其余方法沿用 fakeACP 的空实现，便于验证 runEnhance 的「建会话→回读→下行」编排。
type enhanceFakeACP struct {
	*fakeACP
	stream func(sid string)
}

func (f *enhanceFakeACP) NewSession(ctx context.Context, cwd string) (acpsdk.SessionId, []acpsdk.SessionConfigOption, error) {
	f.fakeACP.NewSession(ctx, cwd)
	return acpsdk.SessionId("sess-fake"), nil, nil
}

func (f *enhanceFakeACP) Prompt(ctx context.Context, sid, text string, attachments []acp.PromptAttachment) error {
	if f.stream != nil {
		f.stream(sid)
	}
	return nil
}

func TestRunEnhance_Success(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.kimiAlive = true
	fake := &enhanceFakeACP{fakeACP: &fakeACP{}}
	fake.stream = func(sid string) {
		// 模拟 kimi 把优化结果以 assistant_message_chunk 累积流出。
		// 文本真实嵌套在 content.text（与 Flutter _chunkText 同源），不是扁平 text。
		r.onUpdate(sid, json.RawMessage(`{"sessionUpdate":"assistant_message_chunk","content":{"text":"优化后的","append":true}}`))
		r.onUpdate(sid, json.RawMessage(`{"sessionUpdate":"assistant_message_chunk","content":{"text":"提示词","append":true}}`))
	}
	r.acp = fake

	r.runEnhance("active-sid", "原始提示词")

	e := recvDown(t, capCh, DownEnhance)
	var p DownEnhancePayload
	if err := json.Unmarshal(e.Payload, &p); err != nil {
		t.Fatalf("payload 解析失败: %v", err)
	}
	if p.Error != "" {
		t.Fatalf("不应有错误: %s", p.Error)
	}
	if p.Original != "原始提示词" {
		t.Fatalf("Original 不符: %q", p.Original)
	}
	if p.Enhanced != "优化后的提示词" {
		t.Fatalf("Enhanced 不符: %q", p.Enhanced)
	}
}

func TestRunEnhance_KimiDown(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.kimiAlive = false
	r.acp = &enhanceFakeACP{fakeACP: &fakeACP{}}

	r.runEnhance("active-sid", "原始提示词")

	e := recvDown(t, capCh, DownEnhance)
	var p DownEnhancePayload
	_ = json.Unmarshal(e.Payload, &p)
	if p.Error == "" {
		t.Fatalf("kimi 离线应返回错误")
	}
}

func TestRunEnhance_EmptyText(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.kimiAlive = true
	r.acp = &enhanceFakeACP{fakeACP: &fakeACP{}}

	r.runEnhance("active-sid", "   ")

	e := recvDown(t, capCh, DownEnhance)
	var p DownEnhancePayload
	_ = json.Unmarshal(e.Payload, &p)
	if p.Error == "" {
		t.Fatalf("空文本应报错")
	}
}

func TestExtractEnhanced(t *testing.T) {
	updates := []json.RawMessage{
		// 真实 kimi 文本嵌套在 content.text。
		json.RawMessage(`{"sessionUpdate":"agent_message_chunk","content":{"text":"（思考过程）"}}`),
		json.RawMessage(`{"sessionUpdate":"assistant_message_chunk","content":{"text":"更清晰"}}`),
		json.RawMessage(`{"sessionUpdate":"assistant_message_chunk","content":{"text":"的提示词"}}`),
	}
	if got := extractEnhanced(updates); got != "更清晰的提示词" {
		t.Fatalf("extractEnhanced 不符: %q", got)
	}
	// 仅有 agent_message_chunk（真实最终回答臂）时也能正确提取。
	agentOnly := []json.RawMessage{
		json.RawMessage(`{"sessionUpdate":"agent_message_chunk","content":{"text":"回退文本"}}`),
	}
	if got := extractEnhanced(agentOnly); got != "回退文本" {
		t.Fatalf("extractEnhanced agent 提取不符: %q", got)
	}
}
