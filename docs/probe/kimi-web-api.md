# Probe: kimi-code `kimi web` 本地接口面

> 探针日期：2026-08-05 ｜ kimi 版本：`0.32.0` ｜ 探测环境：Windows，二进制 `~/.kimi-code/bin/kimi.exe`
> 探测方式：① 启动 `kimi web --no-open --debug-endpoints`；② 读启动日志拿 bearer token；③ curl 探 REST；④ 从二进制提取 `/api/v1/*` 路由字符串；⑤ `GET /api/v1/debug/channels` 拿 WS RPC 全量方法目录；⑥ `websockets` 连 `/api/v1/ws` 验证握手。

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
| `GET /api/v1/sessions/{id}/export` | ❌ 404 | **导出不走这个 REST 路径**（见 §4，是 WS RPC） |
| `POST /api/v1/sessions` | ✅ 200（body 需 `workspace_id`+`metadata.cwd`=`工作区根`） | 新建会话 |
| `PATCH /api/v1/sessions/{id}` | ❌ 404 | REST 不接管整对象 PATCH |
| `POST /api/v1/sessions/{id}/archive` | ❌ `unsupported action: archive` | **归档是 WS RPC** |
| `POST /api/v1/sessions/{id}/restore` | ❌ `unsupported action: restore` | **恢复是 WS RPC** |
| `POST /api/v1/sessions/{id}/rename` | ❌ `unsupported action: rename` | **重命名是 WS RPC** |
| `POST /api/v1/sessions/{id}/fork` | ❌ `unsupported action: fork` | **分叉是 WS RPC** |
| `DELETE /api/v1/sessions/{id}` | ❌ 404 | **删除是 WS RPC** |
| `GET /api/v1/files` / `/api/v1/files/{file_id}` | 路由存在于二进制 | 文件上传/读取 |
| `GET /api/v1/fs:browse` `/fs:home` `/fs::browse` `/fs::content` | 路由存在于二进制 | fs 浏览/内容（对应 `fs_query`） |
| `GET /api/v1/terminals/` | 路由存在（默认 loopback 下 404） | PTY 终端（对应 `terminal`） |
| `GET /api/v1/debug/channels` | ✅ 200（需 `--debug-endpoints`） | **WS RPC 全量方法目录（181 个 channel）** |
| `GET /api/v1/debug/*` | 路由存在 | 测试自省（默认关） |
| `WS  /api/v1/ws` | ✅ 握手 `server_hello` | **WebSocket RPC 主通道（见 §3/§4）** |
| `POST /api/v1/shutdown` | 路由存在（默认 404） | 关服务 |

**关键结论**：REST 只覆盖**只读/列表/新建/文件/fs/终端**；**所有会话生命周期管理（archive/rename/fork/delete/restore/export）都不在 REST 上**，REST 的 `{id}/{action}` 路由显式返回 `unsupported action`。这些操作只能通过 **WebSocket RPC** 完成。

## 3. WebSocket RPC 接口面（核心）

`GET /api/v1/debug/channels` 返回 **181 个 channel**，每个含 `name / scope / domain / methods[]`（含 `kind`=property\|method、`arity`、`params`）。这是驱动 web UI 的**完整实时+管理协议面**。

握手：
```json
{"type":"server_hello","timestamp":"...","payload":{
  "ws_connection_id":"conn_...","protocol_version":2,
  "max_event_buffer_size":1000,
  "capabilities":{"event_batching":false,"compression":false}}}
```

### 3.1 会话管理相关 channel（本项目最关心）

| channel（scope / domain） | 关键方法 |
|---|---|
| `sessionLifecycleService`（workspace / sessionLifecycle） | `archive(sessionId)`、`delete(sessionId)`、`fork(opts)`、`restore(sessionId, opts)`、`resume(sessionId, opts)`、`create(opts)`、`createChild(opts)`、`close(sessionId)`、`get(sessionId)`、`list()`、`duplicateCronTasks`…（共 24） |
| `sessionMetadata`（session / sessionMetadata） | `setTitle(title)`（=重命名）、`setArchived(archived)`、`update(patch)`、`read()`、`load()`（共 10） |
| `sessionExportService`（app / sessionExport） | `export(input, options)`、`liveSession(sessionId)`、`flushLiveSession(summary)`（共 4） |
| `sessionActivityView`（session / sessionActivity） | `current()`、`folds()`、`state()`、`onActivity(agentId,snapshot)`、`recompute(cause)`（共 7） |
| `sessionInteractionService`（session / interaction） | `request(req)`、`respond(id, response)`、`listPending(kind)`、`recordResolved(id,response,origin)`（共 15）—— **权限交互** |
| `sessionQuestionService`（session / question） | `request(req, options)`、`answer(id, result)`、`dismiss(id)`、`listPending()`（共 5）—— **askUserQuestion** |
| `sessionTodoService`（session / todo） | `setTodos(todos)`、`getTodos()`、`clear()`（共 8） |

