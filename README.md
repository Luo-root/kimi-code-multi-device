# kimi-code-multi-device (SENTINEL)

> **一个遥控器，加一个哨兵。** 当你不在跑着 Kimi Code 的那台机器面前时，
> 你仍能指挥它，它也会在需要你时主动穿过锁屏找到你。

一个为 Kimi Code 打造的**多端客户端**：电脑上的 Go 中继持有会话状态（单一真相），
手机端（Flutter）作为纯视图，实现远程遥控、锁屏哨兵批准、会话漂移。

## 它解决什么

Kimi Code 默认假设你在场。但合盖、出门、骑车时，你够不着键盘、不知道它卡在哪、
不知道它跑没跑完。本产品把"不在场"变成可控：远程指挥、危险操作锁屏拍板、跑完主动告知。

## 架构

```
┌──────────── 跑 Kimi 的机器（电脑）──────────────┐
│  kimi acp ◄──stdio(ACP)──► 中继(Go, 常驻)     │
│                            会话状态·许可裁决    │
│                            多端广播·快照对齐·心跳 │
└───────────────────────────┬──────────────────┘
                            │ Tailscale / 本地 WS
                            ▼
              手机 (Flutter, 纯视图) + Bark 门铃
```

**三条铁律**：① 中继是唯一持状态者（`sid → state` map），手机/桌面只是视图；
② 中继 ↔ Kimi 走 stdio（ACP，newline-delimited JSON-RPC）；
③ 中继 ↔ 端走 WebSocket（双向实时，流下推、批准/指令上回）。

## 技术栈

- **中继**：Go（`gorilla/websocket` + `BurntSushi/toml`；ACP client over stdio，WebSocket 对端）
- **手机端**：Flutter（iOS 首发）+ `hux` 组件库（主题底座）+ `flutter_markdown` / `syntax_highlight`（Markdown / 代码块）+ `shared_preferences`（主题持久化）
- **锁屏叫醒**：Bark（v1）/ APNs（v2）
- **数据通道**：Tailscale ｜ 本地 WebSocket

## 仓库结构

| 目录 | 说明 |
|---|---|
| `docs/` | 产品设计定稿（`design-spec.md`，含分期验收表 §16、UX 修正记录、开放问题 §18） |
| `relay/` | Go 中继（v1 核心）：`cmd/relay` 入口 + `internal/{acp,bark,config,permit,relay,replay,risk,session}` |
| `app/` | Flutter 手机端（`lib/` 22 文件约 8.8k 行；`home_shell.dart` 为最大单体，待拆分） |
| `probe/` | v0 探针与地基实测（演进史）+ 扫描真实 `wire.jsonl` 的脚本 |

## 当前状态

- **中继内核已落地**：ACP 客户端、`sid → state` 会话状态机、许可裁决（`manual` 超时默认拒绝 / `yolo·auto` 自动放行 / `plan` 记异常）、多端广播、Bark 门铃、断线快照对齐、`generation` 计数区分主动重启与崩溃。
- **Flutter 端已落地**：活的流渲染（思考 / 回复 / 工具卡 / 批准卡）、级联配置菜单、会话抽屉与归档弹窗、明暗双主题（hux 中性主题、accent 为中性黑 `#1D1D1F`）、按消息复制、滚动防劫持、`停`/发送态联动。
- **测试**：relay 的 `acp` / `config` / `replay` 包有单测；app 约 50 个 `test()` 用例 + 2 个 ACP 探针（固化 Kimi 真实下行字段形态、记录能力缺口）。
- **已知风险**：`internal/relay/server.go`（约 659 行，编排中枢）暂无直接单测，是主要测试盲区；`home_shell.dart`（约 3592 行）为单体大文件，优先拆分对象。

## 开发路线

- [x] **v0** 地基验证（ACP 可驱动 / 流式 / reject 真阻断 / 单进程多会话）
- [x] **Phase 0** 命门实测（`set mode/model` ✅ · `slash` 发送 ✅；MCP 热重载 🔴 留 v1.5，见 `design-spec.md` §18）
- [x] **Phase 1** 中继内核（ACP client / 会话状态机 / 许可裁决 / 广播 / Bark / 快照）
- [x] **Phase 2** Flutter App（活的流 / 批准卡 / 配置菜单 / 抽屉归档 / 双主题）
- [ ] **Phase 3** 联调 + v1 验收（真机局域网连通、连用验收、待批准闭环亲历）

详见 [`docs/design-spec.md`](docs/design-spec.md)。

## License

MIT
