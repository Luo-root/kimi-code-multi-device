package main

import (
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/Luo-root/kimi-code-multi-device/relay/internal/relay"
)

func main() {
	addr := ":7331"
	if v := os.Getenv("RELAY_ADDR"); v != "" {
		addr = v
	}

	r := relay.New()
	if err := r.Start(); err != nil {
		log.Fatalf("[relay] 启动失败: %v", err)
	}
	defer r.Close()

	http.HandleFunc("/ws", r.HandleWS)

	// 优雅退出：收到中断信号时关 acp 子进程。
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Println("[relay] 收到退出信号，关闭…")
		r.Close()
		os.Exit(0)
	}()

	log.Printf("[relay] WebSocket 监听 %s （浏览器打开 probe/web/index.html）", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("[relay] http: %v", err)
	}
}
