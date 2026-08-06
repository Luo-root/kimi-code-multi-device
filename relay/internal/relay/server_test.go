package relay

import (
	"context"
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Luo-root/kimi-code-multi-device/relay/internal/bark"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/config"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/kimiweb"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/permit"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/session"
	acpsdk "github.com/coder/acp-go-sdk"
)

// ---- 测试辅助 ----

// newTestRelay 构造一个不依赖真实 kimi 子进程的 Relay，并挂一个捕获广播的伪客户端。
// bark 用空 URL（静默，不触网）；permTimeout 默认给足时间，超时类测试自行调小。
func newTestRelay(t *testing.T) (*Relay, chan []byte) {
	t.Helper()
	r := &Relay{
		store:               session.New(),
		bark:                bark.New(""), // 未配置：Notify 静默，无网络
		permTimeout:         5 * time.Second,
		autoPassNonCritical: false,
		permWaiters:         map[string]chan permOutcome{},
		clients:             map[*client]bool{},
		cfg:                 &config.Config{},
		cfgPath:             "",
	}
	r.permit = permit.New(r.onPermTimeout)
	capCh := make(chan []byte, 64)
	c := &client{send: capCh}
	r.mu.Lock()
	r.clients[c] = true
	r.mu.Unlock()
	return r, capCh
}

// setMode 给会话写入 config（id=mode），供 onPermission 读取模式分支。
func setMode(r *Relay, sid, mode string) {
	cfg := json.RawMessage(`[{"id":"mode","currentValue":` + strconv.Quote(mode) + `}]`)
	r.store.SetConfig(sid, cfg)
}

// waitFor 轮询直到条件为真或超时（用于等待 handleUp 起的 goroutine 落定）。
func waitFor(t *testing.T, d time.Duration, fn func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(d)
	for !fn() {
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(5 * time.Millisecond)
	}
	return true
}

// recvDown 从捕获通道取出下一条并解析为 Env（带类型断言）。
func recvDown(t *testing.T, capCh chan []byte, wantType string) Env {
	t.Helper()
	select {
	case b := <-capCh:
		var e Env
		if err := json.Unmarshal(b, &e); err != nil {
			t.Fatalf("广播解析失败: %v", err)
		}
		if e.Type != wantType {
			t.Fatalf("期望广播 %s，实际 %s", wantType, e.Type)
		}
		return e
	case <-time.After(3 * time.Second):
		t.Fatalf("超时未收到广播 %s", wantType)
		return Env{}
	}
}

// ---- fake acpClient ----

// fakeACP 是 acpClient 的内存实现，记录调用以便断言；不触网、不拉子进程。
type fakeACP struct {
	mu        sync.Mutex
	calls     []string
	promptErr error
}

