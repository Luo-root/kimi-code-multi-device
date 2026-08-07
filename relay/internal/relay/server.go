package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Luo-root/kimi-code-multi-device/relay/internal/acp"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/bark"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/config"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/kimiweb"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/permit"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/replay"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/risk"
	"github.com/Luo-root/kimi-code-multi-device/relay/internal/session"
	acpsdk "github.com/coder/acp-go-sdk"
	"github.com/gorilla/websocket"
)

// acpClient 是 Relay 依赖的 ACP 客户端能力接口。
// 把 *acp.Client 的具体类型抽象成接口，便于在测试中注入 fake，
// 无需拉起真实的 kimi 子进程。*acp.Client 已实现该接口（见下方断言）。
type acpClient interface {
	Initialize(ctx context.Context) (acpsdk.InitializeResponse, error)
	Authenticate(ctx context.Context, req acpsdk.AuthenticateRequest) (acpsdk.AuthenticateResponse, error)
	NewSession(ctx context.Context, cwd string) (acpsdk.SessionId, []acpsdk.SessionConfigOption, error)
	ListSessions(ctx context.Context) ([]acpsdk.SessionInfo, error)
	ResumeSession(ctx context.Context, sid, cwd string) ([]acpsdk.SessionConfigOption, error)
	Prompt(ctx context.Context, sid, text string) error
	Cancel(ctx context.Context, sid string) error
	SetMode(ctx context.Context, sid, modeID string) error
	SetConfigOption(ctx context.Context, sid, configID, value string) error
	Restart() error
	DebugKill()
	Close()
}

// 编译期断言：*acp.Client 满足 acpClient 接口。
var _ acpClient = (*acp.Client)(nil)

type Relay struct {
	acp      acpClient
	store    *session.Store
	kimiHome string

	bark   *bark.Notifier
	permit *permit.Manager

	// 配置（TOML 文件 + App 热更新）。cfgMu 保护 cfg/permTimeout/autoPassNonCritical。
	cfg     *config.Config
	cfgPath string
	cfgMu   sync.RWMutex

	// 许可裁决配置（运行时热切换）
	permTimeout         time.Duration // manual 模式超时阈值，默认 5 分钟
	autoPassNonCritical bool          // §10 3.5 非关键超时自动放行开关，默认关

	// kimi 健康（§08 ⑥ 心跳）：false=degraded。OnExit 置 false，Restart 置 true。
	kimiAlive bool

	// mgmt 是「通道② 本机管理通道」客户端（kimi web HTTP 调试 RPC），
	// 补齐 ACP 未覆盖的会话管理。nil = 未启用（配置关闭或无可用端点）。
	// 用 managementClient 接口而非具体 *kimiweb.Client，便于测试注入与后续替换实现。
	mgmt      managementClient
	mgmtSpawn *kimiweb.SpawnProvider // 仅当 auto_start 时非空，Close 时清理子进程

	// kimiVersion 是 initialize 时 kimi 下发的版本（如 "0.32.0"），
	// 供管理操作（如 export 需要 host version）复用。
	kimiVersion string
	verMu       sync.RWMutex

	// 权限等待表：manual 模式下 OnPermission 同步阻塞，直到端侧拍板 / 超时 / kimi 退出。
	// key 为中继生成的 permID（json.RawMessage 形式下发给端侧，端侧原样回传）。
	permMu      sync.Mutex
	permWaiters map[string]chan permOutcome
	permSeq     atomic.Int64

	mu      sync.RWMutex
	clients map[*client]bool
}

// permOutcome 是阻塞中的 OnPermission 回调等待的裁决结果。
type permOutcome struct {
	resp acpsdk.RequestPermissionResponse
	err  error
}

type client struct {
	conn *websocket.Conn
	send chan []byte
	wmu  sync.Mutex
}

func New() *Relay {
	cfgPath := config.Path()
	cfg, err := config.Load(cfgPath)
	if err != nil {
		log.Printf("[relay] 配置加载失败，用默认值: %v", err)
	}
	// 首次启动生成默认模板：可人工编辑，也可在 App 设置页改。
	if _, statErr := os.Stat(cfgPath); os.IsNotExist(statErr) {
		if serr := config.Save(cfgPath, cfg); serr != nil {
			log.Printf("[relay] 生成默认配置失败: %v", serr)
		} else {
			log.Printf("[relay] 已生成默认配置 %s（可在 App 设置页或直接编辑）", cfgPath)
		}
	}
	r := &Relay{
		cfg:                 cfg,
		cfgPath:             cfgPath,
		store:               session.New(),
		kimiHome:            replay.DefaultHome(),
		clients:             map[*client]bool{},
		bark:                bark.New(cfg.Bark.URL),
		permTimeout:         time.Duration(cfg.Permission.TimeoutSeconds) * time.Second,
		autoPassNonCritical: cfg.Permission.AutoPassNonCritical,
		permWaiters:         map[string]chan permOutcome{},
	}
	r.permit = permit.New(r.onPermTimeout)
	r.initManagement()
	return r
}

