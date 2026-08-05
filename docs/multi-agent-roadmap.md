# SENTINEL 多 Agent 兼容路线图

> 设计文档 / 后续迭代方向
> 维护：SENTINEL 团队 ｜ 状态：草案（待评审）

---

## 1. 背景与目标

SENTINEL 当前的远程控制链路是 **relay（Go）↔ kimi code（ACP 子进程）↔ Flutter app**，
relay 在重写后（`github.com/coder/acp-go-sdk v0.13.5`）已完整覆盖 kimi code 实际使用的 ACP 能力。

但 relay 目前是 **kimi 硬编码** 的：

- `protocolVersion` 钉死为 `1`（与 kimi 0.32.0 一致）；
- `initialize` 时下发**空** `ClientCapabilities{}`，即不向 agent 声明自己提供 `fs` / `terminal` 能力；
- `Elicitation`（结构化追问）等反向 RPC **未实现**；
- `app` 端直接消费 kimi 原生的 `session/update` schema（思考块 / 工具卡 / AgentGroup 等按 kimi 形状渲染）。

**目标**：让 SENTINEL 的远程控制能力不局限于 kimi code，可兼容任意遵循 **ACP v1** 的 agent
（Claude Code / Codex / Gemini CLI 等本地 CLI agent，以及未来可能的远程 / 容器化 agent）。

### 1.1 协议版本结论（重要）

**ACP 稳定版即为 `v1`；`v2` 目前仅处于草案阶段。**
因此：

- 当前 relay 钉死 `protocolVersion: 1` 是**正确且充分**的，不构成协议风险；
- 在实现与 v1 对齐的前提下，可预见的未来内无需为 v2 提前改造；
- 仅需在文档 / 配置层保留"v2 草案跟踪"的观察项，待 v2 进入稳定再评估升级。

---

## 2. 设计原则

1. **能力协商驱动（capability negotiation），而非硬编码**
   relay 应根据部署配置动态声明 `ClientCapabilities`，而不是写死空能力集。
2. **不追求 100% ACP 兼容**
   只补齐"交互必需"的能力；IDE 专属 / 仍 `UNSTABLE` 的方法保持 `methodNotFound` 兜底。
3. **接口薄、能力 opt-in**
   `acp.Client` 接口保持精简，未声明的能力由 SDK 自动 `methodNotFound`，避免早投。
4. **端侧渲染与具体 agent 解耦**
   app 的 `session/update` 渲染需从"kimi 专属形状"演进为"通用 ACP update 渲染"。
5. **零回归优先**
   任何多 agent 改造不得破坏当前 kimi code 的已验证链路（relay↔app 线协议不变）。

---

## 3. 现状盘点（kimi code 视角）

> 数据来源：`docs/acp-alignment.md`、`docs/acp-schema-comparison.md`、fs 探针（`probe/fs/main.go`）、真实 kimi 0.32.0 联调。

### 3.1 kimi code 已实现 / 已暴露的 ACP 能力

| 类别 | 方法 | kimi 状态 |
|---|---|---|
| client→server | `initialize` / `authenticate` | ✅ |
| client→server | `session/new` / `session/list` / `session/resume` | ✅ |
| client→server | `session/prompt` / `session/cancel` | ✅ |
| client→server | `session/set_mode` / `session/set_config_option` | ✅ |
| server→client（反向 RPC） | `session/update` | ✅（relay 原样透传 app） |
| server→client（反向 RPC） | `session/request_permission` | ✅（完整 manual / 超时 / 退出流） |
| 声明但未触发 | `fs/read_text_file` / `fs/write_text_file` | 🟡 kimi 本地执行，不触发反向 RPC |
| 未实现 | `session/close` / `logout` | ❌ kimi 不实现 |
| 未实现（反向 RPC） | `terminal/*`（5 个） | ❌ kimi 不调用 |
| 未实现（反向 RPC） | `elicitation` | ❌ kimi 当前不依赖 |
| 不稳定面 | 仅 `session/set_model` 支持 | 🟡 UNSTABLE |

### 3.2 relay 当前接入情况

- 全部 **client→server** 稳定方法已接入（`initialize`/`authenticate`/`session/*`/`set_mode`/`set_config_option`）。
- 两个 kimi 实际使用的反向 RPC（`session/update`、`session/request_permission`）已完整接入。
- `session/close` / `logout`：kimi 不实现 → relay 走本地清理 + 广播，正确对齐（非缺口）。
- `fs/*` / `terminal/*`：relay 不声明能力，kimi 也不触发 → SDK `methodNotFound` 兜底，经探针验证充分。
- `elicitation`：未实现（对 kimi 无影响，但为多 agent 方向的关键缺口）。

