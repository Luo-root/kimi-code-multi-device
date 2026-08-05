package kimiweb

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
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

// SpawnProvider 由 relay 代启 `kimi web --debug-endpoints`，并从 stdout 启动横幅中
// 捕获 BaseURL 与 Token（懒启动：首次 Endpoint() 调用时才拉起进程）。
//
// 横幅形如：Kimi server: http://127.0.0.1:58627/#token=xxxx
// Token 跨重启稳定，但 `~/.kimi-code/server.token` 文件在 0.32.0 不存在，故必须捕获 stdout。
type SpawnProvider struct {
	// BinPath 是 kimi 可执行文件路径；空则使用 PATH 中的 "kimi"。
	BinPath string
	// Port 指定端口；0 让 kimi 自选（并从横幅抓取实际端口）。
	Port int
	// DebugEndpoints 是否追加 --debug-endpoints（管理 RPC 必需，默认 true）。
	DebugEndpoints bool

	mu      sync.Mutex
	cmd     *exec.Cmd
	ep      *Endpoint
	ready   chan struct{}
	errCh   chan error
	started bool
	closed  bool
}

// Endpoint 实现 EndpointProvider：首次调用懒启动 kimi web，并等待横幅解析完成。
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

	if err := p.start(ctx); err != nil {
		p.mu.Lock()
		p.started = false
		p.mu.Unlock()
		return Endpoint{}, err
	}
	p.mu.Lock()
	ready, errCh := p.ready, p.errCh
	p.mu.Unlock()
	return p.waitReady(ctx, ready, errCh)
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

func (p *SpawnProvider) start(ctx context.Context) error {
	bin := p.BinPath
	if bin == "" {
		bin = "kimi"
	}
	args := []string{"web"}
	if p.DebugEndpoints {
		args = append(args, "--debug-endpoints")
	}
	if p.Port > 0 {
		args = append(args, "--port", strconv.Itoa(p.Port))
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("kimiweb: stdout pipe: %w", err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("kimiweb: 启动 kimi web: %w", err)
	}
	p.cmd = cmd
	p.ready = make(chan struct{})
	p.errCh = make(chan error, 1)
	go p.scan(stdout)
	go func() {
		if err := cmd.Wait(); err != nil {
			p.mu.Lock()
			if p.ep == nil {
				select {
				case p.errCh <- fmt.Errorf("kimi web 提前退出: %w", err):
				default:
				}
			}
			p.mu.Unlock()
		}
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

// Close 强杀代启的 kimi web 子进程。
func (p *SpawnProvider) Close() error {
	p.mu.Lock()
	p.closed = true
	cmd := p.cmd
	p.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		return cmd.Process.Kill()
	}
	return nil
}
