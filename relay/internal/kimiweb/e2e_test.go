package kimiweb

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"
)

// 端到端验证：对真实的 `kimi web` 跑一遍管理动作，确认 REST :action 契约没有漂移。
//
// 默认跳过（需要本机装有 kimi）。启用方式：
//
//	KIMIWEB_E2E=1 go test ./internal/kimiweb/ -run E2E -v
//
// 可选环境变量：
//
//	KIMIWEB_E2E_PORT=58699    指定端口（默认 58699，避开 kimi 默认的 58627）
//	KIMIWEB_E2E_BIN=/path/kimi 指定 kimi 可执行文件
//
// 注意（单写者约束）：运行前请确保没有别的 kimi web 在跑，否则写操作会返回
// 50001 storage write failed —— 那不是本包的 bug，是 kimi 存储的独占写锁。
// 全包共用一个 provider / kimi web 实例。
// 这既贴近 relay 的真实用法（全程只有一个 SpawnProvider），也避免反复起停
// 撞上「上一个实例的端口还没释放」以及单写者写锁冲突。
var (
	e2eOnce     sync.Once
	e2eProvider *SpawnProvider
	e2eClient   *Client
)

// TestMain 负责在全部用例跑完后回收代启的 kimi web。
func TestMain(m *testing.M) {
	code := m.Run()
	if e2eProvider != nil {
		if err := e2eProvider.Close(); err != nil {
			fmt.Fprintf(os.Stderr, "关闭 kimi web: %v\n", err)
		}
	}
	os.Exit(code)
}

func e2e(t *testing.T) *Client {
	t.Helper()
	if os.Getenv("KIMIWEB_E2E") == "" {
		t.Skip("跳过 e2e：设置 KIMIWEB_E2E=1 并确保本机已安装 kimi")
	}
	e2eOnce.Do(func() {
		port := 58699
		if v := os.Getenv("KIMIWEB_E2E_PORT"); v != "" {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				port = n
			}
		}
		e2eProvider = &SpawnProvider{BinPath: os.Getenv("KIMIWEB_E2E_BIN"), Port: port}
		e2eClient = New(e2eProvider)
	})
	return e2eClient
}

// TestE2E_ArchiveRestoreRoundTrip 归档后立刻恢复，保证不改变用户数据的最终状态。
func TestE2E_ArchiveRestoreRoundTrip(t *testing.T) {
	c := e2e(t)

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	sid := e2eFirstSessionID(ctx, t, c)
	t.Logf("目标会话: %s", sid)

	if err := c.Archive(ctx, sid); err != nil {
		t.Fatalf("Archive: %v", err)
	}
	t.Log("Archive 成功")

	// 立即恢复，避免在用户的真实数据里留下副作用。
	if err := c.Restore(ctx, sid, nil); err != nil {
		t.Fatalf("Restore（会话已被归档，请手动恢复 %s）: %v", sid, err)
	}
	t.Log("Restore 成功，会话状态已还原")
}

// TestE2E_Export 导出会话 zip 到临时目录，验证真的收到了二进制流。
func TestE2E_Export(t *testing.T) {
	c := e2e(t)

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	sid := e2eFirstSessionID(ctx, t, c)
	res, err := c.Export(ctx, sid, ExportOpts{OutputPath: t.TempDir()})
	if err != nil {
		t.Fatalf("Export: %v", err)
	}
	if res.SizeBytes <= 0 {
		t.Fatalf("导出文件为空: %+v", res)
	}
	st, err := os.Stat(res.ZipPath)
	if err != nil {
		t.Fatalf("导出文件不存在: %v", err)
	}
	t.Logf("Export 成功: %s (%d 字节)", res.ZipPath, st.Size())
}

// TestE2E_DeleteStillUnsupported 验证 kimi 0.32.0 仍未提供删除接口。
// 注意：重命名（rename）已确认可用（走 POST /profile，见 TestRename_UsesRESTProfile
// 与 relay server.go 的 ManageActionRename 派发），故此处只校验 delete。
func TestE2E_DeleteStillUnsupported(t *testing.T) {
	c := e2e(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	sid := e2eFirstSessionID(ctx, t, c)

	// 直接打 :delete，绕过本包的 ErrUnsupported 短路，确认 kimi 侧仍未提供删除接口。
	_, err := c.sessionAction(ctx, sid, "delete", nil)
	if err == nil {
		t.Errorf("kimi 现在支持 :delete 了！应更新 client.go 放开删除动作")
	}
	t.Logf(":delete 仍不支持 -> %v", err)
}

// e2eFirstSessionID 取会话列表里的第一个会话 ID。
func e2eFirstSessionID(ctx context.Context, t *testing.T, c *Client) string {
	t.Helper()
	sessions, err := c.ListSessions(ctx)
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions) == 0 {
		t.Skip("kimi 里没有任何会话，跳过")
	}
	return sessions[0].ID
}
