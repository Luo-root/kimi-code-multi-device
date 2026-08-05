# SENTINEL · kimi-code ACP 实现 × 官方 ACP 规范 — Schema 级对比审查

> 范围：仅对比 **kimi-code 已实现** 且 **官方 ACP 规范也已定义** 的「交集」部分，核对 **schema 定义（字段名 / 类型 / 结构）** 差异。
> 方法：官方 `schema.json`（142 个 `$defs`，最新发布修订）+ kimi-code 源码 `MoonshotAI/kimi-code@e7d5a0a`（`apps/kimi-code/src/cli/sub/acp.ts`、`packages/acp-adapter/*`）+ kimi 发布文档 + 动态探针 `probe/fs/main.go`。
> **不修改任何代码**（本次为审查结论）。

---

## 0. 修正后的基线结论（先看这个）

kimi-code 的 ACP 实现**不是**自己重写的协议，而是：

- 通过 `@moonshot-ai/acp-adapter` 包装官方 **`@agentclientprotocol/sdk@0.23.0`**（`acp.ts` 直接 `import ... from '@agentclientprotocol/sdk'`）；
- 协议版本协商 **固定为 `protocolVersion: 1`**（`version.ts`：`specTag: 'v0.10.x'`, `sdkVersion: '0.23.0'`，`SUPPORTED_VERSIONS` 只含 `1`）；
- 所以 kimi 的「类型定义基线」= **官方 SDK 0.23.0 的类型定义**。

**核心结论（按「仅看 kimi 正确实现的功能 + 仅看 schema 定义差异」的口径）：**

> 在 **SDK 0.23.0 基线** 上，kimi 对所有其**正确实现**的方法，字段名 / 类型 / 结构定义与官方 SDK 0.23.0 **逐字一致——不存在 schema 级定义差异**。

之前版本的报告把以下三类也计入「差异 / 严重度」，经复核**口径过宽，予以纠正**：

| 类别 | 是否算「schema 定义差异」 | 说明 |
|---|---|---|
| **版本漂移**（kimi@0.23.0 vs 官方最新） | ❌ 不算 | kimi 就是 SDK 0.23.0，与「官方 0.23.0」完全一致；与「官方最新」的分叉是版本差，不是 kimi「实现错了」。且新版 SDK 向后兼容，实际风险低。 |
| **行为覆盖空缺**（如 `notifications/initialized` 不支持、`fs/*` 不触发） | ❌ 不算 | kimi 内部未走该路径 / 字段缺省，是「某功能未暴露/未触发」，不是「字段定义不一致」。按本次口径排除。 |
| **adapter 层 surface 收敛**（如 `current_mode_update` 不发，改用 `config_option_update`） | ⚠️ 边界 | adapter 选择不暴露 SDK 已定义的某个 arm，属「未发出」而非「类型冲突」；client 监听 `config_option_update` 即可，无兼容性硬伤。 |

---

## 1. 交集方法清单（修正标注）

| 方法 / 通知 | kimi 实现状态 | 官方定义 | 在交集内 |
|---|---|---|---|
| `initialize` | ✅ | ✅ | ✅ |
| `authenticate` | ✅（`methodId:'login'`） | ✅ | ✅ |
| `session/new` | ✅ | ✅ | ✅ |
| `session/load` | ✅ | ✅ | ✅ |
| `session/resume` | ✅ | ✅ | ✅ |
| `session/list` | ✅ | ✅ | ✅ |
| `session/prompt` | ✅ | ✅ | ✅ |
| `session/cancel` | ✅（notification） | ✅ | ✅ |
| `session/close` | ❌ 未实现 | ✅ | ⚠️ kimi 未暴露该能力（行为空缺，不计 schema 差异） |
| `session/delete` | ✅ | ✅ | ✅ |
| `session/update` | ✅ | ✅ | ✅ |
| `session/request_permission` | ✅ | ✅ | ✅ |
| `session/set_mode` | ✅（`modeId`） | ✅ | ✅ |
| `session/set_config_option` | ✅（`configId`） | ✅ | ✅ |
| `fs/read_text_file` · `fs/write_text_file` | ⚠️ 方法名/路由存在但常规流程不触发 | ✅ | ⚠️ kimi 内部未走该路径（行为空缺，不计 schema 差异） |
| `notifications/message` · `progress` · `cancelled` | ✅ | ✅ | ✅ |
| `notifications/initialized` | ❌ `-32601` | ✅ | ⚠️ kimi 未实现该 handler（行为空缺，不计 schema 差异） |
| `session/set_model`（不稳定面） | ✅（等价 `set_config_option`） | ✅（不稳定/legacy） | ✅ |