func (f *fakeACP) Initialize(ctx context.Context) (acpsdk.InitializeResponse, error) {
	f.mu.Lock()
	f.calls = append(f.calls, "Initialize")
	f.mu.Unlock()
	return acpsdk.InitializeResponse{}, nil
}
func (f *fakeACP) Authenticate(ctx context.Context, req acpsdk.AuthenticateRequest) (acpsdk.AuthenticateResponse, error) {
	f.mu.Lock()
	f.calls = append(f.calls, "Authenticate")
	f.mu.Unlock()
	return acpsdk.AuthenticateResponse{}, nil
}
func (f *fakeACP) NewSession(ctx context.Context, cwd string) (acpsdk.SessionId, []acpsdk.SessionConfigOption, error) {
	f.mu.Lock()
	f.calls = append(f.calls, "NewSession:"+cwd)
	f.mu.Unlock()
	return acpsdk.SessionId("sess-fake"), nil, nil
}
func (f *fakeACP) ListSessions(ctx context.Context) ([]acpsdk.SessionInfo, error) {
	f.mu.Lock()
	f.calls = append(f.calls, "ListSessions")
	f.mu.Unlock()
	return nil, nil
}
func (f *fakeACP) ResumeSession(ctx context.Context, sid, cwd string) ([]acpsdk.SessionConfigOption, error) {
	f.mu.Lock()
	f.calls = append(f.calls, "ResumeSession:"+sid)
	f.mu.Unlock()
	return nil, nil
}
func (f *fakeACP) Prompt(ctx context.Context, sid, text string) error {
	f.mu.Lock()
	f.calls = append(f.calls, "Prompt:"+sid)
	err := f.promptErr
	f.mu.Unlock()
	return err
}
func (f *fakeACP) Cancel(ctx context.Context, sid string) error {
	f.mu.Lock()
	f.calls = append(f.calls, "Cancel:"+sid)
	f.mu.Unlock()
	return nil
}
func (f *fakeACP) SetMode(ctx context.Context, sid, modeID string) error {
	f.mu.Lock()
	f.calls = append(f.calls, "SetMode:"+sid+":"+modeID)
	f.mu.Unlock()
	return nil
}
func (f *fakeACP) SetConfigOption(ctx context.Context, sid, configID, value string) error {
	f.mu.Lock()
	f.calls = append(f.calls, "SetConfigOption:"+sid+":"+configID+"="+value)
	f.mu.Unlock()
	return nil
}
func (f *fakeACP) Restart() error {
	f.mu.Lock()
	f.calls = append(f.calls, "Restart")
	f.mu.Unlock()
	return nil
}
func (f *fakeACP) DebugKill() {
	f.mu.Lock()
	f.calls = append(f.calls, "DebugKill")
	f.mu.Unlock()
}
func (f *fakeACP) Close() {
	f.mu.Lock()
	f.calls = append(f.calls, "Close")
	f.mu.Unlock()
}

func (f *fakeACP) has(call string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.calls {
		if c == call {
			return true
		}
	}
	return false
}

// ---- 权限流：模式分支 ----

func TestOnPermission_Modes(t *testing.T) {
	cases := []struct {
		name     string
		mode     string // 设定的会话模式
		wantOpt  string // 期望的 optionId
		blocking bool   // 是否进入 manual 阻塞（需外部拍板）
	}{
		{"yolo", "yolo", "approve_once", false},
		{"auto", "auto", "approve_once", false},
		{"plan", "plan", "reject", false},
		{"default→manual", "default", "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, capCh := newTestRelay(t)
			const sid = "sess-1"
			if tc.mode != "" {
				setMode(r, sid, tc.mode)
			} else {
				// default：无 config，store.Mode 返回 "default" → manual
			}

			req := acpsdk.RequestPermissionRequest{
				SessionId: acpsdk.SessionId(sid),
				ToolCall:  acpsdk.ToolCallUpdate{RawInput: map[string]any{"command": "ls -la"}},
			}
			resCh := make(chan acpsdk.RequestPermissionResponse, 1)
			errCh := make(chan error, 1)
			go func() {
				resp, err := r.onPermission(context.Background(), req)
				resCh <- resp
				errCh <- err
			}()

			if !tc.blocking {
				select {
				case resp := <-resCh:
					if resp.Outcome.Selected == nil || string(resp.Outcome.Selected.OptionId) != tc.wantOpt {
						t.Fatalf("模式 %s 期望 %s，实际 %+v", tc.mode, tc.wantOpt, resp)
					}
				case <-time.After(2 * time.Second):
					t.Fatalf("模式 %s 未立即返回", tc.mode)
				}
				return
			}

			// manual：应阻塞并广播 DownPermRequest，随后由端侧拍板 approve_once。
			e := recvDown(t, capCh, DownPermRequest)
			var p DownPermRequestPayload
			_ = json.Unmarshal(e.Payload, &p)
			if len(p.PermissionID) == 0 {
				t.Fatal("DownPermRequest 缺少 permissionId")
			}
			go func() {
				b, _ := json.Marshal(Env{
					Type:      UpPermDecision,
					SessionID: sid,
					Payload:   mustJSON(UpPermDecisionPayload{PermissionID: p.PermissionID, OptionID: "approve_once"}),
				})
				r.handleUp(&client{send: make(chan []byte, 1)}, b)
			}()
			select {
			case resp := <-resCh:
				if resp.Outcome.Selected == nil || string(resp.Outcome.Selected.OptionId) != "approve_once" {
					t.Fatalf("manual 拍板后期望 approve_once，实际 %+v", resp)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("manual 阻塞后未随拍板返回")
			}
		})
	}
}