// initManagement 依据配置装配「通道② 本机管理通道」客户端（kimi web 调试 RPC）。
// 配置关闭时 mgmt 保持 nil，后续管理类请求将返回明确错误。
// auto_start 走 SpawnProvider（懒启动，首次管理调用才拉起 kimi web）。
func (r *Relay) initManagement() {
	kw := r.cfg.KimiWeb
	if !kw.Enabled {
		return
	}
	if kw.AutoStart {
		// 管理动作走 REST :action（磁盘直读），实测**不需要** --debug-endpoints，
		// 故不再强制开启，仅在配置显式要求时透传（用于 /api/v1/debug/* 调试面）。
		sp := &kimiweb.SpawnProvider{
			DebugEndpoints: kw.DebugEndpoints,
			Port:           kw.Port,
			Token:          kw.Token,
		}
		r.mgmtSpawn = sp
		r.mgmt = kimiweb.New(sp)
		port := kw.Port
		if port == 0 {
			port = kimiweb.DefaultPort
		}
		log.Printf("[relay] 管理通道：auto_start kimi web（首次调用时优先复用已运行实例，端口 %d）", port)
		return
	}
	if kw.BaseURL != "" {
		r.mgmt = kimiweb.New(kimiweb.StaticProvider{BaseURL: kw.BaseURL, Token: kw.Token})
		log.Printf("[relay] 管理通道：直连 kimi web %s", kw.BaseURL)
		return
	}
	log.Printf("[relay] 管理通道已 enabled 但缺少 base_url 或 auto_start，管理功能不可用")
}

// managementClient 是「通道② 本机管理通道」的抽象（由 kimiweb.Client 实现）。
// 用接口而非具体类型，便于测试注入伪造实现，也方便后续替换底层通道。
type managementClient interface {
	Archive(ctx context.Context, sessionID string) error
	Restore(ctx context.Context, sessionID string, opts *kimiweb.RestoreOpts) error
	Delete(ctx context.Context, sessionID string) error
	Fork(ctx context.Context, opts kimiweb.ForkOpts) (string, error)
	Rename(ctx context.Context, sessionID, title string) error
	Export(ctx context.Context, sessionID string, opts kimiweb.ExportOpts) (*kimiweb.ExportResult, error)
}

// management 返回管理客户端；未启用时返回错误，供上层（T3 协议）转译为端侧提示。
func (r *Relay) management() (managementClient, error) {
	if r.mgmt == nil {
		return nil, fmt.Errorf("kimi web 管理通道未启用（relay.toml [kimiweb] enabled=true 并配置 base_url/token 或 auto_start）")
	}
	return r.mgmt, nil
}

func (r *Relay) Start() error {
	if r.kimiHome == "" {
		log.Println("[relay] 警告：无法确定 KIMI_CODE_HOME，历史回放不可用")
	} else {
		log.Printf("[relay] KIMI_CODE_HOME = %s", r.kimiHome)
	}
	ac, err := acp.New(acp.Handlers{
		OnUpdate:     r.onUpdate,
		OnPermission: r.onPermission,
		OnExit:       r.onKimiExit,
	})
	if err != nil {
		return err
	}
	r.acp = ac

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	initRes, err := r.acp.Initialize(ctx)
	if err != nil {
		return err
	}
	r.afterInitialize(ctx, initRes)
	r.kimiAlive = true
	cwd, _ := os.Getwd()
	if _, err := r.newSession(ctx, cwd); err != nil {
		return err
	}
	if err := r.refreshHistory(ctx); err != nil {
		log.Printf("[relay] 启动拉取历史列表失败: %v", err)
	}
	return nil
}

// afterInitialize 在 initialize 成功后做的规范对齐动作：
//  1. 记录 kimi 下发的 agentCapabilities / authMethods（ACP 规范要求 initialize 返回能力矩阵）；
//  2. 补 authenticate 握手（method_id='login'）。已登录环境通常直接成功；
//     返回 authRequired(-32000) 时 best-effort 忽略，不阻断启动（当前环境无需鉴权即可 session/new）。
func (r *Relay) afterInitialize(ctx context.Context, res acpsdk.InitializeResponse) {
	r.logAgentCapabilities(res)
	if err := r.authenticate(ctx); err != nil {
		log.Printf("[relay] authenticate 跳过（已登录或无需鉴权）: %v", err)
	}
}

// authenticate 补鉴权握手。authRequired(-32000) 视为当前环境免鉴权，best-effort 忽略。
func (r *Relay) authenticate(ctx context.Context) error {
	_, err := r.acp.Authenticate(ctx, acpsdk.AuthenticateRequest{MethodId: "login"})
	if err != nil {
		var re *acpsdk.RequestError
		if errors.As(err, &re) && re.Code == -32000 {
			log.Printf("[relay] authenticate: 当前环境免鉴权（authRequired），best-effort 继续")
			return nil
		}
	}
	return err
}