> 不在交集、本次不展开：terminal/* 全套、elicitation（官方已稳定但 kimi 未接入）、`session/fork`、官方扩展 `unstable_*` 等——kimi 未实现即非交集。

---

## 2. Schema 定义层核对（核心结论：无差异）

> 在 **SDK 0.23.0 基线** 逐方法核对 request / response 参数类型与字段名，与官方 SDK 0.23.0 类型定义**逐字一致**。下表为已核实「对齐」项。

| 项 | 结论 | 证据 |
|---|---|---|
| `session/update` 嵌套 envelope | **对齐**：两者均为 `{sessionId, update:{sessionUpdate, ...}}` | kimi `events-map.ts` 注释明示「verified against sdk types.gen.d.ts: SessionNotification = {sessionId, update}」；官方 `SessionNotification` 同样 `update*` 嵌套 |
| `clientCapabilities.fs` 键名 | **对齐**（kimi 文档旧称 `fsCapabilities` 已过时） | kimi `server.ts:632` `const fs = this.clientCapabilities?.fs` |
| `authenticate.methodId` 字段 | **对齐**（camelCase；kimi 文档旧称 `method_id` 已过时） | kimi `server.ts:661` `if (params.methodId !== 'login')`；SENTINEL relay `server.go:128` 实际发送 `{"methodId":"login"}` |
| `session/new` 响应 | **对齐**：`sessionId` + `modes` + `configOptions` | 官方 `NewSessionResponse`；kimi `session.ts` 构造 `configOptions`/`modes` |
| `set_mode`(`modeId`) / `set_config_option`(`configId`) | **对齐**：字段名一致 | 官方 `SetSessionModeRequest.modeId` / `SetSessionConfigOptionRequest.configId` |
| 内容块（prompt） | **对齐**：`text`/`image`/`resource`/`resource_link` | 官方 `PromptRequest.prompt` union；kimi 文档能力矩阵 `embeddedContext:true` |
| `request_permission` 的 `outcome` 形状 | **在 0.23.0 基线对齐**：kimi 用 SDK 0.23.0 的 `{outcome, optionId?}` 形状 | kimi `approval.ts` 读取 `response.outcome.outcome` + `response.outcome.optionId`，即 SDK 0.23.0 定义；仅与「官方最新」分叉（见 §3） |

**唯一需 client 注意的 surface 收敛（非类型冲突）：**

- `current_mode_update`：官方 SDK 0.23.0 定义了该 `sessionUpdate` arm，但 kimi adapter 选择**不发出**它，统一发 `config_option_update`（`events-map.ts` 注释明示旧 helper 已删除）。→ client 监听 `config_option_update` 即可，无 schema 定义冲突。
- kimi adapter 实际发出的 `sessionUpdate` arm 全集（枚举自 `events-map.ts`）：`agent_message_chunk` / `agent_thought_chunk` / `available_commands_update` / `config_option_update` / `plan` / `tool_call` / `tool_call_update`。

---

## 3. 版本漂移核对（供参考，按口径不计 schema 定义差异）

| 方法/通知 | SDK 0.23.0（kimi 基线） | 官方最新 | 性质 | 实际风险 |
|---|---|---|---|---|
| `initialize.protocolVersion` | 固定 `1` | 随规范演进 | 版本差 | 低：新版 SDK 向后兼容，kimi 仅不主动用新能力 |
| `request_permission.outcome` | `{outcome, optionId?}` | `{"outcome"} \| {"optionId"}` | 版本差 | 低：client 按 0.23.0 构造即可；严格 client 不该发 kimi 不认识的简写 |
| `current_mode_update` arm | 定义存在但 kimi 不发出 | 同左（仍定义） | 版本/surface | 低：client 用 `config_option_update` 兜底 |

> 评估：版本漂移属正常的「依赖版本差」，不是 kimi 的实现错误；且 ACP 演进保持向后兼容，**不存在「用新版 SDK 会发 kimi 不认识的字段导致互通失败」的高风险**（新版客户端本就应按 server 协商结果降级）。

---

## 4. 行为覆盖空缺（供参考，按界定不计 schema 定义差异）

| 项 | 现象 | 性质 |
|---|---|---|
| `notifications/initialized` | kimi 返回 `-32601` 不支持 | kimi 服务端未实现该 handler（内部未走此路径），非 schema 定义问题 |
| `fs/read_text_file` · `fs/write_text_file` | 方法名 + `clientCapabilities?.fs` 路由逻辑存在，但常规 Read/Write 走本地 FS，探针未触发 `fs/*` | kimi 内部未把工具 I/O 路由到 client（字段/方法缺省未触发），非 schema 定义问题 |
| `session/close` | kimi 未实现 | kimi 未暴露该能力，非 schema 定义问题 |

> 对 SENTINEL 的影响：relay 已对 `initialized` 容错、对 `fs/*` 维持 `methodNotFound` 兜底——这些防御**正确且应保留**，但属「适配 kimi 行为」而非「修正 schema 差异」。

---

## 5. 对 SENTINEL relay 的结论（修正早前误建议）

- **relay 是 Go，无 ACP SDK 依赖，手搓 JSON-RPC 信封代理——这是合理的。** `@agentclientprotocol/sdk` 是 TypeScript/npm 包，Go 侧无法 import；对「信封透传」场景，手搓反而更可控。**早前报告建议「relay 改为 import SDK 0.23.0」属于空谈，予以撤回。**
- relay 实际需要关注的只有三点（均已满足或易满足）：
  1. **按 kimi 实际发出的 `sessionUpdate` arm 解析**：`agent_message_chunk` / `agent_thought_chunk` / `available_commands_update` / `config_option_update` / `plan` / `tool_call` / `tool_call_update`（不要依赖 `current_mode_update`）；
  2. **握手不依赖 `initialized`**（kimi 返回 `-32601`，relay 已不发/已容错）；
  3. **维持 `fs/*` 的 `methodNotFound` 兜底**（kimi 不触发，relay 无需实现 fs 代理）。
- **去除早前的「P0 SDK 升级跟踪机制」紧迫性**：SDK 升级属常规依赖更新卫生项，非紧急风险；版本漂移在向后兼容前提下风险低。如需，可作为低频的普通依赖巡检，不必单列 P0。
- 当前 relay 改动（commit `9bc1fe4`）全部为正确对齐；本次审查**未发现需要回退的 relay 行为**。

### 一句话总结
**用 SDK 0.23.0 对照 kimi 正确实现的功能，schema 定义完全对齐；之前的「8 处差异 / P0 风险」是把版本漂移和行为覆盖空缺也计入后的虚高结论，按「仅 schema 定义 + 仅正确实现」的口径，应为：无 schema 级差异，仅有可预期的版本差与少量未暴露能力。**
