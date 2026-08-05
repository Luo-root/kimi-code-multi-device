# SENTINEL · ACP 对齐分析（kimi-code 0.32.0）

> 目的：用标准 ACP 协议（agentclientprotocol.com）作参照系，逐方法核对 kimi-code 0.32.0 实际实现，并对照 relay（Go 中继）的调用/处理状态，定位「未实现」与「实现有问题」的项。
>
> 📌 **Schema 级细查见 `docs/acp-schema-comparison.md`**（交集方法 + 逐字段差异表 + 可扩展性评估）。本文件的 `method_id` 旧写法已订正为 `methodId`（camelCase，与官方 `AuthenticateRequest` 一致）；kimi 发布文档中的 `method_id` / `fsCapabilities` 均为过时描述，`acp-adapter` 源码证实使用 `methodId` 与 `clientCapabilities.fs`。
> 方法：① 官网标准 ACP 概念；② kimi 二进制静态扫描（`clientCapabilities?.fs` / `fs/read_text_file` 等字符串）；③ 动态探针 `probe/fs/main.go`（spawn `kimi acp` → initialize → session/new → set_mode yolo → session/prompt 触发读+写文件 → 捕获 session/update 与 fs/* reverse-RPC）。

## 三项关键发现（动态探针证实）

1. **`fs/read_text_file` / `fs/write_text_file` reverse-RPC 不被触发。**
   client 声明 `clientCapabilities.fs={read_text_file:true,write_text_file:true}` + `set_mode yolo`，kimi 的 Read/Write 工具仍走本地 I/O（`tool_call` / `tool_call_update`），全程未向 client 发 `fs/read_text_file` / `fs/write_text_file`。
   → fs/* 是「声明性存在、但工具调用未接线」的空能力。**relay 不需要实现 fs 代理**；当前 `client.go` 对 fs/* 返回 `methodNotFound(-32601)` 的兜底是正确的防御性处理。

2. **`notifications/initialized` 不被支持。**
   kimi 返回 `code:-32601, "Method not found": notifications/initialized`。标准 ACP 的「initialize 响应后发 initialized 通知」握手在 kimi 这里是空操作。
   → relay 不发 initialized（正确）。之前误以为需要补 initialized 是错的。

3. **`session/update` 的 `sessionUpdate` 类型嵌套在 `params.update.sessionUpdate`（非顶层）。**
   kimi 下行结构：`{method:"session/update", params:{sessionId, update:{sessionUpdate:"agent_thought_chunk", content:{...}}}}`。
   relay 透传时提取 `params.update` 子对象作为 `Env.Payload` 下发（server.go:262），因此 mobile 收到展平后的 `{sessionUpdate, content}`，用 `payload.sessionUpdate` 顶层解析——**relay/mobile 解析位置正确**。

## 标准 ACP × kimi 0.32.0 × relay 对照表

| 标准 ACP 方法 | kimi 二进制 | relay 调用/处理 | 状态 |
|---|---|---|---|
| `initialize` | ✅ | ✅ request | 对齐 |
| `notifications/initialized` | ❌ `-32601` | ❌（正确省略） | kimi 不支持，relay 正确不调用 |
| `session/new` | ✅ | ✅ | 对齐 |
| `session/list` | ✅ | ✅ | 对齐 |
| `session/prompt` | ✅ | ✅ | 对齐 |
| `session/cancel` | ✅（notification） | ✅（notify） | 对齐 |
| `session/close` | ⚠️ 二进制有字符串，handler 未实现 | ❌（kimi 未实现；relay 已改本地清理+广播 closed） | 对齐（kimi 侧未实现） |
| `session/delete` | ✅ | ❌ 未用 | kimi 有，relay 未接入 |
| `session/resume` | ✅ | ✅ | 对齐 |
| `session/load` | ✅ | ❌ 未用 | kimi 有，relay 未接入 |
| `session/fork` | ✅ | ❌ 未用 | kimi 有，relay 未接入 |
| `session/update` | ✅（reverse-RPC 通知） | ✅（透传 `update` 子对象） | 对齐 |
| `session/request_permission` | ✅（reverse-RPC） | ✅（optionId 批准） | 对齐（仅覆盖工具审批，未覆盖 elicitation 文本回答） |
| `session/set_mode` | ✅（kimi 扩展，键 `modeId`） | ✅ | kimi 扩展，relay 对齐 |
| `session/set_config_option` | ✅（kimi 扩展） | ✅（发 model） | 对齐 |
| `session/set_model` | ✅（kimi 扩展） | ❌（用 `set_config_option` 等价实现） | kimi 扩展，relay 用等价方法 |
| `authenticate` | ✅ | ✅（best-effort，发送 `methodId:'login'`（camelCase，与官方一致），不阻断启动） | 对齐 |
| `logout` | ❓ 未验证 | ❌ | 未验证 |
| `fs/read_text_file` | ✅（method 名存在） | ❌（未触发，methodNotFound 兜底） | kimi 工具不调用，本地执行 |
| `fs/write_text_file` | ✅（method 名存在） | ❌（未触发，methodNotFound 兜底） | 同上 |
| `notifications/cancelled` | ✅ | — | kimi 支持 |
| `notifications/progress` | ✅ | — | kimi 支持 |
| `notifications/message` | ✅ | — | kimi 支持 |
| `elicitation`（client 能力） | ✅ `clientCapabilities?.elicitation` | ❌ 未用 | kimi 支持能力，relay 未声明/未处理 |
| `terminal`（client 能力） | ✅ `clientCapabilities?.terminal` | ❌ 未用 | kimi 支持能力，relay 未声明/未处理 |
| `fs/promises` | ✅（kimi 特有） | ❌ | kimi 特有，非标准 ACP |

## 对 relay 的结论

- **已实现方法基本对齐标准 ACP + kimi 扩展**（`set_mode` / `set_config_option` 是 kimi 扩展，relay 已覆盖）。
- **fs 代理不需要实现**：kimi 0.32.0 不向 client 路由文件 I/O，relay 当前的 `fs/*` → `methodNotFound` 兜底即足够（防御性正确）。
- **`authenticate` 握手、`session/close` 本地清理、`fs/*` 兜底** 这轮 relay 改动（commit `9bc1fe4`）全部为正确对齐。
- **未接入但 kimi 已支持的**：`session/delete` / `load` / `fork`、`elicitation` / `terminal` 能力、`fs/promises`。当前产品不需要，可后续按需接入；`elicitation` 值得关注——若 kimi 未来用 elicitation 向手机端索要文本输入，relay 的 permission 处理需扩展（当前只回 `optionId`）。

## 探针工具

`probe/fs/main.go` 是固化上述发现的回归探针：声明 `clientCapabilities.fs`、触发真实读+写、打印完整 session/update 流与任何 fs/* 请求。后续 kimi 升级时重跑即可验证 fs/* 是否开始被触发。
