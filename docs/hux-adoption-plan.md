# SENTINEL · hux UI 库采用方案（Plan v1）

> 状态：规划中（未实施）
> 决策来源：用户授权放宽设计规范字体红线（允许第三方字体 Manrope）；级联配置菜单 / 三态灯 / 历史项「形态保留、UI 换 hux」；Markdown 与代码块改用成熟库替代自研。
> 配套评估：`SENTINEL UI 风格规范 v1.0.md`、`design-spec.md`、pub.dev `hux` 包说明。

---

## 0. 决策记录

| 项 | 原规范 | 本次决策 |
|---|---|---|
| 字体 | 系统字体，禁第三方 | **放开**：允许 Manrope（hux 默认字体，SIL OFL 1.1） |
| 级联配置菜单 | 自研手风琴 | 形态保留（Provider/Model/Thinking 手风琴），UI 重绘为 hux 风格 |
| 三态灯 | 自研小圆点 | 形态保留（顶部右侧 8px 圆点），色板接 hux 语义令牌 |
| 历史项 | 自研列表项 | 形态保留（无分割线、左状态点+标题、右时间+cwd），UI 用 hux Sidebar/ListTile 风格 |
| Markdown 渲染 | 自研轻量 `MarkdownView` | 改用 `flutter_markdown` |
| 代码块 | 自研深色等宽 | 改用 `flutter_markdown` + `syntax_highlight` 深色语法高亮 |
| 整体底座 | 纯自研组件 | hux 作主题/通用组件底座 |

---

## 1. 目标与非目标

**目标**
- 用 hux 统一设计语言，消除自研组件风格不一致；补齐规范待修项（暗色主题 §10、菜单动画 §1、错误可见化 §7.3、表单）。
- 用成熟库替代自研 Markdown/代码块，获得标准 GFM 解析 + 语法高亮，降低维护成本。

**非目标（本次不做）**
- 不重写业务逻辑：活的流布局、滚动防劫持、复制逻辑、会话关闭、relay `Unknown sessionId` 热修等功能性修复**全部保留**。
- 不引入 hux 的 Chart/Sidebar 级导航重构（仅借用 Sidebar 视觉风格做历史抽屉）。
- 不做 Mermaid/LaTeX（后续若工具输出图再评估 `markdown_widget`）。

---

## 2. 依赖清单

在 `app/pubspec.yaml` 新增（保留已引入的 `url_launcher`）：

```yaml
dependencies:
  hux: ^1.2.1                  # UI 底座：主题/按钮/卡片/弹层/Snackbar/表单/Sidebar
  flutter_markdown: ^0.7.0     # Markdown 渲染（官方维护，Dart3 兼容，GFM 默认）
  syntax_highlight: ^0.5.0    # 代码块语法高亮（VSCode 风格，维护 Good）
  # url_launcher 已存在，用于链接跳转
```

字体：在 `pubspec.yaml` 的 `fonts` 加入 Manrope（hux 依赖，需配置以全局生效）：

```yaml
fonts:
  - family: Manrope
    fonts:
      - asset: assets/fonts/Manrope-Regular.ttf
      - asset: assets/fonts/Manrope-Medium.ttf
      - asset: assets/fonts/Manrope-SemiBold.ttf
```

> hux 自身可能已声明 Manrope 依赖；落地时以 hux 文档为准，避免字体重复打包。

---

## 3. 设计令牌映射（规范 → hux）

规范令牌见 `SENTINEL UI 风格规范 v1.0.md` 第二~四章。映射到 hux 的方式：**用 `HuxTheme` 种子色 + `HuxTokens`/`HuxColors` 覆盖，建立一套 `app_theme.dart` 统一出口**，业务组件只引用 `app_theme` 不直接写色值。

| 规范令牌 | 色值 | hux 落地方式 |
|---|---|---|
| `background` | `#F7F8FA` | `HuxTheme.lightTheme` scaffold 背景覆盖 |
| `surface` | `#FFFFFF` | `HuxColors.surface` / Card 背景 |
| `keyCap` | `#E5E5EA` | chip / 圆形图标底（复制按钮原底色已去，按需复用） |
| `textPrimary` | `#1D1D1F` | `HuxColors.textPrimary` |
| `textSecondary` | `#86868B` | `HuxColors.textSecondary` |
| `placeholder` | `#C0C0C0` | 输入框占位 |
| `hairline` | `#EEF0F2` | 极淡分隔（规范主张不用分割线） |
| `accent` | 近中性黑 `#1D1D1F`（hux 主色） | 用 hux 颜色，不采用 Kimi 紫（用户澄清：规范未指定 Kimi 紫）；选中态/链接/当前会话接 hux 中性主色 |
| `approve`/`online` | `#34C759` | `HuxColors.approve` / 在线绿 |
| `reject`/`critical` | `#FF3B30` | `HuxColors.reject` / 关键命令红条 |
| `warning`/`pending` | `#FF9500` | `HuxColors.warning` |
| `think` | `#8E8E93` | 思考块中性灰 |