**结论**：针对 kimi code，relay 已**实质完整接入**其支持的全部 ACP 能力；剩余项要么是 kimi 自身未实现的（非 relay 缺口），要么是为"非 kimi agent"预留的（多 agent 方向）。

---

## 4. 能力分级与优先级

| 优先级 | 能力 | 触发条件 | 说明 |
|---|---|---|---|
| **P0** | `Elicitation` | 接入任意"非 kimi 且依赖结构化追问"的 agent | 多数 CLI agent 会用它向用户索取表单 / 链接 / 选项；不接则 `methodNotFound`，交互失败 |
| **P1** | `fs` / `terminal` 代理 | 仅当 agent 运行在**远程 / 容器**、无本地磁盘时 | 本地 CLI agent（同机）自带 FS，relay 代理无意义 |
| 配置驱动（第一步） | `ClientCapabilities` 配置化 | 任何多 agent 部署 | 部署时声明是否代理 fs/terminal，不再写死空 |
| 延后 / 不做 | `NES` / `Plan` / `Document` / `Providers` | — | 多为 IDE 特性或仍 `UNSTABLE`，按需声明 |
| 延后 / 不做 | `session/fork`·`delete`·`load` | 等上游 agent 补 API | 当前 kimi 未实现，app 侧已有占位 |

---

## 5. 演进路线（分阶段）

### 阶段 A — `ClientCapabilities` 配置驱动（低风险，零行为回归）
- 将 `initialize` 时下发的能力集从硬编码空 `ClientCapabilities{}` 改为读取部署配置。
- 配置项：`provideFilesystem`、`provideTerminal`（默认 false，保持当前行为）。
- 验证：`go vet/build/test` 通过，kimi 链路无回归。

### 阶段 B — `Elicitation` 端到端（P0）
- relay：`acp.Client` 实现 `UnstableCreateElicitation`（或对应反向 RPC），透传 `ElicitationRequest` / `ElicitationResponse`。
- app：新增结构化表单组件（输入 / 选择 / 确认），经 `UpElicitationResponse` 回传。
- 验证：用支持 elicitation 的 agent（或 mock）跑通一次结构化追问。

### 阶段 C — app 渲染通用化（联动改造，最大工程量）
- 将 `session/update` 的 `sessionUpdate` 各 arm 渲染从"kimi 专属形状"抽象为通用渲染层。
- 保持 kimi 现有视觉（思考块 / 工具卡 / AgentGroup）作为默认皮肤，新增 agent 可套用通用渲染。
- 目标：换 agent 后 UI 不崩、不漏渲染未知 arm（未知 arm 走兜底渲染而非丢弃）。

### 阶段 D — 远程 agent 的 fs / terminal 代理（按需）
- 仅在出现远程 / 容器化 agent 时实施。
- relay 实现 `fs/read_text_file` / `fs/write_text_file` 与 `terminal/*`，代理到 agent 所在环境。

---

## 6. 风险与开放问题

1. **ACP v2 草案演进**：保持 v1 兼容即可；在 `docs/` 留跟踪项，v2 稳定后再评估升级收益。
2. **app 渲染解耦工作量**：阶段 C 是真正的工作量重心，需在排期时单独评估。
3. **未知 agent 的 `session/update` schema 漂移**：阶段 C 的"未知 arm 兜底渲染"是防御关键。
4. **能力误声明**：relay 声明了某能力却未正确实现，会导致 agent 调用时失败；阶段 A 配置默认关闭即规避此风险。

---

## 7. 验收标准

- [ ] 阶段 A：`ClientCapabilities` 可由配置控制，kimi 链路零回归。
- [ ] 阶段 B：Elicitation 在 relay + app 端到端跑通一次真实结构化追问。
- [ ] 阶段 C：接入一个"非 kimi、含未知 update arm"的 mock agent，app 不崩、未知 arm 有兜底渲染。
- [ ] 阶段 D（如触发）：远程 agent 的 fs / terminal 操作经 relay 代理成功。

---

## 8. 关联文档

- `docs/acp-alignment.md` — relay↔kimi 对齐与 fs 探针结论。
- `docs/acp-schema-comparison.md` — kimi-code × 官方 ACP schema 级对比（v1 基线无 schema 级差异）。
- `docs/design-spec.md` — SENTINEL 产品设计定稿。
