# Probe: kimi-code `kimi web` 本地接口面

> 探针日期：2026-08-05 ｜ kimi 版本：`0.32.0` ｜ 探测环境：Windows，二进制 `~/.kimi-code/bin/kimi.exe`
> 探测方式：① 启动 `kimi web --no-open --debug-endpoints`；② 读启动日志拿 bearer token；③ curl 探 REST；④ 从二进制提取 `/api/v1/*` 路由字符串；⑤ `GET /api/v1/debug/channels` 拿 RPC 全量方法目录；⑥ `websockets` 连 `/api/v1/ws` 验证握手。
> ⚠️ **管理通道结论已订正（2026-08-05 源码核对）**：会话管理走 **HTTP 调试 RPC（`/api/v1/debug`，ProxyChannel）**，**不是 WebSocket-RPC**。本文件最初误判为 WS，此处统一纠正；正确信封见 §3.0。

## 0. 启动与鉴权

```bash
kimi web --no-open --log-level info --debug-endpoints
# 默认监听 http://127.0.0.1:58627 （--host 可绑 0.0.0.0）
# 启动日志打印 bearer token，例如：
#   Kimi server: http://127.0.0.1:58627/#token=<BEARER_TOKEN>
```

- **鉴权**：所有 REST/WS 路由需 `Authorization: Bearer <token>` 头（WS 也可用 `?token=` query，但实测 query 方式返回 401，必须用 header）。token 跨重启持久（同一台机器多次启动 token 不变）。
- **危险开关**：`--dangerous-bypass-auth` 关闭鉴权并会在 `/api/v1/meta` 的 `dangerous_bypass_auth` 暴露 true；仅可信网络用。生产不要开。
- **默认关闭的高危路由**：`/api/v1/shutdown`、`/api/v1/terminals/*` 在非 loopback 绑定时默认 404，除非显式 `--allow-remote-shutdown` / `--allow-remote-terminals`。
- **⚠️ 管理 RPC 前提**：`/api/v1/debug/*` 调试表面需 `--debug-endpoints` 启动（且 loopback）。relay 侧要么代启时带该 flag，要么要求用户以该 flag 启动 `kimi web`；否则调试 RPC 404。

## 1. `/api/v1/meta`（能力声明）

```json
{
  "server_version": "0.32.0",
  "capabilities": {
    "websocket": true, "file_upload": true, "fs_query": true,
    "mcp": true, "tasks": true, "terminal": true
  },
  "backend": "v2",
  "dangerous_bypass_auth": false,
  "experimental_flags": {
    "secondary-model": false, "tool-select": false,
    "persistence_minidb_readmodel": false
  }
}
```

→ 文件上传、fs 查询、mcp、tasks、terminal 全部为真；后端是 v2。

## 2. REST 接口面（实测）

| 方法 + 路径 | 实测 | 说明 |
|---|---|---|
| `GET /api/v1/meta` | ✅ 200 | 能力/版本/flags（上节） |
| `GET /api/v1/healthz` | ✅ 200 `{ok:true}` | 健康检查 |
| `GET /api/v1/sessions` | ✅ 200 | 会话列表；每项含 `id, workspace_id, title, created_at, updated_at, archived, pending_interaction, metadata.cwd, usage, permission_rules, message_count, last_seq` |
| `GET /api/v1/sessions/{id}` | ✅ 200 | 会话详情（同上字段） |
| `GET /api/v1/sessions/{id}/messages` | ✅ 200 `{items:[], has_more}` | 消息列表 |
| `GET /api/v1/sessions/{id}/export` | ❌ 404 | **导出不走这个 REST 路径**（见 §4，是调试 RPC） |
| `POST /api/v1/sessions` | ✅ 200（body 需 `workspace_id`+`metadata.cwd`=`工作区根`） | 新建会话 |
| `PATCH /api/v1/sessions/{id}` | ❌ 404 | REST 不接管整对象 PATCH |
| `POST /api/v1/sessions/{id}/archive` | ❌ `unsupported action: archive` | **归档是调试 RPC（HTTP）** |
| `POST /api/v1/sessions/{id}/restore` | ❌ `unsupported action: restore` | **恢复是调试 RPC（HTTP）** |
| `POST /api/v1/sessions/{id}/rename` | ❌ `unsupported action: rename` | **重命名是调试 RPC（HTTP）** |
| `POST /api/v1/sessions/{id}/fork` | ❌ `unsupported action: fork` | **分叉是调试 RPC（HTTP）** |
| `DELETE /api/v1/sessions/{id}` | ❌ 404 | **删除是调试 RPC（HTTP）** |
| `GET /api/v1/files` / `/api/v1/files/{file_id}` | 路由存在于二进制 | 文件上传/读取 |
| `GET /api/v1/fs:browse` `/fs:home` `/fs::browse` `/fs::content` | 路由存在于二进制 | fs 浏览/内容（对应 `fs_query`） |
| `GET /api/v1/terminals/` | 路由存在（默认 loopback 下 404） | PTY 终端（对应 `terminal`） |
| `GET /api/v1/debug/channels` | ✅ 200（需 `--debug-endpoints`） | **调试 RPC 服务目录（181 个 channel，HTTP）** |
| `GET /api/v1/debug/*` | 路由存在 | 测试自省（默认关） |
| `WS  /api/v1/ws` | ✅ 握手 `server_hello` | **transcript 增量通道（实时消息流，与管理 RPC 无关）** |
| `POST /api/v1/shutdown` | 路由存在（默认 404） | 关服务 |

