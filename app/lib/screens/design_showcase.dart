import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';

/// SENTINEL Design System Showcase。
/// 一屏展示全部令牌与核心组件，供真机确认规范落地效果。
class DesignShowcase extends StatefulWidget {
  const DesignShowcase({super.key});

  @override
  State<DesignShowcase> createState() => _DesignShowcaseState();
}

class _DesignShowcaseState extends State<DesignShowcase> {
  String _mode = 'default';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.pageMargin,
            vertical: AppSpacing.xl,
          ),
          children: [
            _buildHeader(),
            const SizedBox(height: AppSpacing.xxl),
            const _Section(label: '01 · COLOR', title: '色彩令牌'),
            _buildColors(),
            const SizedBox(height: AppSpacing.xxl),
            const _Section(label: '02 · TYPE', title: '字体阶梯'),
            _buildType(),
            const SizedBox(height: AppSpacing.xxl),
            const _Section(label: '03 · APPROVAL', title: '批准卡'),
            const _ApprovalCard(
              critical: true,
              title: 'Bash · 删除构建产物',
              command: 'rm -rf build/ && npm run deploy',
              reason: '命中关键清单（rm -rf / deploy），需要你确认。',
            ),
            const SizedBox(height: AppSpacing.lg),
            const _ApprovalCard(
              critical: false,
              title: 'Bash · 查看覆盖率',
              command: 'cat coverage.txt',
              reason: '纯读命令，未命中关键清单。',
            ),
            const SizedBox(height: AppSpacing.xxl),
            const _Section(label: '04 · STREAM', title: '活的流'),
            _buildStream(),
            const SizedBox(height: AppSpacing.xxl),
            const _Section(label: '05 · STATE & MODE', title: '三态灯与模式'),
            _buildStates(),
            const SizedBox(height: AppSpacing.xxl),
            const _Section(label: '06 · HISTORY', title: '历史会话项'),
            _buildHistory(),
            const SizedBox(height: AppSpacing.xxl),
            const _Section(label: '07 · INPUT', title: '输入区'),
            _buildInput(),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  // ---- Header：品牌 + 点阵装饰（超级符号）----
  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _DotMatrix(),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'SENTINEL',
          style: AppText.title1.copyWith(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text('DESIGN SYSTEM · v1.0', style: AppText.monoCaption.copyWith(letterSpacing: 1.5)),
        const SizedBox(height: AppSpacing.sm),
        Text('现代极简 · 理性克制 · 内容为主', style: AppText.caption),
      ],
    );
  }

  // ---- 01 色彩 ----
  Widget _buildColors() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('中性 · 85%', style: AppText.caption),
        const SizedBox(height: AppSpacing.sm),
        Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.md, children: [
          _swatch('background', AppColors.background, border: true),
          _swatch('surface', AppColors.surface, border: true),
          _swatch('keyCap', AppColors.keyCap),
          _swatch('textPrimary', AppColors.textPrimary),
          _swatch('textSecondary', AppColors.textSecondary),
        ]),
        const SizedBox(height: AppSpacing.lg),
        Text('语义 · 5%（仅决策点）', style: AppText.caption),
        const SizedBox(height: AppSpacing.sm),
        Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.md, children: [
          _swatch('accent', AppColors.accent),
          _swatch('approve', AppColors.approve),
          _swatch('reject', AppColors.reject),
          _swatch('warning', AppColors.warning),
        ]),
      ],
    );
  }

  Widget _swatch(String name, Color c, {bool border = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 56,
          height: 40,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(AppRadius.thumbnail),
            border: border ? Border.all(color: AppColors.hairline) : null,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(name, style: AppText.monoCaption),
      ],
    );
  }

  // ---- 02 字体 ----
  Widget _buildType() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('title1 · 17 Medium 页面标题', style: AppText.title1),
        const SizedBox(height: AppSpacing.md),
        Text('title2 · 16 Medium 弹窗标题', style: AppText.title2),
        const SizedBox(height: AppSpacing.md),
        Text('body · 15 Regular — 核心阅读内容', style: AppText.body),
        const SizedBox(height: AppSpacing.md),
        Text('callout · 13 Regular 工具描述', style: AppText.callout),
        const SizedBox(height: AppSpacing.md),
        Text('caption · 12 Regular 时间 / cwd 辅助', style: AppText.caption),
        const SizedBox(height: AppSpacing.md),
        Text('mono · echo "SENTINEL"', style: AppText.mono),
      ],
    );
  }

  // ---- 04 活的流 ----
  Widget _buildStream() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 用户消息：右对齐 accent 淡底气泡
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm + 2,
            ),
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text('运行 echo SENTINEL 并告诉我输出', style: AppText.body),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const _ThinkingBlock(),
        const SizedBox(height: AppSpacing.lg),
        const _ToolCard(),
        const SizedBox(height: AppSpacing.lg),
        // agent 回复：左对齐无气泡纯文字（减噪）
        const Text('命令输出为：SENTINEL', style: AppText.body),
      ],
    );
  }

  // ---- 05 三态 + 模式 ----
  Widget _buildStates() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _stateDot(const _BreathingDot(color: AppColors.approve), '在线'),
          const SizedBox(width: AppSpacing.xl),
          _stateDot(_plainDot(AppColors.warning), '降级'),
          const SizedBox(width: AppSpacing.xl),
          _stateDot(_plainDot(AppColors.placeholder), '离线'),
        ]),
        const SizedBox(height: AppSpacing.lg),
        const _ModeSelector(),
      ],
    );
  }

  Widget _stateDot(Widget dot, String label) {
    return Row(children: [
      dot,
      const SizedBox(width: AppSpacing.xs + 2),
      Text(label, style: AppText.caption),
    ]);
  }

  Widget _plainDot(Color c) =>
      Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle));

  Widget _modeChip(IconData icon, String label, String mode) {
    final selected = _mode == mode;
    return _Pressable(
      onTap: () => setState(() => _mode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.keyCap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: selected ? AppColors.accent : AppColors.textSecondary),
          const SizedBox(width: AppSpacing.xs + 2),
          Text(
            label,
            style: AppText.callout.copyWith(
              color: selected ? AppColors.accent : AppColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ]),
      ),
    );
  }

  // ---- 06 历史项 ----
  Widget _buildHistory() {
    return Column(children: [
      _historyItem(true, '运行 echo HI', '2 小时前', 'kimi-code-multi-device/relay'),
      const SizedBox(height: AppSpacing.listItemGap),
      _historyItem(false, '请记住数字 42', '昨天', 'kimi-code-multi-device'),
      const SizedBox(height: AppSpacing.listItemGap),
      _historyItem(false, 'New Session', '3 天前', 'v0probe'),
    ]);
  }

  Widget _historyItem(bool active, String title, String time, String cwd) {
    return _Pressable(
      onTap: () {},
      child: Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? AppColors.approve : AppColors.placeholder,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.body),
            const SizedBox(height: 2),
            Text(cwd, style: AppText.monoCaption),
          ]),
        ),
        Text(time, style: AppText.caption),
      ]),
    );
  }

  // ---- 07 输入区 ----
  Widget _buildInput() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.input,
      ),
      child: Row(children: [
        // 左 + 号（浅灰圆形背景）
        Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(color: AppColors.keyCap, shape: BoxShape.circle),
          child: const Icon(AppIcons.plus, size: 18, color: AppColors.textSecondary),
        ),
        const SizedBox(width: AppSpacing.md),
        const Expanded(child: Text('尽管问…', style: AppText.placeholder)),
        // 右 发送（深灰圆形背景）
        Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(color: AppColors.textPrimary, shape: BoxShape.circle),
          child: const Icon(AppIcons.send, size: 16, color: AppColors.surface),
        ),
      ]),
    );
  }
}

