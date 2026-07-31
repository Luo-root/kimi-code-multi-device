import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';
import '../widgets/common.dart';
import 'design_showcase.dart';

// ---------- 假数据（接 WebSocket 后由中继填充）----------

class _Sess {
  final String id;
  final String title;
  const _Sess(this.id, this.title);
}

class _Ws {
  final String name;
  final List<_Sess> sessions;
  const _Ws(this.name, this.sessions);
}

const _modeOptions = [
  DropdownOption(id: 'default', label: '手动审批', icon: AppIcons.modeManual),
  DropdownOption(id: 'plan', label: '只读规划', icon: AppIcons.modePlan),
  DropdownOption(id: 'auto', label: '自动', icon: AppIcons.modeAuto),
  DropdownOption(id: 'yolo', label: 'YOLO', icon: AppIcons.modeYolo),
];

const _modelOptions = [
  DropdownOption(id: 'flash', label: 'Flash'),
  DropdownOption(id: 'pro', label: 'Pro'),
];

const _workspaces = [
  _Ws('kimi-code-multi-device', [
    _Sess('s1', '重构 payment'),
    _Sess('s2', '运行 echo HI'),
    _Sess('s3', '请记住数字 42'),
  ]),
  _Ws('v0probe', [
    _Sess('s4', '运行 sleep 3 && echo DONE_B'),
    _Sess('s5', '请运行 echo PROBE_HELLO'),
  ]),
  _Ws('relay', [
    _Sess('s6', '哈喽，你知道 DeepSeek 发了新模型吗'),
    _Sess('s7', 'hello，你是什么模型呀'),
  ]),
];

