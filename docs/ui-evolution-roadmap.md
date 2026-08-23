# SENTINEL UI 演进路线（UI Evolution Roadmap）

> 基于竞品实测调研的 UI/交互演进规划。定义**学谁、学什么、不学什么**，以及每一阶段的验收标准。
> 配套：产品设计定稿见 `design-spec.md`；UX 问题清单见 `UX-IMPROVEMENT-GUIDE.md`；本卷只管"变好看变好用"这件事。

| 项       | 值 |
| -------- | -- |
| 文档     | UI 演进路线 |
| 版本     | v1.0 |
| 日期     | 2026-08-22 |
| 调研对象 | Paseo · Happy Coder · Omnara（+ ChatGPT/Claude 官方 app 质感参照） |
| 结论     | **不换语言**，留在 Flutter；差距在组件化程度与交互模式，不在框架 |

---

## §01 调研结论摘要

### 三家对标

| | Paseo（最直接竞品） | Happy Coder | Omnara |
|---|---|---|---|
| 定位 | 多 agent 编排器 daemon + 五端 | Claude Code 手机客户端 E2EE | Agent 指挥中心（YC S25） |
| 技术栈 | Expo / React Native + Electron | React Native + React Web | 原生 iOS |
| 口碑 | "the best UI ive seen in this segment" | HN Show HN 热帖 | 首周 25 万次 agent 交互 |
| 关键数字 | 11.1k stars / 4414 commits | 8.2k stars | Apple Watch 批准 |

> 注意：Paseo 已官方支持 Kimi Code（paseo.sh/kimi），是真实竞争压力，也是免费的交互教材。

### 可提取的共性交互模式（学这些）

1. **Diff 是一等公民**——edit 类工具调用渲染为结构化 diff 卡片（文件名 + 增删行数 + 可展开内容），不是文本流里的一张普通工具卡。（Paseo 内联 review / Omnara Changes 页）
2. **批准动作零摩擦**——推送点开直达批准卡；一键批；移动端滑动批准。（Paseo swipe-to-approve / Omnara plain-English approve）
3. **会话列表 = 状态仪表盘**——每张卡片带最后一条动态单行摘要 + 进度感，不是纯名字列表。（Omnara pin 会话 / Paseo ls）
4. **桌面效率的移动端对应物**——命令面板 → 移动端收敛进"+"菜单；Terminal → 会话内视图。（Paseo ⌘K / Omnara Terminal view）
5. **诚实的连接态**——SENTINEL 已有（快照对齐 + busy 广播），方向正确，保持。

### 明确不学

- 云账号体系、团队协作（违反原则 2「数据在你机器上」）
- Paseo 的 worktree 自动预览 URL 一整套（那是多 provider 编排器的需求，SENTINEL 是单机遥控器）
- AGPL-3.0 代码：**一行不搬**。Paseo 是 AGPL，本仓 MIT，只学交互不抄实现。

---

## §02 决策记录：为什么不换语言

| 论点 | 依据 |
|---|---|
| Flutter 能做出优秀 UI | Nubank（1 亿用户、以动效手势著称）、Google Pay/Ads、My BMW（47 国车联 App）、闲鱼（5 亿用户）均为 Flutter 生产应用 |
| 竞品好看不是 RN 的功劳 | Paseo/Happy 的 UI 来自专职前端 + 数千 commits 迭代；换栈不带来迭代次数 |
| 产品形态适配 | 「活的流 + 自绘卡片 + 批准卡」是高度定制 UI，自绘引擎恰是优势场景；非系统控件密集型应用 |
| 换栈成本 | 重写 ~8.8k 行 Dart + 线协议对接 + 测试全重来；进入不熟的 TS 生态，收益不确定 |
| Flutter 真实短板（接受并规避） | 默认 Material 气质偏安卓 → 用 Cupertino 组件 + HapticFeedback 主动贴 iOS 手感；包体积大数 MB → 自用无感 |

**结论：留 Flutter。把力气花在组件化和交互模式上。**

---

## §03 现状诊断（2026-08-22）

