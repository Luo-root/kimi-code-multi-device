# Probe: kimi-code `kimi web` 本地接口面

> 探针日期：2026-08-05 起，**2026-08-06 实机订正** ｜ kimi 版本：`0.32.0` ｜ 探测环境：Windows，二进制 `~/.kimi-code/bin/kimi.exe`
> 探测方式：① 启动 `kimi web --no-open`；② 读启动日志拿 bearer token；③ curl/python 探 REST；④ 从二进制提取 `/api/v1/*` 路由字符串；⑤ `GET /api/v1/debug/channels` 拿 RPC 全量方法目录；⑥ `websockets` 连 `/api/v1/ws` 验证握手。
>
> ### ⚠️ 结论订正史（读本文务必先看这里）
>
> 本文经历过两次误判，**当前有效结论是第三版**：
>
> | 版本 | 结论 | 状态 |
> |---|---|---|
> | v1（08-05 早） | 管理走 **WebSocket-RPC** | ❌ 已否定（v2 事件 socket 已移除） |
> | v2（08-05 晚） | 管理走 **HTTP 调试 RPC** `/api/v1/debug/session/:sid/...` | ❌ 已否定（对代启实例永远 `40401 session not found`） |
> | **v3（08-06 实机，当前有效）** | 管理走 **REST 冒号动作** `POST /api/v1/sessions/{id}:archive`，**无需 `--debug-endpoints`** | ✅ 已实测跑通并落地 relay |
>
> **v2 误判的根因**：早期探针用的是**斜杠** `POST /api/v1/sessions/{id}/archive` → 服务端回 `unsupported action`，于是判定"REST 不支持管理"。实际 kimi 用的是 **Google AIP 风格的冒号自定义方法** `POST /api/v1/sessions/{id}:archive`——一个字符之差，结论完全相反。**探针拿到否定结果时，先怀疑请求形状，再下结论。**

## 0. 启动与鉴权

```bash
kimi web --no-open --log-level info
# 默认监听 http://127.0.0.1:58627 （端口被占用则自动 +1；--host 可绑 0.0.0.0）
# 启动日志打印 bearer token，例如：
#   Kimi server: http://127.0.0.1:58627/#token=<BEARER_TOKEN>
```

- **鉴权**：所有 REST/WS 路由需 `Authorization: Bearer <token>` 头（WS 也可用 `?token=` query，但实测 query 方式返回 401，必须用 header）。token 跨重启持久（同一台机器多次启动 token 不变）。
- **token 只能从启动横幅拿**：`~/.kimi-code/server.token` 实测**不存在**，没有磁盘旁路。relay 代启时须抓 stdout 横幅。
- **危险开关**：`--dangerous-bypass-auth` 关闭鉴权并会在 `/api/v1/meta` 的 `dangerous_bypass_auth` 暴露 true；仅可信网络用。生产不要开。
- **默认关闭的高危路由**：`/api/v1/shutdown`、`/api/v1/terminals/*` 在非 loopback 绑定时默认 404，除非显式 `--allow-remote-shutdown` / `--allow-remote-terminals`。
- **`--debug-endpoints` 与管理无关**：管理动作走 REST 冒号方法（§2.1），**不需要**该 flag。它只开 `/api/v1/debug/*` 自省面（§3），本项目已不依赖。
- **契约文件不可用**：`/openapi.json`、`/asyncapi.json` 均返回空体，不能当接口契约来源。

### 0.1 ⚠️ 存储单写者锁（重要产品约束）

kimi 的会话存储是**独占写锁**。同时运行两个 `kimi web` 时，**非持锁方的所有写操作**一律失败：

```
50001 storage write failed: unrecognized I/O error
```

- 受影响：`:archive` / `:restore` / `:fork` / `POST /api/v1/sessions`（建会话）等**全部写操作**。
- **不**受影响：`GET /api/v1/sessions` 等读操作照常。
- 杀掉多余实例后立即恢复 `code:0`。（决定性实验见 `probe/web/lock_probe.py`）

**对 relay 的强制要求**：代启 `kimi web` 前**必须先探测并复用已有实例**（默认 58627）。否则用户自己开着 kimi web 时，管理功能全线失败，且 `storage write failed` 这个错误文案完全无法自解释。relay 须把 50001 转译为「检测到另一个 kimi web 正在运行」。