// ================= 组件 =================

/// 区块标题：mono 标签 + title1。
class _Section extends StatelessWidget {
  final String label;
  final String title;
  const _Section({required this.label, required this.title});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.monoCaption.copyWith(letterSpacing: 1.5)),
        const SizedBox(height: AppSpacing.xs),
        Text(title, style: AppText.title1),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// 点阵装饰：4 个圆角矩形阵列横向排列，灰度为主点缀低饱和彩色。
class _DotMatrix extends StatelessWidget {
  const _DotMatrix();
  static const double _dot = 6;
  static const double _gap = 5;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        4,
        (b) => Padding(
          padding: EdgeInsets.only(right: b < 3 ? 12 : 0),
          child: _block(b),
        ),
      ),
    );
  }

  Widget _block(int seed) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (r) => Padding(
          padding: EdgeInsets.only(bottom: r < 2 ? _gap : 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(4, (c) {
              final n = (seed * 13 + r * 7 + c * 5) % 10;
              // 灰度为主（60%），点缀低饱和彩色
              final color = n < 6 ? const Color(0xFFD4D6DA) : AppColors.dots[n - 5];
              return Container(
                width: _dot,
                height: _dot,
                margin: EdgeInsets.only(right: c < 3 ? _gap : 0),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              );
            }),
          ),
        ),
      ),
    );
  }
}

