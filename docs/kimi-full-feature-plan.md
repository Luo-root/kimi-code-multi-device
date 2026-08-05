# kimi-code 全功能接入方案

> 姊妹篇：`docs/multi-agent-roadmap.md`（relay 多 agent 兼容方向）。
> 本文聚焦：**如何让 relay + app 完整复现 kimi code 在终端 / TUI / `kimi web` 中提供的全部功能**，而不只限于 ACP 标准通道。

## 1. 目标

ACP 是「任何支持 ACP 的 agent」的通用主通道，已覆盖 kimi code 的全部运行时交互。
但 kimi code 本地进程还提供了一整套 **ACP 未暴露** 的会话管理功能（rename / fork / export / archive / delete / createdAt）——这些在 `kimi web`（本机网页服务）里可用，证明 kimi 本地已实现，只是没放进 ACP。

目标：**远程控制体验不弱于本地终端**——上述功能也能在 app 里用上。

## 2. 现状盘点

### 2.1 已通过 ACP 覆盖（运行时，relay 已实现）
- `session/new` `session/list` `session/resume`
- `session/prompt` `session/cancel`
- `session/permissions/request` + decision
- `session/setMode` (yolo/auto/plan/manual)
- `session/setConfigOption` / `set_model`（等价 `setConfigOption(configId=model)`）
- `session/update` 原样透传（thought / message / tool / tool_update / config_option / available_commands）
- history replay（relay 启动自动下推 `session.list`）

### 2.2 kimi code 提供、但 ACP 未暴露（gap #1 / gap #2）
| 功能 | kimi web 是否可用 | ACP 是否暴露 | 当前 app 处理 |
|---|---|---|---|
| 重命名 rename | ✅ | ❌ | 隐藏（TODO gap #2） |
| 分叉 fork | ✅ | ❌ | 隐藏（TODO gap #2） |
| 导出 export | ✅ | ❌ | 隐藏（TODO gap #2） |
| 归档 archive | ✅ | ❌ | 端侧 shared_preferences 兜底（非 kimi 原生） |
| 删除 delete | ✅ | ❌ | 未实现 |
| 创建时间 / 元信息 createdAt | ✅ | ❌（无 archivedAt/createdAt 字段） | 用 updatedAt 近似 |

> 关键修正（2026-08-05）：这些不是「kimi 没能力」，而是「kimi 没把会话管理放进 ACP」。
> `kimi web` 是 kimi code 启动的**本机网页服务**（见 `docs/design-spec.md:91`），直接读写本地会话存储。
> 因此缺口本质 = **ACP 协议未开放会话管理**，而非 kimi 能力缺失。

### 2.3 控制面辨析：UI 映射 CLI 子命令 ≠ 复刻原生体验

用户曾问「UI 直接映射 kimi-code CLI 命令能否完美复刻原生体验」。对照官方 CLI 参考（https://www.kimi.com/code/docs/kimi-code-cli/reference/kimi-command.html）结论：**不能，且 CLI 不是正确的映射层。**

**原因 1 — 原生体验 = TUI 交互式会话，CLI 里没有「按次」的实时控制命令。**
CLI 子命令分两类：
- ① 一次性管理命令：`export` / `login` / `provider` / `doctor` / `upgrade` / `migrate` / `vis`；
- ② 启动会话的方式：`kimi` / `kimi --session` / `kimi -p "..."`（非交互单次 prompt，`--output-format stream-json` 可流式）。
**没有「发一条消息」「批准一个权限」这种按次的 CLI 命令**——这些在原生体验里就是往 TUI 打字。要远程驱动实时行为，正确通道是 **ACP（`kimi acp`）**，或 `kimi web` 的实时/管理接口，不是 CLI 子命令。

**原因 2 — CLI 子命令根本没覆盖 rename/fork/archive。**
官方 CLI 参考中 `kimi` 子命令只有 `login / acp / web / doctor / export / migrate / upgrade / provider / vis`，**无 `kimi rename` / `kimi fork` / `kimi archive`**。这三个只活在 TUI 斜杠命令和 `kimi web` 的 REST API。所以「UI→CLI」连用户截图里的三个菜单都覆盖不了，仍要另找路。