> 曾误判为"沙箱写限制"，已订正。

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
| `GET /api/v1/sessions/{id}/export` | ❌ 404 | 导出**只认 POST**（见 §2.1） |
| `POST /api/v1/sessions` | ✅ 200（body 需 `workspace_id`+`metadata.cwd`=`工作区根`） | 新建会话 |
| `PATCH /api/v1/sessions/{id}` | ❌ 404 | REST 不接管整对象 PATCH |
| `POST /api/v1/sessions/{id}/archive` | ❌ `unsupported action` | ⚠️ **斜杠写法无效**——真实语法是冒号 `:archive`（§2.1） |
| `DELETE /api/v1/sessions/{id}` | ❌ 404 | 删除**确无**磁盘接口（§2.1） |
| `GET /api/v1/files` / `/api/v1/files/{file_id}` | 路由存在于二进制 | 文件上传/读取 |
| `GET /api/v1/fs:browse` `/fs:home` `/fs::browse` `/fs::content` | 路由存在于二进制 | fs 浏览/内容（对应 `fs_query`） |
| `GET /api/v1/terminals/` | 路由存在（默认 loopback 下 404） | PTY 终端（对应 `terminal`） |
| `GET /api/v1/debug/channels` | ✅ 200（需 `--debug-endpoints`） | **调试 RPC 服务目录（181 个 channel，HTTP）** |
| `GET /api/v1/debug/*` | 路由存在 | 测试自省（默认关） |
| `WS  /api/v1/ws` | ✅ 握手 `server_hello` | **transcript 增量通道（实时消息流，与管理 RPC 无关）** |
| `POST /api/v1/shutdown` | 路由存在（默认 404） | 关服务 |

## 2.1 会话管理：REST 冒号动作（**当前有效结论，已落地 relay**）

kimi 采用 **Google AIP-136 风格的自定义方法**：动作名用**冒号**拼在资源路径尾部，不是斜杠子路径。

| 操作 | 请求 | 请求体 | 响应 `data` |
|---|---|---|---|
| 归档 | `POST /api/v1/sessions/{id}:archive` | `{}` | `{archived: true}` |
| 恢复 | `POST /api/v1/sessions/{id}:restore` | `{}` | 完整 session 对象（`archived` 翻回 false） |
| 分叉 | `POST /api/v1/sessions/{id}:fork` | `{}` | 新 session 完整对象，**新 id 在 `data.id`** |
| 重命名 | `POST /api/v1/sessions/{id}/profile` | `{"title": "新标题"}` | — |
| 导出 | `POST /api/v1/sessions/{id}/export` | `{}` | **zip 二进制流**（见下） |
| 删除 | — | — | ❌ **不支持**（见下） |

**共性约束（全部实测踩过坑）**：

1. **无需 `--debug-endpoints`**。这些动作从**磁盘**解析会话，不要求会话在运行时已激活 → 对 relay 代启的 kimi web 完全可用。
2. **请求体必须是 JSON 对象，哪怕是空对象 `{}`**：
   - 发 `nil`/不发 body → `40001 expected object, received undefined`
   - 带任何额外键 → `40001 Unrecognized key`
3. 响应统一信封 `{code, msg, data, request_id}`，`code:0` 为成功。
4. 写操作受**单写者锁**约束（§0.1）。

**重命名（`/profile`）**：注意它是**斜杠**子资源，不是冒号动作——`:rename` 会回 `unsupported action`。该端点由用户浏览器 F12 抓包证实，探针据此复现验证。

**导出（`/export`）**：
- **仅 POST**（GET 是 404）。
- 返回 `Content-Type: application/zip` 的**二进制流** + `Content-Disposition: attachment; filename="kimi-session-{sid}.zip"`。
- **响应里没有 `zipPath` 字段**——kimi 不落盘，relay 必须自行把流写入文件再把本地路径回给端侧。

**删除**：`:delete` / `:unarchive` / `:duplicate` 均回 `unsupported action`；`PATCH` / `DELETE` 方法回 404。**0.32.0 确实没有磁盘删除接口**，端侧应直接隐藏该入口，而不是发请求再报错。

> 注：`packages/kap-server/src/routes/sessions.ts` 在 main 分支的动作路由与此一致；`unsupported action` 是**动作名白名单**未命中，不是"REST 不支持管理"。

## 3. 调试 RPC 接口面：HTTP ProxyChannel（**本项目不采用**，存档备查）

> ⚠️ **本章是已否定路径（v2 结论），保留仅为避免后人重走弯路。管理请用 §2.1。**
>
> **为什么不可行**：`POST /api/v1/debug/session/{sid}/{service}/{method}` 的 `session/{sid}` scope 路由**确实存在**，但它的会话解析器**只认运行时已加载（经 WebSocket 挂载）的会话**。而 relay 的会话活在独立的 `kimi acp` 进程里，relay 代启的 `kimi web` 永远没有已加载会话 → 全部返回 `40401 session not found`。
>
> 换言之：debug RPC 要求「会话在这个 kimi web 实例里是活的」，这个前提在 relay 架构下**结构性地无法满足**（除非把 ACP 统一收进 kimi web，代价过大）。而 §2.1 的 REST 冒号动作是**磁盘直读**，没有这个前提，故成为唯一正解。
>
> 另注：早期还误判过"管理走 WebSocket-RPC"（v1）。经核对源码（`apps/kimi-inspect/src/channel/client.ts` + `proxyChannel.ts`），v2 的 `/api/v2/ws` 事件 socket 已移除，service 无事件推送（`listen` 直接抛错）；`/api/v1/ws` 是**独立的 transcript 增量通道**，与管理无关。

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