### 3.2 实时控制面 channel（证明 kimi web WS 可单通道驱动完整原生体验）

| channel | 含义 |
|---|---|
| `agentPromptService`（domain=prompt，18 方法） | 提交 prompt、取消、流式控制 |
| `agentActivityView` / `agentStateService` | 思考流、工具调用、状态 |
| `sessionInteractionService` | 权限请求/响应（对应 ACP `session/request_permission`） |
| `sessionQuestionService` | 结构化追问（对应 ACP 缺失的 `elicitation`） |
| `agentPlanService`（15）、`agentGoalService`（65）、`agentTaskService`（61） | plan / goal / task |
| `agentToolExecutorService`、`agentToolApprovalService`、`agentPermission*` | 工具执行/审批/权限 |
| `workspaceFsService`（24）、`hostFileSystem`（13）、`hostTerminalService` | fs / 终端 |

→ **kimi web 的 WebSocket RPC 已经包含 prompt 提交、权限交互、结构化追问、流式、plan/task、fs/终端**——即 ACP 暴露的运行时能力 + 会话管理能力，**全部在一根 WS 上**。这对架构有重大影响（见 §5）。

## 4. 导出（export）落在哪

二进制里 `/api/v1/sessions/{session_id}/export` 是字符串，但 REST 实测 404；`sessionExportService.export(input, options)` 是 WS RPC 方法。结论：**导出走 WS RPC，不走 REST**。（具体 RPC 信封需进一步反编译，本次未打通。）

## 5. 对 relay/app 架构的影响（重要修正）

之前 `docs/kimi-full-feature-plan.md` 把"通道② 本机管理通道"设想为**直连 kimi web 的本地 HTTP/REST API**。本次实测修正为：

1. **管理操作是 WebSocket-RPC，不是 REST。** 想恢复「重命名/分叉/归档/导出/删除」菜单，relay 需要**再开一个到 `127.0.0.1:58627` 的 WebSocket 连接**，按 channel/method 调用 `sessionLifecycleService.*` / `sessionMetadata.*` / `sessionExportService.*`，而不是发 REST 请求。
2. **kimi web WS 可能是 ACP 的超级替代品**：它在一根 WS 上同时提供实时对话（prompt/权限/追问/流式）与会话管理。理论上 relay 可以**直接代理 kimi web 的 WS**（app ↔ relay ↔ kimi-web-WS），从而用一套协议覆盖"原生体验 + 管理"，而 ACP 只作为"agent 无关"的备选。这要把 §3.2 的 RPC 信封（client→server 调用格式）反编译清楚才能落地。
3. **鉴权**：relay 读启动 token 即可（token 跨重启持久；也可在 relay 侧代启 `kimi web` 并捕获其 stdout token）。loopback 下默认安全，不要开 `--dangerous-bypass-auth`。

## 6. 待办（后续探针/实现）

- [ ] 反编译 WS RPC 的 **client→server 调用信封**（如何 invoke `sessionLifecycleService.archive(sessionId)`），以打通管理操作。线索：`server_hello` 的 `protocol_version:2`、二进制里 `serverHelloMessageSchema` 附近应有对称的 client 消息 schema。
- [ ] 确认 `sessionExportService.export` 的入参与返回（导出格式：markdown/json？）。
- [ ] 确认 prompt 提交 / 权限响应的 RPC 信封（验证"WS 单通道替代 ACP"假设）。
- [ ] 把探测中创建的 `PROBE_THROWAWAY` 会话清理掉（REST 删不掉，需走 WS RPC `delete`，见上）。

## 7. 探针产物（本仓库）

- `docs/probe/kimi-web-api.md`（本文件）
- 原始 `debug/channels` 全量 JSON 已抓取（181 channel），按需可重新生成：
  `curl -H "Authorization: Bearer <token>" http://127.0.0.1:58627/api/v1/debug/channels`