**圆角**：卡片/批准卡/输入框 `20`、缩略图/工具卡 `12`、胶囊/状态点 `999` —— 在 `HuxTokens` 或组件参数中按规范固定，不沿用 hux 默认值。
**阴影**：卡片 `black 6% blur24 offset(0,8)`、输入框 `black 5% blur12 offset(0,4)`、弹窗 `black 10% blur32 offset(0,12)` —— 用 `BoxShadow` 常量在 `app_theme.dart` 统一定义。

---

## 4. 逐组件替换映射

| 自研组件 / 位置 | hux / 库接管 | 备注 |
|---|---|---|
| 发送 / 停按钮（`home_shell` 输入区） | `HuxButton(variant: primary)` | 流式中变 `reject` 红「停」，`session.busy` 驱动（逻辑保留） |
| 批准卡（`stream_block` 工具批准） | `HuxCard` + 自定义 3px 语义色条 + `HuxButton` 按钮组 | 批准=`approve` 绿底 / 本会话=`keyCap` 浅灰 / 拒绝=`reject` 红文字；**不脉冲**（规范理性克制） |
| 工具卡 | `HuxCard`（白底+左色条） | 内含深色代码块（见下）+ 复制按钮（保留） |
| 思考块 | 折叠容器（可 `HuxCard` 或自研） | 颜色 `think` 灰，展开/折叠动画保留 |
| 错误可见化（§7.3 `relay.error`） | `HuxSnackbar` | 当前只存储不展示 → 改为顶部/底部 Snackbar 提示，语义色 |
| 级联配置菜单 | 形态保留，UI 重绘 | `HuxCard` 面板 + 自研手风琴行（AnimatedCrossFade + chevron 旋转）；宽度沿用收窄后值 |
| 三态灯 | 小圆点（形态保留） | 颜色接 hux 语义令牌：在线=`approve` / 降级=`warning` / 离线=`placeholder` |
| 历史抽屉项 | `HuxSidebarItem` / `ListTile` 风格 | 左状态点+标题，右相对时间+cwd 末段；无分割线 |
| 底部输入区 | `HuxInput` / `HuxTextarea`（圆角 20 白底） | 左 `+` 号（`HuxIconButton` 风）、右发送/停（`HuxButton`） |
| 弹窗 / 确认 / 会话切换 | `HuxDialog` / `HuxBottomSheet` / `HuxActionSheet` | 多尺寸、动画现成 |
| 菜单体系（§1） | `HuxContextMenu` / `HuxCommand` / `HuxTooltip` | 补出入场动画、scrim、返回键关闭、无障碍 |
| 顶部导航三段式 | 自研布局 + hux 点缀 | 汉堡/三态灯/mode 菜单接 hux 视觉 |
| **活的流 Markdown** | **`flutter_markdown`** | 替代自研 `MarkdownView`；`MarkdownStyleSheet` 接 `app_theme` 令牌；`selectable: true`；`onTapLink` → `url_launcher` |
| **深色代码块** | **`flutter_markdown` `codeblockBuilder` + `syntax_highlight`** | 深底容器 + 语言标签 + 复制按钮（保留）；`syntax_highlight` 包成 `SyntaxHighlighter` 上色 |
| 用户消息气泡 | 自研 Row（右对齐 `accent` 淡底） | 气泡为定制，保留；配色接 `app_theme` |

---

## 5. 暗色主题落地（§10）

- 规范将暗色登记为「月之暗面签名形态」可选变体；hux 内置 `HuxTheme.darkTheme`，天然契合。
- 落地：在 `app_theme.dart` 提供 `lightTheme` / `darkTheme` 两个 `ThemeData`（基于 `HuxTheme` + 规范令牌覆盖），`MaterialApp(theme:..., darkTheme:...)`。
- 暗色中性色阶按规范反向映射（深背景、浅文字），主色沿用 hux 中性主色（不采用 Kimi 紫）。
- `flutter_markdown` 提供 `MarkdownStyleSheet` 的 dark 变体或手动映射，确保暗色下代码块/正文可读。
- 主题切换开关：顶栏或设置入口切换 `ThemeMode`，持久化到本地。