// logAgentCapabilities 把 initialize 响应里的能力矩阵与鉴权方式打到日志，便于对齐/排查。
func (r *Relay) logAgentCapabilities(res acpsdk.InitializeResponse) {
	if res.AgentInfo != nil {
		log.Printf("[relay] kimi agentInfo name=%s version=%s", res.AgentInfo.Name, res.AgentInfo.Version)
		r.verMu.Lock()
		r.kimiVersion = res.AgentInfo.Version
		r.verMu.Unlock()
	}
	if b, err := json.Marshal(res.AgentCapabilities); err == nil {
		log.Printf("[relay] kimi capabilities=%s", string(b))
	}
	if b, err := json.Marshal(res.AuthMethods); err == nil {
		log.Printf("[relay] kimi authMethods=%s", string(b))
	}
}

func (r *Relay) Close() {
	if r.acp != nil {
		r.acp.Close()
	}
	if r.mgmtSpawn != nil {
		_ = r.mgmtSpawn.Close()
	}
}

func (r *Relay) newSession(ctx context.Context, cwd string) (string, error) {
	sid, configOpts, err := r.acp.NewSession(ctx, cwd)
	if err != nil {
		return "", err
	}
	sidStr := string(sid)
	raw := acp.ConfigOptionsToRaw(configOpts)
	r.store.SetCWD(sidStr, cwd)
	r.store.SetConfig(sidStr, raw)
	r.broadcast(Env{
		Type:      DownSessionCreated,
		SessionID: sidStr,
		Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: raw}),
	})
	return sidStr, nil
}

func (r *Relay) refreshHistory(ctx context.Context) error {
	infos, err := r.acp.ListSessions(ctx)
	if err != nil {
		return err
	}
	metas := make([]session.SessionMeta, 0, len(infos))
	for _, s := range infos {
		m := session.SessionMeta{SessionID: string(s.SessionId), CWD: s.Cwd}
		if s.Title != nil {
			m.Title = *s.Title
		}
		if s.UpdatedAt != nil {
			m.UpdatedAt = *s.UpdatedAt
		}
		metas = append(metas, m)
	}
	r.store.SetHistory(metas)
	return nil
}

func (r *Relay) listSessions() {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := r.refreshHistory(ctx); err != nil {
		r.sendErr("", "list_sessions: "+err.Error())
		return
	}
	r.broadcast(Env{Type: DownSessionList, Payload: mustJSON(DownSessionListPayload{Sessions: r.store.History()})})
}

// openHistory 打开历史会话：活跃则直接补发；否则 resume 恢复上下文 + 读 wire.jsonl 回放。
func (r *Relay) openHistory(sid, cwd string) {
	// 活跃会话（中继已有流尾部）：直接补发 created
	if len(r.store.Tail(sid)) > 0 {
		r.broadcast(Env{
			Type:      DownSessionCreated,
			SessionID: sid,
			Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: r.store.Snapshot()[sid]}),
		})
		return
	}
	// 历史会话：resume 恢复 Kimi 侧上下文
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	opts, err := r.acp.ResumeSession(ctx, sid, cwd)
	if err != nil {
		r.sendErr(sid, "恢复历史会话失败: "+err.Error())
		return
	}
	raw := acp.ConfigOptionsToRaw(opts)
	r.store.SetCWD(sid, cwd)
	if len(opts) > 0 {
		r.store.SetConfig(sid, raw)
	}
	// 读历史回放（先于 created 发送，前端按序处理：先渲染历史，再据 resumed 决定是否兜底）
	blocks, meta, herr := replay.LoadHistory(r.kimiHome, sid)
	if herr != nil {
		log.Printf("[relay] 读取历史回放失败 %s: %v", sid, herr)
	}
	if blocks == nil {
		blocks = []replay.Block{}
	}
	r.broadcast(Env{
		Type:      DownSessionHistory,
		SessionID: sid,
		Payload:   mustJSON(DownSessionHistoryPayload{Blocks: blocks, Title: meta.Title, Count: len(blocks)}),
	})
	r.broadcast(Env{
		Type:      DownSessionCreated,
		SessionID: sid,
		Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: raw, Resumed: true}),
	})
}

func (r *Relay) onUpdate(sid string, update json.RawMessage) {
	var probe struct {
		SessionUpdate string          `json:"sessionUpdate"`
		ConfigOptions json.RawMessage `json:"configOptions"`
	}
	_ = json.Unmarshal(update, &probe)
	if probe.SessionUpdate == "config_option_update" && len(probe.ConfigOptions) > 0 {
		r.store.SetConfig(sid, probe.ConfigOptions)
	}
	r.store.AppendUpdate(sid, update)
	r.broadcast(Env{Type: DownSessionUpdate, SessionID: sid, Payload: update})
}