- `home_shell.dart` 约 4300 行、40 个 class 单体（README 记录 3592 行已过时，附件上传功能又长了）。所有界面逻辑挤一个文件 → 视觉细节无法按组件打磨，这是"显丑"的第一根因。
- 顶栏四组决策点（历史抽屉 + 级联配置 + 三态灯 + mode 菜单）、底部 chip+输入+发送 → 首屏信息密度失衡，「活的流」没有呼吸空间。
- 风格规范 v1.0（`SENTINEL UI 风格规范 v1.0.md`）质量很高（85/5/10、克制原则、令牌齐全），问题是**规范到实现的执行落差**。
- edit 类工具调用目前以普通工具卡呈现，无结构化 diff 感知。

### home_shell.dart 结构地图（拆分作业面）

```
HomeShell/_HomeShellState        133-1084   状态中枢（最后处理）
─ _TopBar                        1085       顶栏
─ _ModeIconMenu(+State)          1173-1317  mode 菜单
─ _MenuRow(+State)               1318-1379  菜单行
─ _CascadeConfigMenu(+State)     1380-1814  级联配置菜单 ≈430 行 ★独立可拆
─ _SessionDrawer(+State)         1815-2172  会话抽屉 ≈360 行 ★独立可拆
─ _SessionRowMenu/_SessionMenuItem/_GroupMenu  2173-2546  抽屉配套菜单
─ SessionStoreScope/ArchiveStoreScope          2551-2576  InheritedWidget（公开 API，测试依赖）
─ _AiIdentityBar                 2577       AI 身份条
─ _EmptyState/_DotMatrix         2604-2672  空态+点阵装饰
─ _UserMessageAnchor(+State)     2673-2704  用户消息锚点
─ _ScrollJumpFab                 2705-2772  回到底部 FAB
─ _BottomDock                    2786-2927  底部 dock
─ _AttachmentPreviewRow/_AttachmentChip        2928-3013  附件预览
─ _SlashPanel                    3014-3060  slash 面板
─ _EnhancePill                   3061-3097  增强 pill
─ ComposerTextField/ComposerInputBar           3100-3360  公开 API（composer_input_test 依赖）
─ _PermSheet(+State)             3361-3631  批准卡弹层 ≈270 行 ★独立可拆
─ _SettingsSheet(+State)         3632-3878  设置弹层
─ _StatusRow/_ConnBanner         3879-3984  状态行/连接横幅
─ _SessionSwitcher/_SessionTab/_PendingBadge   3985-4162  会话切换器
─ _PendingQueuePage(+State)      4163-末尾  待批准队列页
```

---

## §04 演进分期与验收

> 每阶段 = 目标 + 任务 + 验收标准。功能是手段，"打开 app 想多用一会儿"才是目的。

### U1 · 地基重构（进行中）

**目标**：把单体拆成可单独打磨的组件文件；edit 操作获得结构化 diff 感知。

| # | 任务 | 验收 |
|---|---|---|
| U1-1 | 拆 `_CascadeConfigMenu` → `home_parts/cascade_config_menu.dart` | analyze 0 issue；现有测试全绿；行为零变化 |
| U1-2 | 拆 `_SessionDrawer` + `_SessionRowMenu`/`_GroupMenu` → `home_parts/session_drawer.dart` | 同上 |
| U1-3 | 拆叶子组件（_TopBar/_DotMatrix/_EmptyState/_AiIdentityBar/_ScrollJumpFab/_StatusRow/_ConnBanner/_SlashPanel/_EnhancePill/_AttachmentPreviewRow 等）→ `home_parts/` 各自归位 | 同上 |
| U1-4 | 拆 `_PermSheet`/`_SettingsSheet`/`_PendingQueuePage` → `home_parts/sheets.dart` 组 | 同上 |
| U1-5 | 拆 `_BottomDock` + Composer 组件 → `home_parts/composer.dart` | 同上 |
| U1-6 | **edit 工具调用 → mini-diff 卡片**：文件名 + `+n −m` 行徽标 + 展开显示增删行（绿/红底）；折叠态单行 | 真实 kimi edit 事件渲染正确；有单测固化字段形态 |
| U1-7 | home_shell.dart 收敛到 ≤1500 行（状态编排为主） | wc 验证 |

