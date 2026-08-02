// Package bark 是 §08 锁屏门铃：中继调 Bark API 弹系统级通知。
// 通知只当门铃、不传会话内容（原则 2：数据不出机器；命令原文绝不进推送）。
package bark

import (
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Notifier 发 Bark 推送。URL 为空则静默（未配置门铃）。
// URL 形如 https://api.day.app/{key}，Notify 追加 /{title}/{body}。
type Notifier struct {
	mu      sync.RWMutex // 保护 baseURL/enabled：App 设置页可热更新（Configure）
	baseURL string
	client  *http.Client
	enabled bool
}

// New 用给定 URL 创建；url 为空则禁用（静默）。
func New(url string) *Notifier {
	return &Notifier{
		baseURL: strings.TrimRight(url, "/"),
		client:  &http.Client{Timeout: 4 * time.Second},
		enabled: url != "",
	}
}

// Configure 热更新推送目标（App 设置页改 BARK_URL 时调用，无需重启）。
func (n *Notifier) Configure(url string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.baseURL = strings.TrimRight(url, "/")
	n.enabled = url != ""
}

// Enabled 报告门铃是否已配置（URL 非空）。中继据此下发真实状态给端侧。
func (n *Notifier) Enabled() bool {
	n.mu.RLock()
	defer n.mu.RUnlock()
	return n.enabled
}

// Notify 发一条门铃。title/body 都不应含会话内容（命令、输出）。
// 失败仅记日志，不影响主流程（best-effort）。
func (n *Notifier) Notify(title, body string) {
	n.mu.RLock()
	enabled := n.enabled
	base := n.baseURL
	n.mu.RUnlock()
	if !enabled {
		return
	}
	u := base + "/" + url.PathEscape(title) + "/" + url.PathEscape(body)
	resp, err := n.client.Get(u)
	if err != nil {
		log.Printf("[bark] 推送失败: %v", err)
		return
	}
	resp.Body.Close()
}
