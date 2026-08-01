// Package bark 是 §08 锁屏门铃：中继调 Bark API 弹系统级通知。
// 通知只当门铃、不传会话内容（原则 2：数据不出机器；命令原文绝不进推送）。
package bark

import (
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Notifier 发 Bark 推送。URL 为空则静默（未配置门铃）。
// URL 形如 https://api.day.app/{key}，Notify 追加 /{title}/{body}。
type Notifier struct {
	baseURL string
	client  *http.Client
	enabled bool
}

// New 从环境变量 BARK_URL 读取配置；为空则禁用（静默）。
func New() *Notifier {
	base := strings.TrimRight(os.Getenv("BARK_URL"), "/")
	return &Notifier{
		baseURL: base,
		client:  &http.Client{Timeout: 4 * time.Second},
		enabled: base != "",
	}
}

// Notify 发一条门铃。title/body 都不应含会话内容（命令、输出）。
// 失败仅记日志，不影响主流程（best-effort）。
func (n *Notifier) Notify(title, body string) {
	if !n.enabled {
		return
	}
	u := n.baseURL + "/" + url.PathEscape(title) + "/" + url.PathEscape(body)
	resp, err := n.client.Get(u)
	if err != nil {
		log.Printf("[bark] 推送失败: %v", err)
		return
	}
	resp.Body.Close()
}