**原因 3 — 比 CLI 更好的管理通道是 `kimi web` 的 HTTP 调试 RPC API。**
`kimi web` 同一进程挂载 REST + WebSocket(transcript) + web UI。**实测（2026-08-05，kimi 0.32.0）+ 源码核对（2026-08-05 订正）关键结论**：
- `GET /openapi.json` 与 `GET /asyncapi.json` 均返回 **HTTP 200 但空 body（size=0）**——0.32.0 下这两个自描述端点**并未真正提供 schema**，不能依赖。
- 接口面靠 `GET /api/v1/debug/channels`（需 `--debug-endpoints` 启动）拿 **181 个 service 的全量方法目录**（即 `agent-core-v2` 的各 Service，如 `sessionLifecycleService` / `sessionMetadata` / `sessionExportService`）。
- **会话管理（rename/fork/export/archive/delete/restore）全部走 HTTP 调试 RPC，不是 REST、也不是 WebSocket**。REST 的 `POST /api/v1/sessions/{id}/{action}` 对 archive/rename/restore/fork 显式返回 `unsupported action`，`DELETE` 404——REST 只覆盖只读/列表/新建/文件/fs/终端。而 `/api/v1/ws` 是**独立的 transcript 增量通道**（实时消息流），与管理 RPC 无关；v2 的 `/api/v2/ws` 事件 socket 已被移除，service 无事件推送。
- 信封（已核对 `apps/kimi-inspect/src/channel/proxyChannel.ts`）：`POST /api/v1/debug[/session/:sid]/:service/:method`，body=参数数组 JSON，响应 `{code,msg,data,request_id}`，`code≠0` 抛错。详见 `docs/probe/kimi-web-api.md` §3。
因此「管理通道」应理解为 **`kimi web` 的 HTTP 调试 RPC**，CLI 子命令与公开 REST 都覆盖不全。

**结论**：
- 实时对话体验（thinking 流 / 工具调用 / 权限弹窗 / mode / config）→ 只能靠 **ACP** 复刻，CLI 做不到（`kimi web` 的 transcript WS 是内部实时流，relay 走 ACP 即可）。
- 管理类一次性操作（rename/fork/export/archive/delete）→ **`kimi web` 的 HTTP 调试 RPC** 能做（CLI 连 rename/fork/archive 都没有）。
- 因此「完美复刻原生体验」的正确架构 = **ACP（实时）+ `kimi web` HTTP 调试 RPC（管理）**，而非「UI 映射 CLI」。CLI 映射只是管理通道里一个可选的、覆盖不全的粗粒度实现方式。

## 3. 架构：双通道

```
                 ┌─────────────────────────────────────┐
   Flutter app   │            relay (Go)               │
   (远程)   ─────▶│                                     │
                 │  ① ACP 主通道 ──▶ kimi code (ACP)    │  runtime: prompt/cancel/permission/mode/config/update
                 │  ② 本机管理通道 ─▶ kimi 本地服务/存储 │  mgmt: rename/fork/export/archive/delete/createdAt
                 └─────────────────────────────────────┘
                         同机（自托管假设）
```

- **通道 ① ACP**：已实现，任意 ACP agent 通用，不动。
- **通道 ② 本机管理通道**（新增）：补全 ACP 未暴露的会话管理操作。

### 3.1 通道 ② 的两条实现路径

**路径 A — 直连 `kimi web` 本地 HTTP 调试 RPC（推荐）**
- relay 用 **HTTP 客户端** 打 `kimi web` 的 `/api/v1/debug` 表面（或 relay 代启 `kimi web --debug-endpoints`），按 `POST /api/v1/debug/session/:sid/:service/:method` 调用 `sessionLifecycleService.*` / `sessionMetadata.*` / `sessionExportService.*` 完成管理操作。
- 复用 kimi 自身 fork/export 语义，避免我们重复实现导致不一致。
- **`kimi web` 实测可探测机制（2026-08-05，kimi 0.32.0；信封经源码订正）**：
  - 默认端口 `58627`，被占用自动 +1（58628、58629…）；`--port` 可指定。
  - 默认绑定 `127.0.0.1`（仅本机）；`--host 0.0.0.0` 才对外（需谨慎）。
  - 启动横幅打印 **bearer token**（形如 `.../#token=xxxx`）；实测**两次启动 token 不变（跨重启稳定）**，但 **`~/.kimi-code/server.token` 文件在 0.32.0 不存在**——relay 应在启动 `kimi web` 时捕获其 stdout 横幅读取 token，或探测已运行实例。
  - 运行实例注册目录 `~/.kimi-code/server/instances/` 同样未实测到（不要依赖）。
  - **接口面探测靠**：`GET /api/v1/debug/channels`（需 `--debug-endpoints` 启动）拿 181 个 service 的全量方法目录；信封见 `docs/probe/kimi-web-api.md` §3.0。`/openapi.json`、`/asyncapi.json` 在 0.32.0 是空体，不可用；`/api/v1/ws` 仅 transcript 增量通道，与管理无关。
  - 鉴权：HTTP 用 `Authorization: Bearer <token>` 头；loopback 下默认安全，**不要**开 `--dangerous-bypass-auth`（关掉全部鉴权，危险）。
- 注意：管理操作是 **HTTP 调试 RPC，既不是 REST 也不是 WS**。REST 仅用于只读/列表/新建/文件/fs/终端；`archive/rename/fork/delete/restore/export` 走 `sessionLifecycleService` / `sessionMetadata` / `sessionExportService` 等 service（经 `/api/v1/debug`）。