// onPermission 是 SDK 的同步权限回调：kimi 每次请求权限都会阻塞在此，直到本函数返回
// 决定（SDK 据此回 JSON-RPC response 给 kimi）。yolo/auto 立即放行；plan 拒绝；
// manual 则挂号入 permit 管理器、下发端侧等待拍板，并阻塞在 permWaiters 通道上，
// 由 UpPermDecision（端侧决定）或 onPermTimeout（超时代答）或 onKimiExit（进程退出）唤醒。
func (r *Relay) onPermission(ctx context.Context, req acpsdk.RequestPermissionRequest) (acpsdk.RequestPermissionResponse, error) {
	sid := string(req.SessionId)
	toolCall := mustJSON(req.ToolCall)
	options := mustJSON(req.Options)
	command := extractCommand(toolCall)
	critical := risk.IsCritical(command)
	mode := r.store.Mode(sid)

	switch mode {
	case "yolo", "auto":
		// agent 自主决策：直接放行，不打扰人（哨兵退场）。
		log.Printf("[relay] %s 模式自动放行 sid=%s critical=%v", mode, sid, critical)
		return permResponse("approve_once"), nil
	case "plan":
		// 只读模式不应有工具调用，记异常并拒绝。
		log.Printf("[relay] plan 模式出现工具调用，拒绝 sid=%s: %s", sid, command)
		return permResponse("reject"), nil
	default: // manual / default —— 哨兵在场
		permID := r.nextPermID()
		permIDRaw := json.RawMessage(strconv.Quote(permID))
		r.cfgMu.RLock()
		deadline := time.Now().Add(r.permTimeout)
		r.cfgMu.RUnlock()
		r.permit.Register(sid, permIDRaw, deadline, critical)

		// 登记等待通道（缓冲 1，避免唤醒端阻塞）。
		ch := make(chan permOutcome, 1)
		r.permMu.Lock()
		r.permWaiters[permID] = ch
		r.permMu.Unlock()

		r.broadcast(Env{
			Type:      DownPermRequest,
			SessionID: sid,
			Payload: mustJSON(DownPermRequestPayload{
				PermissionID: permIDRaw, ToolCall: toolCall, Options: options,
				DeadlineMs: deadline.UnixMilli(), Critical: critical,
			}),
		})
		// 门铃只当门铃，不传命令内容。
		r.bark.Notify("SENTINEL", "有命令等你批准")

		// 阻塞，直到端侧拍板 / 超时代答 / 上下文取消（kimi 退出会取消 reqCtx）。
		select {
		case out := <-ch:
			return out.resp, out.err
		case <-ctx.Done():
			log.Printf("[relay] 许可请求被取消（上下文结束）sid=%s", sid)
			return permCancelled(), ctx.Err()
		}
	}
}

// nextPermID 生成进程中唯一的中继侧许可 ID，用于关联端侧回传与阻塞的 OnPermission。
func (r *Relay) nextPermID() string {
	return "perm-" + strconv.FormatInt(r.permSeq.Add(1), 10)
}

// deliverPermission 把裁决结果投递给阻塞中的 OnPermission 回调（非阻塞：通道缓冲 1）。
func (r *Relay) deliverPermission(id json.RawMessage, resp acpsdk.RequestPermissionResponse) {
	var key string
	if err := json.Unmarshal(id, &key); err != nil {
		key = strings.Trim(string(id), `"`)
	}
	r.permMu.Lock()
	ch, ok := r.permWaiters[key]
	if ok {
		delete(r.permWaiters, key)
	}
	r.permMu.Unlock()
	if ok {
		ch <- permOutcome{resp: resp, err: nil}
	}
}

// permResponse 构造「用户选定某选项」的许可决定。
func permResponse(optionID string) acpsdk.RequestPermissionResponse {
	return acpsdk.RequestPermissionResponse{Outcome: acpsdk.RequestPermissionOutcome{
		Selected: &acpsdk.RequestPermissionOutcomeSelected{
			OptionId: acpsdk.PermissionOptionId(optionID),
			Outcome:  "selected",
		},
	}}
}

// permCancelled 构造「请求已取消」的许可决定（kimi 取消 prompt 或连接关闭时返回）。
func permCancelled() acpsdk.RequestPermissionResponse {
	return acpsdk.RequestPermissionResponse{Outcome: acpsdk.RequestPermissionOutcome{
		Cancelled: &acpsdk.RequestPermissionOutcomeCancelled{Outcome: "cancelled"},
	}}
}