> ⚠️ **接入前提（双重门槛，这也是它不可用的原因）**：① 需 `kimi web --debug-endpoints` 启动（且 loopback），否则 `/api/v1/debug/*` 404；② 目标会话必须在**该实例**运行时已加载，否则 `40401 session not found`。条件 ② 对 relay 无解，详见本章开头。
>
> 实测补充：在**未带** `--debug-endpoints` 的实例上，§2.1 的 REST 冒号动作照常 `code:0`，而 debug RPC 404——两者互不依赖。

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

**结论：走 REST `POST /api/v1/sessions/{id}/export`**（斜杠子资源，非冒号动作），详见 §2.1。

二进制里该路径确实是字符串；早期 `GET` 实测 404 曾导致误判为"走 debug RPC"，实际只是**方法不对**——它只认 POST。关键细节：请求体必须是 `{}`，响应是 zip 二进制流而非 JSON，**没有 `zipPath` 字段**，落盘由调用方负责。

## 5. 对 relay/app 架构的影响

`docs/kimi-full-feature-plan.md` 最初把"通道② 本机管理通道"设想为**直连 kimi web 的本地 REST API**——**这个最初设想是对的**，中间两版订正（WS → debug RPC）反而是弯路，现已回归 REST：

1. **管理操作走 REST 冒号动作**（§2.1）。relay 用普通 HTTP 客户端打 `http://127.0.0.1:58627/api/v1/sessions/{id}:archive` 等，**不需要** `--debug-endpoints`，也不需要 WebSocket。
2. **能力边界要如实反映到 UI**：archive / restore / fork / export / rename 可用；**delete 在 0.32.0 无接口**，端侧应**隐藏入口**而非发请求后报错。
3. **必须先探测复用已有 kimi web 实例**（§0.1 单写者锁）。这是硬约束，不是优化项。
4. **不存在"WS 单通道替代 ACP"**：实时运行时仍由 **ACP（通道①）** 负责，管理由 **REST（通道②）** 负责，两者正交。
5. **鉴权**：relay 读启动横幅 token（跨重启持久）。loopback 下默认安全，**不要**开 `--dangerous-bypass-auth`。Flutter 端**不直接碰 kimi web**——多设备场景下 loopback 够不到，必须经 relay 中转。

## 6. 待办（后续探针/实现）

- [x] ~~反编译 WS RPC 信封~~ → 已否定（v1 误判）。
- [x] ~~实跑验证 debug RPC invoke~~ → 已否定（v2 误判，`40401 session not found`，见 §3）。
- [x] **确认管理接口真身** → REST 冒号动作，已实测跑通并落地 relay（§2.1）。
- [x] **确认 export 入参与返回格式** → `{}` body，返回 zip 二进制流（§2.1）。
- [x] **确认单写者锁行为** → 已做决定性实验（§0.1，`probe/web/lock_probe.py`）。
- [ ] `GET /api/v1/sessions` 未暴露 `archived` 之外的端侧所需字段（gap #1：ACP 侧无 `archived`/`createdAt`），待后续对齐。
- [ ] 关注新版 kimi 是否补上 delete 的磁盘接口；补上后从 `kKimiUnsupportedActions` 移除即可自动放开端侧入口。

## 7. 探针产物（本仓库）

- `docs/probe/kimi-web-api.md`（本文件）
- `probe/web/kimi_web_channels.json`（181 channel 全量方法目录）
- `probe/web/kimi_web_routes.txt`（二进制提取路由）
- `probe/web/action_shape_probe.py` —— **REST 冒号动作全貌 + 验证无需 `--debug-endpoints`**（§2.1 主依据）
- `probe/web/export_body_probe.py` —— export 的 `{}` body 要求与 zip 流响应
- `probe/web/rename_probe.py` —— 重命名端点探索（记录 `:rename` 为何不可用）
- `probe/web/lock_probe.py` —— **单写者锁决定性实验**（§0.1）

> 探针脚本均从启动横幅抓 token，**不硬编码凭据**；写操作可逆（archive→restore、改名后还原），可安全复跑。
> 原始 `debug/channels` 可重新生成：`curl -H "Authorization: Bearer <token>" http://127.0.0.1:58627/api/v1/debug/channels`
