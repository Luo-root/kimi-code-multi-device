# kimi-code-multi-device

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
│                            多端广播·持久化·心跳  │
└───────────────────────────┬──────────────────┘
                            │ Tailscale / 本地 WS
                            ▼
              手机 (Flutter, 纯视图) + Bark 门铃
```

## 技术栈

- **中继**：Go（ACP client over stdio，WebSocket 对端）
- **手机端**：Flutter（iOS 首发）
- **数据通道**：Tailscale ｜ **锁屏叫醒**：Bark（v1）/ APNs（v2）

## 仓库结构

| 目录 | 说明 |
|---|---|
| `docs/` | 产品设计定稿、架构决策 |
| `relay/` | Go 中继（v1 核心） |
| `app/` | Flutter 手机端 |
| `probe/` | v0 探针与地基实测（演进史） |

## 开发路线

- [x] **v0** 地基验证（ACP 可驱动 / 流式 / reject 真阻断 / 单进程多会话）
- [ ] **Phase 0** 命门实测（set mode/model · slash 发送 · MCP 热重载）
- [ ] **Phase 1** 中继内核
- [ ] **Phase 2** Flutter App
- [ ] **Phase 3** 联调 + v1 验收

详见 [`docs/design-spec.md`](docs/design-spec.md)。

## License

MIT