**U1 整体验收**：`flutter analyze` 0 issue、`flutter test` 全绿、真机跑一遍主流程（发消息/批准/切会话/抽屉）无回归。

### U2 · 批准动线与信息密度

**目标**：从"锁屏推送→解锁→找会话→找卡"变成"点推送→拍板"，全程 ≤2 步。

| # | 任务 | 验收 |
|---|---|---|
| U2-1 | Bark 推送点击深链直达对应批准卡（app 冷启/热启两条路径） | 锁屏点通知 3 秒内见到批准卡 |
| U2-2 | 待批准时批准卡置顶弹层优先于流内容（已在流中则锚点高亮） | 多会话并发待批准互不串味 |
| U2-3 | 会话列表卡片增加"最后一条动态"单行摘要（tool_call 标题或回复首行） | 抽屉一屏看清全部会话在干什么 |
| U2-4 | 待批准队列页强化：按会话分组 + 剩余时间倒计时 | 两会话同时待批准分清不串味 |

### U3 · 对话流质感专项

**目标**：对齐 ChatGPT/Claude 官方 app 的对话流手感。

| # | 任务 | 验收 |
|---|---|---|
| U3-1 | 触觉反馈：批准/拒绝轻击、发送轻击、到达新消息（可设置关） | iOS 真机手感自然不烦人 |
| U3-2 | 动效统一：卡片出入场曲线/时长令牌化，杜绝各写各的 | 全 app 动效只用 tokens 定义 |
| U3-3 | 列表左滑手势：会话 tab 左滑=关闭；抽屉行左滑=归档 | 与 iOS Mail 同款手感 |
| U3-4 | 首屏减负：mode 菜单收进级联菜单第二级，顶栏只留 抽屉/级联/三态灯 | 顶栏视觉分组 ≤3 |
| U3-5 | 空态/加载骨架屏打磨（点阵装饰已有，补骨架屏） | 冷启动无白屏闪烁 |

### U4 · 扩展交互（对应产品 v2/v3 场景）

| # | 任务 | 验收 |
|---|---|---|
| U4-1 | 语音输入按钮（系统 STT 起步，骑车场景前置条件） | 骑车场景完成一次语音派活 |
| U4-2 | 会话内 Terminal 视图（bash 工具调用的连续输出聚合展示） | 长输出任务可当终端看 |
| U4-3 | slash 命令历史快捷重放（长按输入框弹出最近指令） | 高频命令一次点击重发 |

---

## §05 不做清单（带理由）

| 不做 | 理由 |
|---|---|
| 换 React Native / Expo / 原生重写 | 见 §02 决策记录 |
| 搬运 Paseo 代码（AGPL-3.0） | 许可证污染 MIT 仓库；只学交互 |
| 引入重型状态管理框架迁移（如全面 BLoC） | 现有 setState+InheritedWidget 够用，迁移是稀释燃料 |
| 自绘 Markdown 引擎替换 flutter_markdown | 现有方案已满足，替换无用户可见收益 |
| 主题商店 / 字体切换 | 风格规范明确克制；自用不需要 |

---

## §06 风险与开放问题

| # | 问题 | 应对 |
|---|---|---|
| 1 | 拆分期间与并行开发（附件/markdown WIP）冲突 | 每次抽取前先同步主干；抽取 PR 保持小步 |
| 2 | 下划线私有类跨文件后需转公开，命名冲突风险 | 抽取时统一加 `Sentinel`/语义前缀检查 lib 全局无冲突 |
| 3 | 行为零变化的验证手段有限（无 golden test） | U1 先补关键组件 golden 测试再动刀；analyze+test 双闸门 |
| 4 | Windows 本机 Flutter 工具链曾损坏（cache Dart 版本错位） | 修复方式：删 `bin/cache` 重建（保持版本不变），已确认可行路径 |
| 5 | U2 深链需要 iOS Universal Links / scheme 配置，涉 Xcode 工程 | 用 custom scheme 起步（self-host 场景够用），v2 再评估 universal link |