/// 批准卡：白底大圆角 + 柔和阴影 + 左色条（关键=红）+ 胶囊按钮。静态突出，不脉冲。
class _ApprovalCard extends StatelessWidget {
  final bool critical;
  final String title;
  final String command;
  final String reason;

  const _ApprovalCard({
    required this.critical,
    required this.title,
    required this.command,
    required this.reason,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.card,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: critical ? AppColors.reject : AppColors.hairline,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.card),
                  bottomLeft: Radius.circular(AppRadius.card),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(
                        AppIcons.terminal,
                        size: 16,
                        color: critical ? AppColors.reject : AppColors.textSecondary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(title, style: AppText.title2)),
                      if (critical)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.rejectSoft,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(
                            '关键命令',
                            style: AppText.monoCaption.copyWith(color: AppColors.reject),
                          ),
                        ),
                    ]),
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(AppRadius.thumbnail),
                      ),
                      child: Text(command, style: AppText.mono),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(reason, style: AppText.caption),
                    const SizedBox(height: AppSpacing.md),
                    Row(children: const [
                      _Pill(label: '批准', bg: AppColors.approve, fg: AppColors.surface),
                      SizedBox(width: AppSpacing.sm),
                      _Pill(label: '本会话', bg: AppColors.keyCap, fg: AppColors.textPrimary),
                      SizedBox(width: AppSpacing.sm),
                      _Pill(label: '拒绝', bg: AppColors.rejectSoft, fg: AppColors.reject),
                    ]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 胶囊按钮（全圆角），按压有轻量透明度反馈。
class _Pill extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _Pill({required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: _Pressable(
        onTap: () {},
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppText.callout.copyWith(color: fg, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }
}

/// 思考块：可折叠浅灰块。
class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock();

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.thinkSoft,
        borderRadius: BorderRadius.circular(AppRadius.thumbnail),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Pressable(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm + 2,
              ),
              child: Row(children: [
                Icon(AppIcons.chevronRight, size: 14, color: AppColors.think),
                const SizedBox(width: AppSpacing.xs),
                Text('思考中…', style: AppText.callout.copyWith(color: AppColors.think)),
              ]),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
              child: Text(
                '用户想运行 echo 命令，这是个无害的操作，直接执行并返回输出即可…',
                style: AppText.callout.copyWith(
                  color: AppColors.think,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            crossFadeState: _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}

/// 工具卡：白底 + 左色条 + terminal 图标 + 等宽命令/输出。
class _ToolCard extends StatelessWidget {
  const _ToolCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.thumbnail),
        boxShadow: AppShadows.card,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 4,
              decoration: const BoxDecoration(
                color: AppColors.approve,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.thumbnail),
                  bottomLeft: Radius.circular(AppRadius.thumbnail),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(AppIcons.terminal, size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: AppSpacing.sm),
                      const Text('Bash', style: AppText.mono),
                      const Spacer(),
                      Text('完成', style: AppText.monoCaption.copyWith(color: AppColors.approve)),
                    ]),
                    const SizedBox(height: AppSpacing.sm),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.sm + 2),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('echo SENTINEL', style: AppText.mono),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text('✓ SENTINEL', style: AppText.monoCaption.copyWith(color: AppColors.approve)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 在线绿点：轻量呼吸（表示"活着"，功能含义，非装饰）。
class _BreathingDot extends StatefulWidget {
  final Color color;
  const _BreathingDot({required this.color});

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.45).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 按压反馈：轻量透明度变化（克制，无水波纹）。
class _Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _Pressable({required this.child, required this.onTap});

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedOpacity(
        opacity: _down ? 0.55 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: widget.child,
      ),
    );
  }
}