// ---- 权限流：超时（manual + critical → reject） ----

func TestOnPermission_Manual_TimeoutReject(t *testing.T) {
	r, _ := newTestRelay(t)
	r.permTimeout = 30 * time.Millisecond // 极短超时
	const sid = "sess-1"
	setMode(r, sid, "manual") // 显式 manual

	req := acpsdk.RequestPermissionRequest{
		SessionId: acpsdk.SessionId(sid),
		ToolCall:  acpsdk.ToolCallUpdate{RawInput: map[string]any{"command": "rm -rf /tmp/x"}}, // 关键命令
	}
	resCh := make(chan acpsdk.RequestPermissionResponse, 1)
	errCh := make(chan error, 1)
	go func() {
		resp, err := r.onPermission(context.Background(), req)
		resCh <- resp
		errCh <- err
	}()

	select {
	case resp := <-resCh:
		if resp.Outcome.Selected == nil || string(resp.Outcome.Selected.OptionId) != "reject" {
			t.Fatalf("超时关键命令期望 reject，实际 %+v", resp)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("超时未返回")
	}
}

// ---- 权限流：超时（manual + 非关键 + 自动放行开关 → approve_once） ----

func TestOnPermission_Manual_TimeoutAutoPass(t *testing.T) {
	r, _ := newTestRelay(t)
	r.permTimeout = 30 * time.Millisecond
	r.autoPassNonCritical = true
	const sid = "sess-1"
	setMode(r, sid, "manual")

	req := acpsdk.RequestPermissionRequest{
		SessionId: acpsdk.SessionId(sid),
		ToolCall:  acpsdk.ToolCallUpdate{RawInput: map[string]any{"command": "ls -la"}}, // 非关键
	}
	resCh := make(chan acpsdk.RequestPermissionResponse, 1)
	errCh := make(chan error, 1)
	go func() {
		resp, err := r.onPermission(context.Background(), req)
		resCh <- resp
		errCh <- err
	}()

	select {
	case resp := <-resCh:
		if resp.Outcome.Selected == nil || string(resp.Outcome.Selected.OptionId) != "approve_once" {
			t.Fatalf("超时非关键+自动放行期望 approve_once，实际 %+v", resp)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("超时未返回")
	}
}

// ---- 权限流：kimi 退出唤醒阻塞的 OnPermission（cancelled） ----

func TestOnPermission_Manual_KimiExit(t *testing.T) {
	r, capCh := newTestRelay(t)
	const sid = "sess-1"
	setMode(r, sid, "manual")

	req := acpsdk.RequestPermissionRequest{
		SessionId: acpsdk.SessionId(sid),
		ToolCall:  acpsdk.ToolCallUpdate{RawInput: map[string]any{"command": "ls -la"}},
	}
	resCh := make(chan acpsdk.RequestPermissionResponse, 1)
	errCh := make(chan error, 1)
	go func() {
		resp, err := r.onPermission(context.Background(), req)
		resCh <- resp
		errCh <- err
	}()

	// 等 onPermission 完成 waiter 挂号（DownPermRequest 广播发生在注册之后），
	// 避免 onKimiExit 早于挂号、漏唤醒导致 goroutine 永久挂起。
	recvDown(t, capCh, DownPermRequest)

	// 模拟 kimi 崩溃：解除所有阻塞的 OnPermission。
	r.onKimiExit()

	select {
	case resp := <-resCh:
		if resp.Outcome.Cancelled == nil || resp.Outcome.Cancelled.Outcome != "cancelled" {
			t.Fatalf("kimi 退出期望 cancelled，实际 %+v", resp)
		}
		if err := <-errCh; err != nil {
			t.Fatalf("kimi 退出不应带 error，实际 %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("kimi 退出后 OnPermission 未返回")
	}
	if r.kimiAlive {
		t.Fatal("onKimiExit 应将 kimiAlive 置为 false")
	}
}

// ---- 权限流：超时后的迟到决定应被忽略（不重复投递、不 panic） ----

func TestOnPermission_Manual_LateDecisionIgnored(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.permTimeout = 30 * time.Millisecond
	const sid = "sess-1"
	setMode(r, sid, "manual")

	req := acpsdk.RequestPermissionRequest{
		SessionId: acpsdk.SessionId(sid),
		ToolCall:  acpsdk.ToolCallUpdate{RawInput: map[string]any{"command": "rm -rf /tmp/x"}},
	}
	resCh := make(chan acpsdk.RequestPermissionResponse, 1)
	go func() {
		resp, _ := r.onPermission(context.Background(), req)
		resCh <- resp
	}()

	// 捕获注册时下发的 permID（超时前）。
	e := recvDown(t, capCh, DownPermRequest)
	var p DownPermRequestPayload
	_ = json.Unmarshal(e.Payload, &p)

	// 等超时自然返回（reject）。
	select {
	case <-resCh:
	case <-time.After(2 * time.Second):
		t.Fatal("超时未返回")
	}

	// 超时后才回传决定：应被忽略（permit.Resolve 返回 false，deliverPermission 无 waiter）。
	b, _ := json.Marshal(Env{
		Type:      UpPermDecision,
		SessionID: sid,
		Payload:   mustJSON(UpPermDecisionPayload{PermissionID: p.PermissionID, OptionID: "approve_once"}),
	})
	r.handleUp(&client{send: make(chan []byte, 1)}, b)

	if n := r.permit.PendingCount(); n != 0 {
		t.Fatalf("迟到决定处理后仍有 %d 条 pending", n)
	}
}

// ---- deliverPermission：无 waiter 时安全 no-op ----

func TestDeliverPermission_NoWaiter(t *testing.T) {
	r, _ := newTestRelay(t)
	// 不应 panic，也不应阻塞。
	r.deliverPermission(json.RawMessage(`"perm-nope"`), permResponse("approve_once"))
}

// ---- onUpdate：config_option_update 应更新 store 配置并追加 tail ----

func TestOnUpdate_ConfigOptionUpdate(t *testing.T) {
	r, capCh := newTestRelay(t)
	const sid = "sess-1"
	update := json.RawMessage(`{"sessionUpdate":"config_option_update","configOptions":[{"id":"mode","currentValue":"yolo"}]}`)
	r.onUpdate(sid, update)

	got := r.store.Snapshot()[sid]
	if !strings.Contains(string(got), `"currentValue":"yolo"`) {
		t.Fatalf("store 配置未更新为 yolo：%s", string(got))
	}
	if len(r.store.Tail(sid)) != 1 {
		t.Fatalf("tail 未追加 update")
	}
	recvDown(t, capCh, DownSessionUpdate)
}

// ---- 纯函数：extractCommand / stripCmdPrefix ----

func TestExtractCommand(t *testing.T) {
	// extractCommand 直接解析 toolCall 原始 JSON，这里用原始 JSON 直测解析逻辑，
	// 避免依赖 SDK 结构体的 marshal 形态。
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{"running_prefix", `{"rawInput":{"command":"Running: rm -rf /tmp/x"}}`, "rm -rf /tmp/x"},
		{"requesting_prefix", `{"rawInput":{"command":"Requesting approval to Running: git push -f"}}`, "git push -f"},
		{"content_text", `{"content":[{"content":{"text":"ls -la"}}]}`, "ls -la"},
		{"empty", `{}`, ""},
		{"empty_command", `{"rawInput":{"command":""}}`, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := extractCommand(json.RawMessage(tc.raw)); got != tc.want {
				t.Fatalf("extractCommand=%q，期望 %q", got, tc.want)
			}
		})
	}
}

func TestStripCmdPrefix(t *testing.T) {
	cases := []struct{ in, want string }{
		{"Running: foo", "foo"},
		{"Requesting approval to Running: bar", "bar"},
		{"plain cmd", "plain cmd"},
	}
	for _, tc := range cases {
		if got := stripCmdPrefix(tc.in); got != tc.want {
			t.Fatalf("stripCmdPrefix(%q)=%q，期望 %q", tc.in, got, tc.want)
		}
	}
}

// ---- handleUp 上行分发（fake acpClient 注入） ----

func TestHandleUp_SetMode(t *testing.T) {
	r, _ := newTestRelay(t)
	f := &fakeACP{}
	r.acp = f
	const sid = "sess-1"
	r.store.SetCWD(sid, "/tmp")

	b, _ := json.Marshal(Env{Type: UpSetMode, SessionID: sid, Payload: mustJSON(UpSetModePayload{ModeID: "plan"})})
	r.handleUp(&client{send: make(chan []byte, 1)}, b)

	if !waitFor(t, 2*time.Second, func() bool { return f.has("SetMode:" + sid + ":plan") }) {
		t.Fatalf("SetMode 未被调用；calls=%v", f.calls)
	}
}

func TestHandleUp_SetModel(t *testing.T) {
	r, _ := newTestRelay(t)
	f := &fakeACP{}
	r.acp = f
	const sid = "sess-1"
	r.store.SetCWD(sid, "/tmp")

	b, _ := json.Marshal(Env{Type: UpSetModel, SessionID: sid, Payload: mustJSON(UpSetModelPayload{Value: "kimi-k2"})})
	r.handleUp(&client{send: make(chan []byte, 1)}, b)

	if !waitFor(t, 2*time.Second, func() bool { return f.has("SetConfigOption:" + sid + ":model=kimi-k2") }) {
		t.Fatalf("SetConfigOption(model) 未被调用；calls=%v", f.calls)
	}
}

func TestHandleUp_Cancel(t *testing.T) {
	r, _ := newTestRelay(t)
	f := &fakeACP{}
	r.acp = f
	const sid = "sess-1"
	r.store.SetCWD(sid, "/tmp")

	b, _ := json.Marshal(Env{Type: UpCancel, SessionID: sid})
	r.handleUp(&client{send: make(chan []byte, 1)}, b)

	if !waitFor(t, 2*time.Second, func() bool { return f.has("Cancel:" + sid) }) {
		t.Fatalf("Cancel 未被调用；calls=%v", f.calls)
	}
}

func TestHandleUp_CloseSession(t *testing.T) {
	r, capCh := newTestRelay(t)
	const sid = "sess-1"
	r.store.SetCWD(sid, "/tmp")
	if !r.store.Has(sid) {
		t.Fatal("前置：会话应存在")
	}

	b, _ := json.Marshal(Env{Type: UpCloseSession, SessionID: sid})
	r.handleUp(&client{send: make(chan []byte, 1)}, b)

	if !waitFor(t, 2*time.Second, func() bool { return !r.store.Has(sid) }) {
		t.Fatal("CloseSession 后会话未从活跃表移除")
	}
	recvDown(t, capCh, DownSessionClosed)
}

func TestHandleUp_Prompt(t *testing.T) {
	r, _ := newTestRelay(t)
	f := &fakeACP{}
	r.acp = f
	const sid = "sess-1"
	r.store.SetCWD(sid, "/tmp")

	b, _ := json.Marshal(Env{Type: UpPrompt, SessionID: sid, Payload: mustJSON(UpPromptPayload{Text: "hello"})})
	r.handleUp(&client{send: make(chan []byte, 1)}, b)

	if !waitFor(t, 2*time.Second, func() bool { return f.has("Prompt:" + sid) }) {
		t.Fatalf("Prompt 未被调用；calls=%v", f.calls)
	}
	// busy 应在跑完（fake 立即返回）后复位。
	if !waitFor(t, 2*time.Second, func() bool { return !r.store.Busy(sid) }) {
		t.Fatal("Prompt 完成后 busy 未复位")
	}
}

func TestHandleUp_ConfigSet(t *testing.T) {
	r, _ := newTestRelay(t)
	tmp, err := os.CreateTemp(t.TempDir(), "relay-*.toml")
	if err != nil {
		t.Fatalf("建临时配置失败: %v", err)
	}
	// CreateTemp 返回的是已打开的句柄，本测试只用路径，立即关闭以免 Windows 清理时锁文件。
	if err := tmp.Close(); err != nil {
		t.Fatalf("关闭临时配置失败: %v", err)
	}
	r.cfgPath = tmp.Name()
	newTimeout := 123
	b, _ := json.Marshal(Env{Type: UpConfigSet, Payload: mustJSON(UpConfigSetPayload{PermTimeoutSeconds: &newTimeout})})
	r.handleUp(&client{send: make(chan []byte, 1)}, b)

	if !waitFor(t, 2*time.Second, func() bool { return r.cfg.Permission.TimeoutSeconds == newTimeout }) {
		t.Fatalf("config.set 未更新内存配置；got=%d", r.cfg.Permission.TimeoutSeconds)
	}
	// 热切换应同步到运行期字段。
	r.cfgMu.RLock()
	pt := r.permTimeout
	r.cfgMu.RUnlock()
	if pt != time.Duration(newTimeout)*time.Second {
		t.Fatalf("permTimeout 热切换未生效；got=%v", pt)
	}
	// 应已写回文件。
	if data, err := os.ReadFile(tmp.Name()); err != nil || !strings.Contains(string(data), "timeout_seconds") {
		t.Fatalf("config.set 未写回文件: err=%v data=%q", err, string(data))
	}
}

// ---- fake managementClient（T3 管理协议测试） ----

type fakeMgmt struct {
	mu         sync.Mutex
	calls      []string
	archiveErr error
	restoreErr error
	deleteErr  error
	renameErr  error
	forkNewID  string
	forkErr    error
	exportRes  *kimiweb.ExportResult
	exportErr  error
}

func (f *fakeMgmt) Archive(ctx context.Context, sid string) error {
	f.mu.Lock()
	f.calls = append(f.calls, "Archive:"+sid)
	f.mu.Unlock()
	return f.archiveErr
}
func (f *fakeMgmt) Restore(ctx context.Context, sid string, opts *kimiweb.RestoreOpts) error {
	f.mu.Lock()
	f.calls = append(f.calls, "Restore:"+sid)
	f.mu.Unlock()
	return f.restoreErr
}
func (f *fakeMgmt) Delete(ctx context.Context, sid string) error {
	f.mu.Lock()
	f.calls = append(f.calls, "Delete:"+sid)
	f.mu.Unlock()
	return f.deleteErr
}
func (f *fakeMgmt) Fork(ctx context.Context, opts kimiweb.ForkOpts) (string, error) {
	f.mu.Lock()
	f.calls = append(f.calls, "Fork:"+opts.SourceSessionID)
	f.mu.Unlock()
	return f.forkNewID, f.forkErr
}
func (f *fakeMgmt) Rename(ctx context.Context, sid, title string) error {
	f.mu.Lock()
	f.calls = append(f.calls, "Rename:"+sid+":"+title)
	f.mu.Unlock()
	return f.renameErr
}
func (f *fakeMgmt) Export(ctx context.Context, sid string, opts kimiweb.ExportOpts) (*kimiweb.ExportResult, error) {
	f.mu.Lock()
	f.calls = append(f.calls, "Export:"+sid)
	f.mu.Unlock()
	return f.exportRes, f.exportErr
}

func mgmtCalled(f *fakeMgmt, want string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.calls {
		if c == want {
			return true
		}
	}
	return false
}

// recvManaged 从捕获通道取出 session.managed 回执并解析。
func recvManaged(t *testing.T, capCh chan []byte) DownSessionManagedPayload {
	t.Helper()
	var p DownSessionManagedPayload
	e := recvDown(t, capCh, DownSessionManaged)
	if err := json.Unmarshal(e.Payload, &p); err != nil {
		t.Fatalf("解析 session.managed 失败: %v", err)
	}
	return p
}

func TestHandleManageSession_NotEnabled(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.handleManageSession(&client{send: capCh}, UpManageSessionPayload{Action: ManageActionArchive, SessionID: "s1"})
	p := recvManaged(t, capCh)
	if p.Ok {
		t.Fatal("未启用应 ok=false")
	}
	if p.Error == "" {
		t.Fatal("未启用应带错误信息")
	}
}

func TestHandleManageSession_Archive(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.acp = &fakeACP{} // 成功后 go listSessions 需要 acp.ListSessions
	fm := &fakeMgmt{}
	r.mgmt = fm
	r.handleManageSession(&client{send: capCh}, UpManageSessionPayload{Action: ManageActionArchive, SessionID: "s1"})
	p := recvManaged(t, capCh)
	if !p.Ok {
		t.Fatalf("archive 应成功，got err=%s", p.Error)
	}
	if p.Action != ManageActionArchive || p.SessionID != "s1" {
		t.Fatalf("回执字段不匹配: %+v", p)
	}
	if !mgmtCalled(fm, "Archive:s1") {
		t.Fatal("未调用 Archive")
	}
	// 成功后应广播刷新会话列表
	recvDown(t, capCh, DownSessionList)
}

func TestHandleManageSession_RenameMissingTitle(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.acp = &fakeACP{}
	r.mgmt = &fakeMgmt{}
	r.handleManageSession(&client{send: capCh}, UpManageSessionPayload{Action: ManageActionRename, SessionID: "s1"})
	p := recvManaged(t, capCh)
	if p.Ok {
		t.Fatal("缺 title 应失败")
	}
}

func TestHandleManageSession_UnknownAction(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.acp = &fakeACP{}
	r.mgmt = &fakeMgmt{}
	r.handleManageSession(&client{send: capCh}, UpManageSessionPayload{Action: "whatever", SessionID: "s1"})
	p := recvManaged(t, capCh)
	if p.Ok {
		t.Fatal("未知 action 应失败")
	}
}

func TestHandleManageSession_Fork(t *testing.T) {
	r, capCh := newTestRelay(t)
	r.acp = &fakeACP{}
	fm := &fakeMgmt{forkNewID: "s-new"}
	r.mgmt = fm
	r.handleManageSession(&client{send: capCh}, UpManageSessionPayload{Action: ManageActionFork, SessionID: "s1", Title: "copy"})
	p := recvManaged(t, capCh)
	if !p.Ok {
		t.Fatalf("fork 应成功，got err=%s", p.Error)
	}
	var d struct {
		NewSessionID string `json:"newSessionId"`
	}
	if err := json.Unmarshal(p.Data, &d); err != nil {
		t.Fatalf("解析 fork data 失败: %v", err)
	}
	if d.NewSessionID != "s-new" {
		t.Fatalf("fork 未返回新会话 id，got=%q", d.NewSessionID)
	}
}