---

## 6. 实施阶段（切片，每阶段独立提交）

- **阶段 0 · 地基**：✅ 已完成。`pubspec` 加依赖 + 配置 Manrope；`lib/theme/app_theme.dart` 基于 `HuxTheme.lightTheme/darkTheme` copyWith 落地脚手架背景/文本映射；`main.dart` 接 `light()`/`dark()`（暗色开关留阶段 4）。**前提订正**：用户澄清规范未指定 Kimi 紫，故 `accent` 改为 hux 近中性主色，不覆盖种子色。
- **阶段 1 · 试点切片（活的流）**：✅ 已完成。`MarkdownView` 换 `flutter_markdown` + `syntax_highlight` 深色代码块；链接可点、代码高亮、复制按钮保留（测试 `markdown_test` 通过）。注：纯文本对话与旧自研渲染视觉接近，差异主要体现在代码块语法高亮。
- **阶段 2 · 通用组件**：✅ 已完成。发送/停止按钮、批准卡按钮 → `HuxButton`；tool 卡、批准卡 → `HuxCard`；busy/attach/relay.error toast → `HuxSnackbar`（错误详情 `AlertDialog` → `HuxDialog`）；复制 toast → `HuxSnackbar`。错误可见化 §7.3 落地。
- **阶段 3 · 导航与菜单**：✅ 已完成。级联配置菜单 / 模式菜单弹出面板 `Container`→`HuxCard`（圆角20、surface、hairline 边框、elevation 0、ClipRRect 防溢出）；顶栏汉堡 `_iconBtn`→`HuxButton`(ghost)；抽屉「新建会话」→`HuxButton`(primary)；**composer 输入框适配修复**（用户反馈 hux 按钮与输入框割裂）：`+` 按钮→`HuxButton`(ghost)，发送键显式 `primaryColor: AppColors.textPrimary`（修复回退近白种子色导致的发白），三者统一 32×32 图标按钮。三态灯已用 hux 语义色（approve/warning/placeholder），无需改；菜单动画/scrim/返回键（§1）由 `PopupAnimator` 在阶段1/2 已落地。
- **阶段 4 · 暗色与对齐**：✅ 已完成。`pubspec` 加 `shared_preferences`；新建 `lib/theme/theme_mode_store.dart`（`themeModeNotifier` 实时切换 + `loadThemeMode/setThemeMode` 持久化到本地键 `sentinel.themeMode`）；`main.dart` 用 `ValueListenableBuilder` 接线 `themeMode`；顶栏加 sun/moon 切换按钮（`AppIcons.sun/moon`）。**全量令牌对齐**：中性色阶从写死常量改为上下文感知 `AppColors.XOf(context)`（委托 `HuxTokens`，130 处调用点转换），`AppText` 摘掉写死颜色改继承主题色；命令/代码块深底保持固定 `const Color(0xFF1D1D1F)`（明暗均深色）。`analyze` No issues / `test` 7/7，kimi_core 动画保留。

---

## 7. 风险与回滚预案

| 风险 | 缓解 / 回滚 |
|---|---|
| hux 成熟度（2026-05 首发，评分未披露） | 阶段 0/1 先验证；遇 breaking/不兼容，回退该阶段 commit，保留自研组件文件不删 |
| 引入后双设计系统并存 | 每个阶段独立 git 提交，可单独 `revert`；自研文件仅停用引用、不删除，回滚即恢复 |
| 与「先保留效果」节奏冲突 | 分阶段切片，阶段 1 走查通过才继续；任何阶段出问题即停在当前已验证态（含第一版 breathing dots） |
| 字体包体/许可 | Manrope 为 SIL OFL 1.1，合规；如体积敏感可后续换系统字体 |
| 功能性修复回退 | 滚动防劫持、复制、会话关闭、Unknown sessionId 热修在替换中**只改引用不改逻辑**，回滚不影响 |

---

## 8. 验收标准

- `flutter analyze` → No issues；`flutter test` → 全过（基线 7/7 不回退）。
- 浅色/暗色双主题可切换，令牌与 `SENTINEL UI 风格规范 v1.0` 一致（hux 中性主色、圆角20、柔和阴影）。
- 功能性修复（滚动/复制/会话关闭/热修）全部保留、行为不变。
- 用户逐屏走查：活的流、批准卡、级联菜单、历史抽屉、错误提示、暗色模式。
- 规范待修项至少落地：暗色主题（§10）、菜单动画（§1）、错误可见化（§7.3）。