/// 模式定义。
class _Mode {
  final String id;
  final IconData icon;
  final String label;
  const _Mode(this.id, this.icon, this.label);
}

/// 模式选择器：两态。
/// 收起态 = 小指示器（中性、安静，不与内容抢注意力）；
/// 展开态 = 全部选项（accent 仅在此刻出现，辅助决策）。
/// 选中即收起 —— 决策控件在决策后退场。
class _ModeSelector extends StatefulWidget {
  const _ModeSelector();

  @override
  State<_ModeSelector> createState() => _ModeSelectorState();
}

class _ModeSelectorState extends State<_ModeSelector> {
  static const List<_Mode> _modes = [
    _Mode('default', AppIcons.modeManual, '手动'),
    _Mode('plan', AppIcons.modePlan, '只读'),
    _Mode('auto', AppIcons.modeAuto, '自动'),
    _Mode('yolo', AppIcons.modeYolo, 'YOLO'),
  ];

  String _modeId = 'default';
  bool _expanded = false;

  _Mode get _current => _modes.firstWhere((m) => m.id == _modeId);

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.centerLeft,
      child: _expanded ? _buildOptions() : _buildCollapsed(),
    );
  }

  /// 收起态：一个小胶囊，全中性色（无 accent），安静地标明当前模式。
  Widget _buildCollapsed() {
    return _Pressable(
      onTap: () => setState(() => _expanded = true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.keyCap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_current.icon, size: 13, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.xs + 2),
          Text(_current.label, style: AppText.callout.copyWith(color: AppColors.textPrimary)),
          const SizedBox(width: AppSpacing.xs),
          const Icon(AppIcons.chevronDown, size: 12, color: AppColors.textSecondary),
        ]),
      ),
    );
  }

  /// 展开态：全部选项，当前项打勾。点选后立即收起。
  Widget _buildOptions() {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: _modes.map(_optionChip).toList(),
    );
  }

  Widget _optionChip(_Mode m) {
    final selected = _modeId == m.id;
    return _Pressable(
      onTap: () => setState(() {
        _modeId = m.id;
        _expanded = false; // 选完即收，把注意力还给内容
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.keyCap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(m.icon, size: 14, color: selected ? AppColors.accent : AppColors.textSecondary),
          const SizedBox(width: AppSpacing.xs + 2),
          Text(
            m.label,
            style: AppText.callout.copyWith(
              color: selected ? AppColors.accent : AppColors.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (selected) ...[
            const SizedBox(width: AppSpacing.xs),
            const Icon(AppIcons.check, size: 12, color: AppColors.accent),
          ],
        ]),
      ),
    );
  }
}