// onPermTimeout 超时未决：按策略代答（默认拒绝；非关键+开关开则放行），
// 投递给阻塞的 OnPermission，并广播失效 + 门铃。
func (r *Relay) onPermTimeout(sid string, id json.RawMessage, critical bool) {
	r.cfgMu.RLock()
	autoPass := r.autoPassNonCritical
	r.cfgMu.RUnlock()
	optionID := "reject"
	note := "一条命令已超时拒绝"
	if !critical && autoPass {
		optionID = "approve_once"
		note = "一条非关键命令已超时自动放行"
	}
	r.deliverPermission(id, permResponse(optionID))
	r.broadcast(Env{Type: DownPermInvalidate})
	r.bark.Notify("SENTINEL", note)
	log.Printf("[relay] 许可超时 sid=%s critical=%v → %s", sid, critical, optionID)
}

// extractCommand 从 toolCall 提取命令文本（与端 extractToolText 同源）。
func extractCommand(toolCall json.RawMessage) string {
	var tc struct {
		RawInput struct {
			Command string `json:"command"`
		} `json:"rawInput"`
		Content []struct {
			Content struct {
				Text string `json:"text"`
			} `json:"content"`
			Text string `json:"text"`
		} `json:"content"`
	}
	_ = json.Unmarshal(toolCall, &tc)
	if tc.RawInput.Command != "" {
		return stripCmdPrefix(tc.RawInput.Command)
	}
	var buf strings.Builder
	for _, c := range tc.Content {
		if c.Content.Text != "" {
			buf.WriteString(c.Content.Text)
		} else if c.Text != "" {
			buf.WriteString(c.Text)
		}
	}
	return stripCmdPrefix(buf.String())
}

func stripCmdPrefix(s string) string {
	for _, m := range []string{"Requesting approval to Running: ", "Running: "} {
		if strings.HasPrefix(s, m) {
			return strings.TrimPrefix(s, m)
		}
	}
	return s
}

func (r *Relay) onKimiExit() {
	log.Println("[relay] kimi 子进程退出（非预期）→ degraded")
	r.kimiAlive = false
	// kimi 没了，解除所有被阻塞的 OnPermission 回调，避免 goroutine 永久挂起；
	// 同时 pending 许可 respond 无意义，清定时器；端侧凭 invalidate 收尾。
	r.permMu.Lock()
	for k, ch := range r.permWaiters {
		delete(r.permWaiters, k)
		ch <- permOutcome{resp: permCancelled(), err: nil}
	}
	r.permMu.Unlock()
	r.permit.InvalidateAll()
	r.broadcast(Env{Type: DownPermInvalidate})
	r.broadcast(Env{Type: DownRelayState, Payload: mustJSON(DownRelayStatePayload{State: "degraded"})})
}

