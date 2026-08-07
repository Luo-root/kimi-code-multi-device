package kimiweb

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// StaticProvider 用固定 BaseURL + Token 提供 Endpoint（来自配置或环境变量）。
type StaticProvider struct {
	BaseURL string
	Token   string
}

// Endpoint 实现 EndpointProvider。
func (p StaticProvider) Endpoint(_ context.Context) (Endpoint, error) {
	if p.BaseURL == "" {
		return Endpoint{}, fmt.Errorf("kimiweb: StaticProvider BaseURL 为空")
	}
	return Endpoint{BaseURL: p.BaseURL, Token: p.Token}, nil
}

// SpawnProvider 提供 kimi web 端点：优先复用已在运行的实例，没有才代启一个
// （懒启动：首次 Endpoint() 调用时才拉起进程），并从 stdout 启动横幅中捕获
// BaseURL 与 Token。
//
// 横幅形如：Kimi server: http://127.0.0.1:58627/#token=xxxx
// Token 跨重启稳定，但 `~/.kimi-code/server.token` 文件在 0.32.0 不存在，故必须捕获 stdout。
//
// # 为什么必须先复用（单写者约束）
//
// kimi 的会话存储是独占写锁。若用户自己开着 kimi web，relay 再起第二个实例，
// 则非持锁方的一切写操作都返回 50001 "storage write failed"，而读正常——
// 表现为「会话列表看得到、一改就失败」，且错误信息完全无法自解释。
// 因此这里先探测默认端口上是否已有实例，有就复用。
type SpawnProvider struct {
	// BinPath 是 kimi 可执行文件路径；空则使用 PATH 中的 "kimi"。
	BinPath string
	// Port 指定端口；0 表示使用 kimi 默认端口 DefaultPort。
	Port int
	// Token 是已知的 kimi web bearer token。用于复用已在运行的实例
	// （token 跨重启持久，可由用户从 kimi web 启动横幅抄到配置里）。
	Token string
	// DebugEndpoints 是否追加 --debug-endpoints。
	// 注意：REST :action 管理面**不需要**它，仅在需要 /api/v1/debug/* 时才开。
	DebugEndpoints bool

	mu       sync.Mutex
	cmd      *exec.Cmd
	ep       *Endpoint
	ready    chan struct{}
	errCh    chan error
	waitDone chan struct{}
	started  bool
	closed   bool
}

// DefaultPort 是 kimi web 的默认绑定端口（占用时 kimi 自身会 +1 顺延）。
const DefaultPort = 58627

// spawnStartupTimeout 是首次拉起 kimi web 后等待启动横幅的最长时限。
// 与调用方 ctx 解耦：kimi web 拥有独立生命周期（detached），即使调用方超时/取消，
// 子进程也不会被强杀，下次调用即可命中已缓存的 Endpoint。
const spawnStartupTimeout = 60 * time.Second

// probeTimeout 是探测已有实例的超时（loopback，应当很快）。
const probeTimeout = 2 * time.Second

// port 返回实际使用的端口。
func (p *SpawnProvider) port() int {
	if p.Port > 0 {
		return p.Port
	}
	return DefaultPort
}

// Endpoint 实现 EndpointProvider：优先复用已运行实例，否则懒启动 kimi web。
func (p *SpawnProvider) Endpoint(ctx context.Context) (Endpoint, error) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return Endpoint{}, fmt.Errorf("kimiweb: SpawnProvider 已关闭")
	}
	if p.ep != nil {
		ep := *p.ep
		p.mu.Unlock()
		return ep, nil
	}
	if p.started {
		ready, errCh := p.ready, p.errCh
		p.mu.Unlock()
		return p.waitReady(ctx, ready, errCh)
	}
	p.started = true
	p.mu.Unlock()

	// 1) 端口上已有服务：必须复用，绝不能再起第二个（单写者写锁）。
	if occupied := portOccupied(p.port()); occupied {
		ep, err := p.reuseExisting(ctx)
		if err != nil {
			p.mu.Lock()
			p.started = false
			p.mu.Unlock()
			return Endpoint{}, err
		}
		p.mu.Lock()
		p.ep = &ep
		p.mu.Unlock()
		return ep, nil
	}

	// 2) 端口空闲：代启一个。
	if err := p.start(); err != nil {
		p.mu.Lock()
		p.started = false
		p.mu.Unlock()
		return Endpoint{}, err
	}
	ready, errCh := p.ready, p.errCh
	// 首次拉起：用独立超时等待横幅，绝不被调用方的短超时强杀子进程。
	// 即使本次等待超时，kimi web 仍存活，下一次调用将直接命中缓存的 Endpoint。
	waitCtx, cancel := context.WithTimeout(context.Background(), spawnStartupTimeout)
	defer cancel()
	return p.waitReady(waitCtx, ready, errCh)
}

// reuseExisting 尝试复用已在运行的 kimi web 实例。
// 需要 token 才能通过鉴权；拿不到 token 时给出可操作的中文指引，
// 而不是让用户后续撞上晦涩的 50001 storage write failed。
func (p *SpawnProvider) reuseExisting(ctx context.Context) (Endpoint, error) {
	base := fmt.Sprintf("http://127.0.0.1:%d", p.port())
	if p.Token == "" {
		return Endpoint{}, fmt.Errorf(
			"检测到 %s 上已有 kimi web 在运行，但 relay 没有它的访问 token。"+
				"kimi 的会话存储是单写者独占，relay 不能再启动第二个实例"+
				"（否则归档/分叉等写操作会返回 50001 storage write failed）。"+
				"请在 relay.toml 的 [kimiweb] 段填入 token（可从 kimi web 启动横幅的 #token= 处抄取），"+
				"或先关闭已运行的 kimi web 再重试", base)
	}
	if err := probeAuth(ctx, base, p.Token); err != nil {
		return Endpoint{}, fmt.Errorf(
			"检测到 %s 上已有 kimi web 在运行，但用配置的 token 访问失败：%w。"+
				"请核对 [kimiweb] token（kimi web 启动横幅 #token= 之后的部分），"+
				"或先关闭已运行的 kimi web 再重试", base, err)
	}
	return Endpoint{BaseURL: base, Token: p.Token}, nil
}