// ---------- 主页 ----------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String _modeId = 'default';
  String _modelId = 'flash';
  String _currentId = 's1';

  bool _pending = true; // 模拟：是否有一个待批准的工具调用
  bool _approved = false;
  bool _highlight = false; // 流内锚点 ↔ 底部浮层 联动高亮

  void _focusSheet() {
    setState(() => _highlight = true);
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _highlight = false);
    });
  }

  void _decide(bool approve) => setState(() {
        _approved = approve;
        _pending = false;
      });

  @override
  Widget build(BuildContext context) {
    final bottomPad = _pending ? 300.0 : 110.0;
    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: Drawer(
        width: 280,
        backgroundColor: AppColors.background,
        child: _SessionDrawer(
          workspaces: _workspaces,
          currentId: _currentId,
          onSelect: (id) => setState(() => _currentId = id),
          onNew: () {},
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              modeId: _modeId,
              onMode: (m) => setState(() => _modeId = m),
              modelId: _modelId,
              onModel: (m) => setState(() => _modelId = m),
              onPalette: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DesignShowcase()),
              ),
            ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _Stream(
                    bottomPad: bottomPad,
                    pending: _pending,
                    approved: _approved,
                    onFocus: _focusSheet,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _BottomDock(
                      pending: _pending,
                      highlight: _highlight,
                      onApprove: () => _decide(true),
                      onReject: () => _decide(false),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 顶部导航（单行：左汉堡 / 中 model+mode / 右状态+工具）----------

class _TopBar extends StatelessWidget {
  final String modeId;
  final ValueChanged<String> onMode;
  final String modelId;
  final ValueChanged<String> onModel;
  final VoidCallback onPalette;

  const _TopBar({
    required this.modeId,
    required this.onMode,
    required this.modelId,
    required this.onModel,
    required this.onPalette,
  });

  @override
  Widget build(BuildContext context) {
    final curMode = _modeOptions.firstWhere((m) => m.id == modeId);
    final curModel = _modelOptions.firstWhere((m) => m.id == modelId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: Row(
        children: [
          _iconBtn(AppIcons.menu,
              onTap: () => Scaffold.of(context).openDrawer()),
          const SizedBox(width: 4),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ChipDropdown(
                  triggerIcon: AppIcons.modelChip,
                  triggerLabel: curModel.label,
                  options: _modelOptions,
                  selectedId: modelId,
                  onSelect: onModel,
                  minWidth: 110,
                ),
                const SizedBox(width: 8),
                ChipDropdown(
                  triggerIcon: curMode.icon ?? AppIcons.modeManual,
                  triggerLabel: curMode.label,
                  options: _modeOptions,
                  selectedId: modeId,
                  onSelect: onMode,
                  minWidth: 130,
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          const BreathingDot(color: AppColors.approve),
          const SizedBox(width: 12),
          _iconBtn(AppIcons.settings),
          const SizedBox(width: 4),
          _iconBtn(AppIcons.palette, onTap: onPalette),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, {VoidCallback? onTap}) {
    return Pressable(
      onTap: onTap ?? () {},
      child: SizedBox(
        width: 36,
        height: 36,
        child: Icon(icon, size: 20, color: AppColors.textPrimary),
      ),
    );
  }
}

// ---------- 会话抽屉（按工作区分组，参考 kimi web）----------

class _SessionDrawer extends StatelessWidget {
  final List<_Ws> workspaces;
  final String currentId;
  final ValueChanged<String> onSelect;
  final VoidCallback onNew;

  const _SessionDrawer({
    super.key,
    required this.workspaces,
    required this.currentId,
    required this.onSelect,
    required this.onNew,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Pressable(
              onTap: () {
                onNew();
                Navigator.of(context).pop();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.thumbnail),
                  boxShadow: AppShadows.input,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: const BoxDecoration(
                        color: AppColors.keyCap,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(AppIcons.plus,
                          size: 15, color: AppColors.textSecondary),
                    ),
                    const SizedBox(width: 10),
                    Text('新建会话',
                        style: AppText.callout.copyWith(
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('工作区', style: AppText.monoCaption),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              children: [
                for (final ws in workspaces) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                    child: Row(
                      children: [
                        const Icon(AppIcons.folder,
                            size: 15, color: AppColors.textSecondary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ws.name,
                            style: AppText.callout.copyWith(
                                fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final s in ws.sessions)
                    _sessionRow(context, s),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionRow(BuildContext context, _Sess s) {
    final sel = s.id == currentId;
    return Pressable(
      onTap: () {
        onSelect(s.id);
        Navigator.of(context).pop();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: sel ? AppColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.thumbnail),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: sel ? AppColors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                  child: Text(
                    s.title,
                    style: AppText.callout.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- 活的流 ----------

class _Stream extends StatelessWidget {
  final double bottomPad;
  final bool pending;
  final bool approved;
  final VoidCallback onFocus;

  const _Stream({
    required this.bottomPad,
    required this.pending,
    required this.approved,
    required this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        8,
        AppSpacing.pageMargin,
        bottomPad,
      ),
      children: [
        const _UserBubble('运行 echo SENTINEL 并告诉我输出'),
        const SizedBox(height: AppSpacing.lg),
        const _ThinkingBlock('用户想运行 echo，这是个无害操作，直接执行并返回输出即可…'),
        const SizedBox(height: AppSpacing.lg),
        const _ToolCardDone(
          title: 'Bash',
          command: 'echo SENTINEL',
          output: 'SENTINEL',
          ok: true,
        ),
        const SizedBox(height: AppSpacing.lg),
        const _ReplyText('命令输出为：`SENTINEL`'),
        const SizedBox(height: AppSpacing.lg),
        const _UserBubble('再清理一下 build 目录'),
        const SizedBox(height: AppSpacing.lg),
        const _ThinkingBlock('要删除 build 目录，这是不可逆操作，必须先取得用户许可…'),
        const SizedBox(height: AppSpacing.lg),
        if (pending)
          _ApprovalAnchor(
            command: 'rm -rf build/ && npm run deploy',
            onTap: onFocus,
          )
        else
          _ToolCardDone(
            title: 'Bash',
            command: 'rm -rf build/ && npm run deploy',
            output: approved ? 'build cleaned, deployed to prod' : '已拒绝',
            ok: approved,
          ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  final String text;
  const _UserBubble(this.text);
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.accentSoft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text, style: AppText.body),
      ),
    );
  }
}

class _ReplyText extends StatelessWidget {
  final String text;
  const _ReplyText(this.text);
  @override
  Widget build(BuildContext context) => Text(text, style: AppText.body);
}

class _ThinkingBlock extends StatefulWidget {
  final String text;
  const _ThinkingBlock(this.text);
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
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Pressable(
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                      size: 14,
                      color: AppColors.think,
                    ),
                    const SizedBox(width: 6),
                    Text('思考',
                        style:
                            AppText.callout.copyWith(color: AppColors.think)),
                  ],
                ),
              ),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(
                  widget.text,
                  style: AppText.callout.copyWith(
                    color: AppColors.think,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolCardDone extends StatefulWidget {
  final String title;
  final String command;
  final String output;
  final bool ok;
  const _ToolCardDone({
    required this.title,
    required this.command,
    required this.output,
    required this.ok,
  });
  @override
  State<_ToolCardDone> createState() => _ToolCardDoneState();
}

class _ToolCardDoneState extends State<_ToolCardDone> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final statusColor = widget.ok ? AppColors.approve : AppColors.reject;
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
              decoration: BoxDecoration(
                color: statusColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.thumbnail),
                  bottomLeft: Radius.circular(AppRadius.thumbnail),
                ),
              ),
            ),
            Expanded(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Pressable(
                      onTap: () => setState(() => _open = !_open),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 11,
                        ),
                        child: Row(
                          children: [
                            const Icon(AppIcons.terminal,
                                size: 14, color: AppColors.textSecondary),
                            const SizedBox(width: 8),
                            Text(widget.title, style: AppText.mono),
                            const Spacer(),
                            Icon(widget.ok ? AppIcons.check : AppIcons.close,
                                size: 13, color: statusColor),
                            const SizedBox(width: 4),
                            Text(widget.ok ? '完成' : '已拒绝',
                                style: AppText.monoCaption
                                    .copyWith(color: statusColor)),
                            const SizedBox(width: 6),
                            Icon(
                              _open
                                  ? AppIcons.chevronDown
                                  : AppIcons.chevronRight,
                              size: 13,
                              color: AppColors.placeholder,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_open) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(widget.command, style: AppText.mono),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Text(
                          '${widget.ok ? '✓' : '✗'} ${widget.output}',
                          style: AppText.monoCaption
                              .copyWith(color: statusColor),
                        ),
                      ),
                    ],
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

class _ApprovalAnchor extends StatelessWidget {
  final String command;
  final VoidCallback onTap;
  const _ApprovalAnchor({required this.command, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
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
                  color: AppColors.warning,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(AppRadius.thumbnail),
                    bottomLeft: Radius.circular(AppRadius.thumbnail),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(AppIcons.terminal,
                          size: 14, color: AppColors.warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(command,
                            style: AppText.mono,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: AppColors.warning,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text('待批准',
                          style: AppText.monoCaption
                              .copyWith(color: AppColors.warning)),
                      const SizedBox(width: 4),
                      const Icon(AppIcons.chevronDown,
                          size: 13, color: AppColors.warning),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- 底部 dock ----------

class _BottomDock extends StatelessWidget {
  final bool pending;
  final bool highlight;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _BottomDock({
    required this.pending,
    required this.highlight,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 24,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00F7F8FA), AppColors.background],
            ),
          ),
        ),
        Container(
          color: AppColors.background,
          padding: EdgeInsets.only(bottom: 12 + mq.padding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pending) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.pageMargin),
                  child: _ApprovalSheet(
                    highlight: highlight,
                    onApprove: onApprove,
                    onReject: onReject,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: AppSpacing.pageMargin),
                child: _InputBar(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ApprovalSheet extends StatefulWidget {
  final bool highlight;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  const _ApprovalSheet({
    required this.highlight,
    required this.onApprove,
    required this.onReject,
  });
  @override
  State<_ApprovalSheet> createState() => _ApprovalSheetState();
}

class _ApprovalSheetState extends State<_ApprovalSheet> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.card,
        border: widget.highlight
            ? Border.all(color: AppColors.accent, width: 1.5)
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(AppIcons.terminal,
                    size: 16, color: AppColors.reject),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Bash · 删除构建产物', style: AppText.title2),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.rejectSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text('关键命令',
                      style: AppText.monoCaption
                          .copyWith(color: AppColors.reject)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(AppRadius.thumbnail),
              ),
              child:
                  const Text('rm -rf build/ && npm run deploy', style: AppText.mono),
            ),
            const SizedBox(height: AppSpacing.sm),
            Pressable(
              onTap: () => setState(() => _open = !_open),
              child: Row(
                children: [
                  Icon(_open ? AppIcons.chevronDown : AppIcons.chevronRight,
                      size: 13, color: AppColors.accent),
                  const SizedBox(width: 5),
                  Text('展开看完整上下文',
                      style: AppText.callout.copyWith(color: AppColors.accent)),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _open
                  ? Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        border: Border.all(color: AppColors.hairline),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '- 将删除 ./build 下 142 个文件\n'
                        '- 随后向 prod 环境部署（不可逆）',
                        style: AppText.monoCaption,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text('Kimi 想清理旧 build 再部署——命中关键清单，需要你确认。',
                style: AppText.caption),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                _Pill(
                    label: '批准',
                    bg: AppColors.approve,
                    fg: AppColors.surface,
                    onTap: widget.onApprove),
                const SizedBox(width: AppSpacing.sm),
                _Pill(
                    label: '本会话',
                    bg: AppColors.keyCap,
                    fg: AppColors.textPrimary,
                    onTap: widget.onApprove),
                const SizedBox(width: AppSpacing.sm),
                _Pill(
                    label: '拒绝',
                    bg: AppColors.rejectSoft,
                    fg: AppColors.reject,
                    onTap: widget.onReject),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;
  const _Pill({
    required this.label,
    required this.bg,
    required this.fg,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: AppText.callout
                  .copyWith(color: fg, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.input,
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration:
                const BoxDecoration(color: AppColors.keyCap, shape: BoxShape.circle),
            child:
                const Icon(AppIcons.plus, size: 18, color: AppColors.textSecondary),
          ),
          const SizedBox(width: AppSpacing.md),
          const Expanded(child: Text('尽管问…', style: AppText.placeholder)),
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
                color: AppColors.textPrimary, shape: BoxShape.circle),
            child: const Icon(AppIcons.send, size: 16, color: AppColors.surface),
          ),
        ],
      ),
    );
  }
}