func (r *Relay) restartKimi() {
	log.Println("[relay] 重试拉起 kimi …")
	if err := r.acp.Restart(); err != nil {
		r.sendErr("", "restart spawn: "+err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	initRes, err := r.acp.Initialize(ctx)
	if err != nil {
		r.sendErr("", "restart initialize: "+err.Error())
		return
	}
	r.afterInitialize(ctx, initRes)
	for _, sid := range r.store.SIDs() {
		cwd := r.store.CWD(sid)
		opts, err := r.acp.ResumeSession(ctx, sid, cwd)
		if err != nil {
			log.Printf("[relay] resume %s 失败: %v", sid, err)
			r.sendErr(sid, "会话恢复失败，上下文可能丢失: "+err.Error())
			// 失效会话从活跃表摘除：否则 snapshot() 会把它再次广播给端侧，
			// 造成死 tab，用户一发消息就被 Kimi 拒（Unknown sessionId）。
			r.store.Remove(sid)
			r.broadcast(Env{Type: DownSessionClosed, SessionID: sid})
			continue
		}
		raw := acp.ConfigOptionsToRaw(opts)
		if len(opts) > 0 {
			r.store.SetConfig(sid, raw)
		}
	}
	r.kimiAlive = true
	r.broadcast(Env{Type: DownRelayState, Payload: mustJSON(DownRelayStatePayload{State: "ok"})})
	log.Println("[relay] kimi 已恢复 → ok")
}

func (r *Relay) broadcast(e Env) {
	b, err := json.Marshal(e)
	if err != nil {
		return
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for c := range r.clients {
		select {
		case c.send <- b:
		default:
			log.Printf("[relay] 端发送缓冲满，丢帧 type=%s", e.Type)
		}
	}
}

func (r *Relay) sendBlocking(c *client, e Env) {
	b, _ := json.Marshal(e)
	c.send <- b
}

func (r *Relay) sendErr(sid, msg string) {
	r.broadcast(Env{Type: DownRelayError, SessionID: sid, Payload: mustJSON(DownRelayErrorPayload{Message: msg})})
}

// relayConfig 组装中继运行配置快照（snapshot 时随下行下发，端侧设置页据此诚实展示）。
func (r *Relay) relayConfig() DownRelayConfigPayload {
	r.cfgMu.RLock()
	defer r.cfgMu.RUnlock()
	return r.relayConfigLocked()
}

// relayConfigLocked 组装配置快照，调用方须已持有 cfgMu（读或写）。
func (r *Relay) relayConfigLocked() DownRelayConfigPayload {
	return DownRelayConfigPayload{
		BarkURL:             r.cfg.Bark.URL,
		PermTimeoutSeconds:  r.cfg.Permission.TimeoutSeconds,
		AutoPassNonCritical: r.cfg.Permission.AutoPassNonCritical,
		ConfigPath:          r.cfgPath,
		MgmtEnabled:         r.mgmt != nil,
	}
}

// applyConfig 应用端侧 config.set：更新内存配置 + 热切换 + 写回文件 + 广播新快照。
func (r *Relay) applyConfig(p UpConfigSetPayload) error {
	r.cfgMu.Lock()
	defer r.cfgMu.Unlock()
	if p.BarkURL != nil {
		r.cfg.Bark.URL = *p.BarkURL
		r.bark.Configure(*p.BarkURL)
	}
	if p.PermTimeoutSeconds != nil {
		r.cfg.Permission.TimeoutSeconds = *p.PermTimeoutSeconds
		r.permTimeout = time.Duration(*p.PermTimeoutSeconds) * time.Second
	}
	if p.AutoPassNonCritical != nil {
		r.cfg.Permission.AutoPassNonCritical = *p.AutoPassNonCritical
		r.autoPassNonCritical = *p.AutoPassNonCritical
	}
	if err := config.Save(r.cfgPath, r.cfg); err != nil {
		return fmt.Errorf("config save: %w", err)
	}
	r.broadcast(Env{Type: DownRelayConfig, Payload: mustJSON(r.relayConfigLocked())})
	return nil
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func (r *Relay) HandleWS(w http.ResponseWriter, req *http.Request) {
	conn, err := upgrader.Upgrade(w, req, nil)
	if err != nil {
		return
	}
	c := &client{conn: conn, send: make(chan []byte, 512)}
	r.mu.Lock()
	r.clients[c] = true
	r.mu.Unlock()

	go r.writePump(c)
	r.readPump(c)
}

func (r *Relay) writePump(c *client) {
	defer func() {
		r.mu.Lock()
		delete(r.clients, c)
		r.mu.Unlock()
		_ = c.conn.Close()
	}()
	for msg := range c.send {
		c.wmu.Lock()
		_ = c.conn.WriteMessage(websocket.TextMessage, msg)
		c.wmu.Unlock()
	}
}

func (r *Relay) readPump(c *client) {
	defer func() {
		close(c.send)
		_ = c.conn.Close()
	}()
	r.snapshot(c)
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		r.handleUp(c, data)
	}
}

func (r *Relay) snapshot(c *client) {
	for _, sid := range r.store.SIDs() {
		opts := r.store.Snapshot()[sid]
		r.sendBlocking(c, Env{
			Type:      DownSessionCreated,
			SessionID: sid,
			Payload:   mustJSON(DownSessionCreatedPayload{ConfigOptions: opts}),
		})
		for _, u := range r.store.Tail(sid) {
			r.sendBlocking(c, Env{Type: DownSessionUpdate, SessionID: sid, Payload: u})
		}
	}
	if h := r.store.History(); len(h) > 0 {
		r.sendBlocking(c, Env{Type: DownSessionList, Payload: mustJSON(DownSessionListPayload{Sessions: h})})
	}
	// 下发当前 kimi 健康态，重连客户端立即知是否 degraded。
	state := "ok"
	if !r.kimiAlive {
		state = "degraded"
	}
	r.sendBlocking(c, Env{Type: DownRelayState, Payload: mustJSON(DownRelayStatePayload{State: state})})
	// 下发运行配置快照，端侧设置页展示真实值（不诚实即一票否决）。
	r.sendBlocking(c, Env{Type: DownRelayConfig, Payload: mustJSON(r.relayConfig())})
	// 补发在跑会话的 busy，重连后「停」可见性正确。
	for _, sid := range r.store.BusySIDs() {
		r.sendBlocking(c, Env{Type: DownSessionBusy, SessionID: sid, Payload: mustJSON(DownSessionBusyPayload{Busy: true})})
	}
}

func (r *Relay) handleUp(c *client, data []byte) {
	var e Env
	if err := json.Unmarshal(data, &e); err != nil {
		return
	}
	switch e.Type {
	case UpPermDecision:
		var d UpPermDecisionPayload
		_ = json.Unmarshal(e.Payload, &d)
		// 仅当尚未超时才 respond；超时已由中继代答，迟到决定忽略。
		if !r.permit.Resolve(d.PermissionID) {
			log.Printf("[relay] 许可决定迟到（已超时代答）: %s", d.OptionID)
			return
		}
		r.deliverPermission(d.PermissionID, permResponse(d.OptionID))
	case UpPrompt:
		var p UpPromptPayload
		_ = json.Unmarshal(e.Payload, &p)
		sid := e.SessionID
		// 防御：sid 不在活跃表（Kimi 不认识 / 已失效）时不再透传给 Kimi，
		// 否则 Kimi 报 Unknown sessionId 且端侧还卡在死 tab。直接报错并通知端侧移除。
		if sid == "" || !r.store.Has(sid) {
			r.sendErr(sid, "会话不存在或已失效，消息未发送")
			r.broadcast(Env{Type: DownSessionClosed, SessionID: sid})
			return
		}
		go func() {
			// busy 开始：AI 还在输出，驱动端「停」可见。
			r.store.SetBusy(sid, true)
			r.broadcast(Env{Type: DownSessionBusy, SessionID: sid, Payload: mustJSON(DownSessionBusyPayload{Busy: true})})
			start := time.Now()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer cancel()
			err := r.acp.Prompt(ctx, sid, p.Text)
			elapsed := time.Since(start)
			// busy 结束：输出完毕（成功或出错都算跑完），「停」退场。
			r.store.SetBusy(sid, false)
			r.broadcast(Env{Type: DownSessionBusy, SessionID: sid, Payload: mustJSON(DownSessionBusyPayload{Busy: false})})
			if err != nil {
				r.sendErr(sid, "prompt: "+err.Error())
				// §04 支柱02 时刻②：跑完（出错）也告知。
				r.bark.Notify("SENTINEL", "一轮跑完（出错）")
				return
			}
			// 长任务跑完才叫（短任务频繁打扰没意义）。
			if elapsed > time.Minute {
				r.bark.Notify("SENTINEL", "长任务跑完了")
			}
		}()
	case UpCancel:
		sid := e.SessionID
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			// session/cancel 是 ACP notification（无 id）；带 id 的 request 形式会被
			// kimi 拒为 -32601 Method not found（实测 0.32.0，二进制内嵌 SDK 注释证实）。
			// notification 形式立即中断当前轮：prompt 以 stopReason=cancelled 返回，
			// busy 随 prompt goroutine 自然复位，会话可继续使用（均已实测）。
			if err := r.acp.Cancel(ctx, sid); err != nil {
				r.sendErr(sid, "cancel: "+err.Error())
			}
		}()
	case UpSetMode:
		var s UpSetModePayload
		_ = json.Unmarshal(e.Payload, &s)
		sid := e.SessionID
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := r.acp.SetMode(ctx, sid, s.ModeID); err != nil {
				r.sendErr(sid, "set_mode: "+err.Error())
			}
		}()
	case UpSetModel:
		var s UpSetModelPayload
		_ = json.Unmarshal(e.Payload, &s)
		sid := e.SessionID
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := r.acp.SetConfigOption(ctx, sid, "model", s.Value); err != nil {
				r.sendErr(sid, "set_config_option: "+err.Error())
			}
		}()
	case UpNewSession:
		var n UpNewSessionPayload
		_ = json.Unmarshal(e.Payload, &n)
		cwd := n.CWD
		if cwd == "" {
			cwd, _ = os.Getwd()
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			if _, err := r.newSession(ctx, cwd); err != nil {
				r.sendErr("", "new_session: "+err.Error())
			}
		}()
	case UpRestartKimi:
		go r.restartKimi()
	case UpDebugKill:
		r.acp.DebugKill()
	case UpListSessions:
		go r.listSessions()
	case UpConfigSet:
		var s UpConfigSetPayload
		_ = json.Unmarshal(e.Payload, &s)
		if err := r.applyConfig(s); err != nil {
			r.sendErr("", "config.set: "+err.Error())
		}
	case UpOpenHistory:
		var o UpOpenHistoryPayload
		_ = json.Unmarshal(e.Payload, &o)
		go r.openHistory(o.SessionID, o.CWD)
	case UpCloseSession:
		sid := e.SessionID
		if sid == "" {
			return
		}
		go func() {
			// ACP 规范（kimi-acp 文档「稳定面」清单）：kimi 未实现 session/close，
			// 向其发该 RPC 必然 methodNotFound。故只做本地清理 + 通知端侧移除 tab，
			// 不再发无意义的请求（此前每次关 tab 都会打一条失败日志）。
			r.store.Remove(sid)
			r.broadcast(Env{Type: DownSessionClosed, SessionID: sid})
		}()
	case UpManageSession:
		var p UpManageSessionPayload
		_ = json.Unmarshal(e.Payload, &p)
		r.handleManageSession(c, p)
	}
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// handleManageSession 处理端侧发起的会话管理操作（通道② 补齐 ACP 缺口）。
// 结果定向回给发起端 c；成功后广播刷新会话列表，使所有端看到最新状态。
func (r *Relay) handleManageSession(c *client, p UpManageSessionPayload) {
	sid := p.SessionID
	log.Printf("[relay] session.manage action=%s sessionId=%s", p.Action, sid)
	reply := func(ok bool, errMsg string, data json.RawMessage) {
		log.Printf("[relay] session.managed action=%s sessionId=%s ok=%v error=%q", p.Action, sid, ok, errMsg)
		r.sendBlocking(c, Env{
			Type:      DownSessionManaged,
			SessionID: sid,
			Payload: mustJSON(DownSessionManagedPayload{
				Action: p.Action, SessionID: sid, Ok: ok, Error: errMsg, Data: data,
			}),
		})
	}

	if sid == "" {
		reply(false, "session.manage 缺少 sessionId", nil)
		return
	}
	mgmt, err := r.management()
	if err != nil {
		reply(false, enrichMgmtErr(err), nil)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	switch p.Action {
	case ManageActionArchive:
		if err := mgmt.Archive(ctx, sid); err != nil {
			reply(false, enrichMgmtErr(err), nil)
			return
		}
	case ManageActionRestore:
		if err := mgmt.Restore(ctx, sid, nil); err != nil {
			reply(false, enrichMgmtErr(err), nil)
			return
		}
	case ManageActionDelete:
		if err := mgmt.Delete(ctx, sid); err != nil {
			reply(false, enrichMgmtErr(err), nil)
			return
		}
	case ManageActionRename:
		if p.Title == "" {
			reply(false, "rename 需要 title", nil)
			return
		}
		if err := mgmt.Rename(ctx, sid, p.Title); err != nil {
			reply(false, enrichMgmtErr(err), nil)
			return
		}
	case ManageActionFork:
		newID, err := mgmt.Fork(ctx, kimiweb.ForkOpts{
			SourceSessionID: sid,
			Title:           p.Title,
			NewSessionID:    p.NewSessionID,
		})
		if err != nil {
			reply(false, enrichMgmtErr(err), nil)
			return
		}
		reply(true, "", mustJSON(struct {
			NewSessionID string `json:"newSessionId"`
		}{NewSessionID: newID}))
		go r.listSessions()
		return
	case ManageActionExport:
		opts := kimiweb.ExportOpts{Version: r.kimiVersionLocked()}
		if len(p.Options) > 0 {
			var o struct {
				Version    string `json:"version"`
				OutputPath string `json:"outputPath"`
			}
			if err := json.Unmarshal(p.Options, &o); err == nil {
				if o.Version != "" {
					opts.Version = o.Version
				}
				opts.OutputPath = o.OutputPath
			}
		}
		res, err := mgmt.Export(ctx, sid, opts)
		if err != nil {
			reply(false, enrichMgmtErr(err), nil)
			return
		}
		reply(true, "", mustJSON(res))
		return
	default:
		reply(false, "未知管理操作: "+p.Action, nil)
		return
	}

	// 归档/恢复/删除/重命名成功：刷新会话列表让所有端看到最新状态。
	go r.listSessions()
	reply(true, "", nil)
}

// kimiVersionLocked 读取缓存的 kimi 版本（调用方无需持锁）。
func (r *Relay) kimiVersionLocked() string {
	r.verMu.RLock()
	defer r.verMu.RUnlock()
	return r.kimiVersion
}

// enrichMgmtErr 把管理通道的错误转译为端侧可懂的提示。
//
// kimi 的原始错误对用户完全不可自解释，这里把三类高频错误翻成可操作的中文：
//   - 50001 storage write failed：另有 kimi web 持有会话存储的独占写锁（单写者约束）。
//     典型场景是用户自己开着 kimi web，relay 又起了第二个实例。
//   - 40401 session not found：会话未加载进 kimi web 运行时（仅调试 RPC 路径会遇到；
//     REST :action 走磁盘直读，正常不会命中）。
//   - ErrUnsupported：kimi 该版本压根没提供此动作的接口（rename/delete）。
func enrichMgmtErr(err error) string {
	if errors.Is(err, kimiweb.ErrUnsupported) {
		// 端侧已按 kKimiUnsupportedActions 在菜单禁用并提示，理论上不会走到这里；
		// 若仍触发（例如未来协议扩展），给一条干净、不含内部前缀的中文说明。
		return "当前 kimi 版本未提供该管理动作的接口，操作无法执行"
	}
	if re, ok := kimiweb.IsRPCError(err); ok {
		switch re.Code {
		case kimiweb.CodeStorageWriteFailed:
			return "检测到另一个 kimi web 正在运行并占用会话存储的写锁，操作被拒绝。" +
				"kimi 同一时刻只允许一个进程写会话数据，请关闭其他 kimi web 后重试。(" + err.Error() + ")"
		case kimiweb.CodeSessionNotFound:
			return "kimi 未能找到该会话（可能已被删除，或未加载进 kimi web 运行时）。" +
				"请刷新会话列表后重试。(" + err.Error() + ")"
		}
	}
	return err.Error()
}