**路径 B — relay 直接读写 kimi 本地会话存储**
- relay 自己实现 rename/fork/export/archive/delete，操作 kimi 的会话目录/DB。
- 风险：存储格式是 kimi 内部实现，版本升级易碎；fork 要「复制完整上下文」，只复制历史文件不一定等价。
- 仅作为路径 A 不可用时的降级方案。

> 推荐路径 A：因为会话管理的「真相」在 kimi 进程内，转发比重新实现更稳、语义更对。

### 3.2 订正：不存在「WS 单通道超级替代品」

早期探针误判"181 个 channel 同在一根 WS 上、可单通道替代 ACP"。经核对源码（`apps/kimi-inspect/src/channel/client.ts` + `proxyChannel.ts`）订正：

- 那 181 个"channel"是 **`/api/v1/debug` 调试 RPC 的 service 目录**，经 **HTTP ProxyChannel** 调用，**不是 WebSocket 帧**。
- v2 的 `/api/v2/ws` 事件 socket 已被移除，service 无事件推送（`listen` 直接抛错）；`/api/v1/ws` 仅承载 transcript 增量（实时消息流），与管理无关。
- 因此"kimi web WS 覆盖 ACP 全部运行时 + 管理"的设想**不成立**。实时运行时仍由 **ACP（通道①）** 负责，会话管理由 **HTTP 调试 RPC（通道②）** 负责，二者分工明确、互不替代。

> 结论：维持 §3 双通道（ACP 实时 + HTTP 调试 RPC 管理），不采用单通道 WS 替代方案。

## 4. 风险与缓解

| 风险 | 缓解 |
|---|---|
| `kimi web` 本地 API 未文档化，可能随版本变动 | probe 阶段摸清形态；relay 加一层适配 + 版本探测，接口变动时快速定位 |
| 直连本机服务需 relay 与 kimi 同机 | 本产品本就假设自托管同机（设计 spec §03），可接受 |
| fork/export 的「完整上下文复制」语义 | 依赖 kimi 实现，relay/app 只做转发与展示，不重造 |
| `kimi web` 服务未常驻 | relay 可在收到管理请求时按需启动 `kimi web`，或探测已运行实例 |

## 5. 落地步骤

1. **probe（第一步，已完成主体，2026-08-05）**：
   - 运行 `kimi web --no-open --debug-endpoints`，捕获 stdout 横幅里的 bearer token。
   - 已实测：`GET /api/v1/debug/channels` 拿 181 个 service 全量方法目录；`WS /api/v1/ws` 仅 transcript 增量通道；REST 的 `archive/rename/fork/delete/restore/export` 均 `unsupported action`/404，**管理走 HTTP 调试 RPC（非 WS）**。信封见 `docs/probe/kimi-web-api.md` §3.0。
   - 产出 `docs/probe/kimi-web-api.md`（含路由清单、channel 摘要、WS 握手样本、REST 实测结果）。
   - **信封已确认（源码）**：`POST /api/v1/debug/session/:sid/:service/:method`，body=参数数组，响应 `{code,msg,data,request_id}`；待补 = 实跑 invoke 验证 + `sessionExportService.export` 入参/返回 + 确认 `--debug-endpoints` 是否必需（或新版 v1 REST 是否可用）。
2. **relay 管理通道**：新增 `internal/relay/management`（或并入 server）封装 rename/fork/export/archive/delete/createdAt；app 通过既有 Down/Up 协议扩展新 message 类型触发。
3. **app 菜单恢复**：解除 `home_shell.dart` 的 TODO(gap #2)，恢复隐藏的 rename/fork/export/delete 菜单项，接到管理通道；createdAt 接入列表展示。
4. **验证**：接入真实 kimi，验证全功能可用，且 ACP 通道不变（仍支持任意 ACP agent）。

## 6. 验收标准

- app 中 rename / fork / export / archive / delete / createdAt 全部可用，体验对齐 `kimi web`。
- ACP 主通道零改动，仍兼容任意 ACP agent（与 `multi-agent-roadmap.md` 不冲突：多 agent 方向用 ACP，kimi 专属增强用通道 ②）。
- 任一 kimi 版本接口变动时，relay 可快速定位并适配，不拖垮主流程。

## 7. 与 multi-agent 路线图的关系

- `multi-agent-roadmap.md` = 「**纵向**」：让 relay 适配更多 ACP agent（能力协商、Elicitation、渲染通用化）。
- 本文 = 「**横向**」：让 kimi code 这一个 agent 的功能被**完全**覆盖（补齐 ACP 之外的本地管理通道）。
- 两者正交：通道 ① 服务所有 agent，通道 ② 仅服务 kimi code（或任何暴露本地管理 API 的 agent）。