// portOccupied 检测本机端口上是否已有服务在监听。
func portOccupied(port int) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), probeTimeout)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// probeAuth 用 token 访问 /api/v1/meta 验证凭据可用。
func probeAuth(ctx context.Context, baseURL, token string) error {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/api/v1/meta", nil)
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return fmt.Errorf("token 被拒绝 (http %d)", resp.StatusCode)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("http %d", resp.StatusCode)
	}
	return nil
}

// waitReady 等待横幅解析（或进程提前退出 / ctx 取消）。
func (p *SpawnProvider) waitReady(ctx context.Context, ready chan struct{}, errCh chan error) (Endpoint, error) {
	select {
	case <-ctx.Done():
		return Endpoint{}, ctx.Err()
	case err := <-errCh:
		return Endpoint{}, err
	case <-ready:
		p.mu.Lock()
		ep := *p.ep
		p.mu.Unlock()
		return ep, nil
	}
}

// start 懒启动 kimi web 子进程。
//
// 关键修复（Root Cause 1）：使用 context.Background() 的独立生命周期启动子进程，
// 绝不绑定调用方的短超时 ctx。原先使用 exec.CommandContext(ctx, ...) 会把调用方
// 的 15s 超时透传到子进程；超时取消时 Go 会强杀 kimi web，表现为
// "kimi web 提前退出: exit status 1" 与 "context deadline exceeded"。
// 改为 detached 生命周期后，kimi web 常驻，Endpoint 横幅解析与后续 RPC 互不干扰。
func (p *SpawnProvider) start() error {
	bin := p.BinPath
	if bin == "" {
		bin = "kimi"
	}
	// --no-open：relay 是后台服务，绝不能弹出浏览器窗口打扰用户。
	args := []string{"web", "--no-open", "--port", strconv.Itoa(p.port())}
	if p.DebugEndpoints {
		args = append(args, "--debug-endpoints")
	}
	cmd := exec.Command(bin, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("kimiweb: stdout pipe: %w", err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("kimiweb: 启动 kimi web: %w", err)
	}
	done := make(chan struct{})
	p.cmd = cmd
	p.ready = make(chan struct{})
	p.errCh = make(chan error, 1)
	p.waitDone = done
	go p.scan(stdout)
	go func() {
		err := cmd.Wait()
		p.mu.Lock()
		if err != nil && p.ep == nil {
			select {
			case p.errCh <- fmt.Errorf("kimi web 提前退出: %w", err):
			default:
			}
		}
		p.mu.Unlock()
		close(done)
	}()
	return nil
}

// scan 逐行读 stdout，命中启动横幅即解析 Endpoint 并关闭 ready。
func (p *SpawnProvider) scan(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		if ep, ok := parseBanner(sc.Text()); ok {
			p.mu.Lock()
			if p.ep == nil {
				p.ep = &ep
				close(p.ready)
			}
			p.mu.Unlock()
			return
		}
	}
}

// parseBanner 从 kimi web 启动横幅中解析 BaseURL 与 Token。
// 兼容两种常见形态：
//
//	Kimi server: http://127.0.0.1:58627/#token=xxxx
//	... token=xxxx ...
func parseBanner(line string) (Endpoint, bool) {
	idx := strings.Index(line, "token=")
	if idx < 0 {
		return Endpoint{}, false
	}
	token := line[idx+len("token="):]
	if i := strings.IndexAny(token, " \t\r\n\"'"); i >= 0 {
		token = token[:i]
	}
	if token == "" {
		return Endpoint{}, false
	}

	var base string
	if u := strings.Index(line, "http://"); u >= 0 {
		base = line[u:]
	} else if u := strings.Index(line, "https://"); u >= 0 {
		base = line[u:]
	}
	if h := strings.Index(base, "#"); h >= 0 {
		base = base[:h]
	}
	if i := strings.IndexAny(base, " \t\r\n"); i >= 0 {
		base = base[:i]
	}
	base = strings.TrimRight(base, "/")
	if base == "" {
		return Endpoint{}, false
	}
	return Endpoint{BaseURL: base, Token: token}, true
}

// closeTimeout 是等待 kimi web 退出的上限。
const closeTimeout = 10 * time.Second

// Close 强杀代启的 kimi web 子进程，并**等待其真正退出**。
//
// 必须等待：Kill 只是投递信号，进程仍需时间释放监听端口。若不等就返回，
// 紧接着的重启会看到端口仍被占用，误判为「已有实例在运行」而拒绝启动。
// 复用已有实例（未代启）时 cmd 为 nil，此处直接返回，不会误杀用户自己的 kimi web。
func (p *SpawnProvider) Close() error {
	p.mu.Lock()
	p.closed = true
	cmd, done := p.cmd, p.waitDone
	p.mu.Unlock()

	if cmd == nil || cmd.Process == nil {
		return nil
	}
	if err := cmd.Process.Kill(); err != nil {
		// 进程可能已自行退出，此时 Kill 报错无需上抛。
		if done == nil {
			return err
		}
	}
	if done == nil {
		return nil
	}
	select {
	case <-done:
		return nil
	case <-time.After(closeTimeout):
		return fmt.Errorf("kimiweb: kimi web 未在 %s 内退出", closeTimeout)
	}
}