**关键结论**：REST 只覆盖**只读/列表/新建/文件/fs/终端**；**所有会话生命周期管理（archive/rename/fork/delete/restore/export）都不在公开 REST 上**，REST 的 `{id}/{action}` 路由显式返回 `unsupported action`。这些操作只能通过 **HTTP 调试 RPC（`/api/v1/debug` 的 ProxyChannel）** 完成（见 §3）。
> 注：`packages/kap-server/src/routes/sessions.ts` 在 main 分支已实现 `POST /sessions/{id}/archive|restore|fork|...` 动作路由，但本地 `0.32.0` 实测仍回 `unsupported action`——属**版本差异**。新版 kimi 或可走公开 v1 REST；`0.32.0` 及更早版本须走调试 RPC。

## 3. 调试 RPC 接口面（核心）：HTTP ProxyChannel（**非 WebSocket**）

> ⚠️ **结论订正（重要）**：早期探针误判"会话管理走 WebSocket-RPC"。经核对 kimi-code 源码（`apps/kimi-inspect/src/channel/client.ts` + `proxyChannel.ts`），**管理操作走 HTTP，不是 WS**：
> - 各 service 方法（archive/rename/fork/delete/restore/export…）经 **`/api/v1/debug` 的 HTTP ProxyChannel** 调用；v2 的 `/api/v2/ws` 事件 socket 已被移除，service 无事件推送（`listen` 直接抛错）。
> - `/api/v1/ws` 是**独立的 transcript 增量通道**（实时消息流），与管理 RPC 完全无关。

`GET /api/v1/debug/channels`（`--debug-endpoints` 开）返回 **181 个 channel**，每个含 `name / scope / domain / methods[]`。这是 **debug RPC 服务目录**（`agent-core-v2` 的各 Service），经 HTTP 调用。

### 3.0 调用信封（已从源码确认 `proxyChannel.ts`）

对任意 service 方法，客户端行为：

- **URL**：`POST http://127.0.0.1:58627/api/v1/debug[/session/:sid[/agent/:aid]]/:service/:method`
  - scope 前缀：`/session/:sid`（会话级）、`/workspace/:wid`（工作区级）、`/core`（全局）、`/agent/:aid`（agent 级）
  - `:service` = Service 名（例：`sessionLifecycleService` / `sessionMetadata` / `sessionExportService`）
  - `:method` = 方法名（例：`archive` / `setTitle` / `fork` / `delete` / `restore` / `export`）
- **Body**：`JSON.stringify(args)` —— 方法参数的**完整数组**（例：archive → `["<sessionId>"]`；setTitle → `["<new title>"]`；fork → `[{...opts}]`）
- **Headers**：`content-type: application/json` + `authorization: Bearer <token>`
- **响应信封**：`{ "code": 0, "msg": "", "data": <T>, "request_id": "...", "details": ... }`；`code !== 0` 抛 `RPCError`（`code` 即错误码，`msg` 描述）

> ⚠️ **接入前提**：debug RPC 表面需 `kimi web --debug-endpoints` 启动（且 loopback）。relay 侧要么代启时带该 flag，要么要求用户以该 flag 启动；否则 `/api/v1/debug/*` 404。

### 3.1 会话管理相关 service（本项目最关心）

| channel（scope / domain） | 关键方法 |
|---|---|
| `sessionLifecycleService`（workspace / sessionLifecycle） | `archive(sessionId)`、`delete(sessionId)`、`fork(opts)`、`restore(sessionId, opts)`、`resume(sessionId, opts)`、`create(opts)`、`createChild(opts)`、`close(sessionId)`、`get(sessionId)`、`list()`、`duplicateCronTasks`…（共 24） |
| `sessionMetadata`（session / sessionMetadata） | `setTitle(title)`（=重命名）、`setArchived(archived)`、`update(patch)`、`read()`、`load()`（共 10） |
| `sessionExportService`（app / sessionExport） | `export(input, options)`、`liveSession(sessionId)`、`flushLiveSession(summary)`（共 4） |
| `sessionActivityView`（session / sessionActivity） | `current()`、`folds()`、`state()`、`onActivity(agentId,snapshot)`、`recompute(cause)`（共 7） |
| `sessionInteractionService`（session / interaction） | `request(req)`、`respond(id, response)`、`listPending(kind)`、`recordResolved(id,response,origin)`（共 15）—— **权限交互** |
| `sessionQuestionService`（session / question） | `request(req, options)`、`answer(id, result)`、`dismiss(id)`、`listPending()`（共 5）—— **askUserQuestion** |
| `sessionTodoService`（session / todo） | `setTodos(todos)`、`getTodos()`、`clear()`（共 8） |

### 3.2 运行时 service（注意：这些经 transcript `/api/v1/ws`，不在 debug RPC）

| channel(service) | 含义 |
|---|---|
| `agentPromptService`（domain=prompt，18 方法） | 提交 prompt、取消、流式控制 |
| `agentActivityView` / `agentStateService` | 思考流、工具调用、状态 |
| `sessionInteractionService` | 权限请求/响应（对应 ACP `session/request_permission`） |
| `sessionQuestionService` | 结构化追问（对应 ACP 缺失的 `elicitation`） |
| `agentPlanService`（15）、`agentGoalService`（65）、`agentTaskService`（61） | plan / goal / task |
| `agentToolExecutorService`、`agentToolApprovalService`、`agentPermission*` | 工具执行/审批/权限 |
| `workspaceFsService`（24）、`hostFileSystem`（13）、`hostTerminalService` | fs / 终端 |

> 上表的运行时能力由 **ACP（通道①）** 已覆盖，relay 不需要再碰 `/api/v1/ws`。其中 `session/request_permission` / `elicitation` 缺失项属于 `multi-agent-roadmap.md` 的议题，与本文的 **HTTP 调试 RPC 管理通道** 正交。早期"kimi web WS 单通道驱动完整原生体验、可替代 ACP"的推断**已订正为不成立**（v2 事件 socket 已移除、`/api/v1/ws` 仅 transcript 增量）。

## 4. 导出（export）落在哪

二进制里 `/api/v1/sessions/{session_id}/export` 是字符串，但 REST 实测 404；`sessionExportService.export(input, options)` 是 **debug RPC 方法**（HTTP）。结论：**导出走 HTTP 调试 RPC，不走 REST、也不走 WS**。

- 调用：`POST /api/v1/debug/session/:sid/sessionExportService/export`，body = `[input, options]`。
- 具体 `input`/`options` 形状与返回格式（markdown / json?）需实跑确认（见 §6 待办）。

## 5. 对 relay/app 架构的影响（重要修正）

之前 `docs/kimi-full-feature-plan.md` 把"通道② 本机管理通道"设想为**直连 kimi web 的本地 HTTP/REST API**；本次实测进一步修正为 **HTTP 调试 RPC（非 REST、非 WS）**：

1. **管理操作是 HTTP 调试 RPC，不是 REST，也不是 WebSocket。** 想恢复「重命名/分叉/归档/导出/删除」菜单，relay 用一个 **HTTP 客户端** 打 `http://127.0.0.1:58627/api/v1/debug/session/:sid/:service/:method`（信封见 §3.0），而不是发 REST 请求、也不是开 WebSocket。
2. **不存在"WS 单通道替代 ACP"**：v2 的 `/api/v2/ws` 事件 socket 已移除，`/api/v1/ws` 仅 transcript 增量；实时运行时仍由 **ACP（通道①）** 负责，管理由 **HTTP 调试 RPC（通道②）** 负责，分工明确（详见 `docs/kimi-full-feature-plan.md` §3.2 订正）。
3. **鉴权**：relay 读启动 token 即可（token 跨重启持久；也可在 relay 侧代启 `kimi web` 并捕获其 stdout token）。loopback 下默认安全，不要开 `--dangerous-bypass-auth`。
4. **`--debug-endpoints` 前提**：debug RPC 表面需 `kimi web --debug-endpoints` 启动；relay 代启或要求用户以该 flag 启动。无此 flag 时 `/api/v1/debug/*` 404。

## 6. 待办（后续探针/实现）

- [x] ~~反编译 WS RPC 信封~~ → **已通过源码确认，且结论订正为 HTTP ProxyChannel**（见 §3.0）：`POST /api/v1/debug/session/:sid/:service/:method`，body=参数数组，响应 `{code,msg,data,request_id}`。
- [ ] **实跑验证 invoke**：起 `kimi web --debug-endpoints`，对真实/throwaway 会话 `POST /api/v1/debug/session/:sid/sessionLifecycleService/archive`（body `["<sid>"]`）确认 200 + `code:0`；并验证 `delete` 清理 `PROBE_THROWAWAY` 会话。
- [ ] 确认 `sessionExportService.export` 的入参 `input/options` 与返回格式（markdown/json？）。
- [ ] 确认接入形态：debug RPC 是否必须 `--debug-endpoints`（是）；并评估新版 kimi 的公开 v1 REST `POST /sessions/{id}/archive`（main 已实现，0.32.0 仍 `unsupported action`）是否可作为更简单的免 flag 路径。

## 7. 探针产物（本仓库）

- `docs/probe/kimi-web-api.md`（本文件）
- 原始 `debug/channels` 全量 JSON 已抓取（181 channel），按需可重新生成：
  `curl -H "Authorization: Bearer <token>" http://127.0.0.1:58627/api/v1/debug/channels`
- `probe/web/kimi_web_channels.json`（181 channel 全量方法目录）
- `probe/web/kimi_web_routes.txt`（二进制提取路由）
