import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';
import '../widgets/common.dart';
import 'design_showcase.dart';

// ---------- 假数据：provider→model→effort 级联，演示"思考档数随模型动态" ----------

class _ModelDef {
  final String label;
  final List<String> efforts; // effort id 列表，档数随模型变
  const _ModelDef(this.label, this.efforts);
}

class _ProviderDef {
  final String id;
  final String label;
  final Map<String, _ModelDef> models;
  const _ProviderDef(this.id, this.label, this.models);
}

const _providers = [
  _ProviderDef('openai', 'OpenAI', {
    'gpt-5': _ModelDef('GPT-5', ['low', 'medium', 'high']),
    'gpt-5-mini': _ModelDef('GPT-5 Mini', ['low', 'medium']),
  }),
  _ProviderDef('myprovider', 'MyProvider', {
    'my-model': _ModelDef('My Model', ['low', 'medium', 'high', 'xhigh']),
  }),
  _ProviderDef('anthropic', 'Anthropic', {
    'claude': _ModelDef('Claude', ['low', 'medium', 'high']),
  }),
];

const _effortLabel = {
  'low': '低',
  'medium': '中',
  'high': '高',
  'xhigh': '超高',
  'max': '极强',
};

const _modeOptions = [
  DropdownOption(id: 'default', label: '手动审批', icon: AppIcons.modeManual,
      subtitle: '危险动作逐一问你'),
  DropdownOption(id: 'plan', label: '只读规划', icon: AppIcons.modePlan,
      subtitle: '只规划，不执行工具'),
  DropdownOption(id: 'auto', label: '自动', icon: AppIcons.modeAuto,
      subtitle: 'agent 自主决策'),
  DropdownOption(id: 'yolo', label: 'YOLO', icon: AppIcons.modeYolo,
      subtitle: '自动批准，但可能问你'),
];
const _modeIcon = {
  'default': AppIcons.modeManual,
  'plan': AppIcons.modePlan,
  'auto': AppIcons.modeAuto,
  'yolo': AppIcons.modeYolo,
};

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

const _chips = ['跑下测试', 'commit 一下', '解释刚干了啥', '/status'];
const _slash = ['/status', '/usage', '/compact', '/mcp', '/skill'];

// ---------- 主页 ----------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // 级联选择
  String _providerId = _providers.first.id;
  late String _modelId = _providers.first.models.keys.first;
  late String _effortId = _providers.first.models.values.first.efforts.first;
  String _modeId = 'default';
  String _currentId = 's1';

  bool _pending = true;
  bool _approved = false;
  bool _highlight = false;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<String> _extra = [];
  String? _slashQuery; // 输入处于 "/xxx" 命令词阶段时为 xxx，否则 null

  _ProviderDef get _curProvider =>
      _providers.firstWhere((p) => p.id == _providerId);
  Map<String, _ModelDef> get _curModels => _curProvider.models;
  _ModelDef get _curModel => _curModels[_modelId] ?? _curModels.values.first;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onProvider(String id) => setState(() {
        _providerId = id;
        _modelId = _curProvider.models.keys.first;
        _effortId = _curModel.efforts.first;
      });

  void _onModel(String id) => setState(() {
        _modelId = id;
        _effortId = _curModel.efforts.first;
      });

  void _onEffort(String id) => setState(() => _effortId = id);

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

  void _send(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    setState(() {
      _extra.add(t);
      _slashQuery = null;
    });
    _inputCtrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // 输入变化：以 '/' 开头且无空格 = 命令词阶段，弹内联候选；否则收起。
  void _onInputChanged(String v) {
    final q = (v.startsWith('/') && !v.contains(' ')) ? v.substring(1) : null;
    if (q != _slashQuery) setState(() => _slashQuery = q);
  }

  // 选中 slash：填入输入框（带尾空格），不发送，光标置末，收起候选。
  void _pickSlash(String s) {
    setState(() {
      _inputCtrl.text = '$s ';
      _inputCtrl.selection =
          TextSelection.collapsed(offset: _inputCtrl.text.length);
      _slashQuery = null;
    });
  }

  void _onAttach() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('附件上传即将支持',
            style: AppText.callout.copyWith(color: AppColors.surface)),
        backgroundColor: AppColors.textPrimary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  void _openSettings() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => const _SettingsSheet(),
      );

  @override
  Widget build(BuildContext context) {
    final slashOpen = _slashQuery != null;
    final slashOpts = _slashQuery == null
        ? const <String>[]
        : _slash
            .where((s) =>
                _slashQuery!.isEmpty ||
                s.toLowerCase().contains(_slashQuery!.toLowerCase()))
            .toList();
    final bottomPad = _pending ? 360.0 : (slashOpen ? 230.0 : 150.0);

    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: Drawer(
        width: 280,
        backgroundColor: AppColors.background,
        child: _SessionDrawer(
          workspaces: _workspaces,
          currentId: _currentId,
          onSelect: (id) => setState(() => _currentId = id),
          onOpenSettings: () {
            Navigator.of(context).pop();
            _openSettings();
          },
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              providerId: _providerId,
              onProvider: _onProvider,
              modelId: _modelId,
              onModel: _onModel,
              effortId: _effortId,
              onEffort: _onEffort,
              modeId: _modeId,
              onMode: (m) => setState(() => _modeId = m),
              onPalette: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DesignShowcase()),
              ),
            ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _Stream(
                    scrollCtrl: _scrollCtrl,
                    bottomPad: bottomPad,
                    pending: _pending,
                    approved: _approved,
                    extra: _extra,
                    onFocus: _focusSheet,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _BottomDock(
                      pending: _pending,
                      highlight: _highlight,
                      controller: _inputCtrl,
                      onSend: _send,
                      onChanged: _onInputChanged,
                      onOpenPlus: _onAttach,
                      onChip: _send,
                      slashOpen: slashOpen && slashOpts.isNotEmpty,
                      slashOpts: slashOpts,
                      onPickSlash: _pickSlash,
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

// ---------- 顶部导航：左汉堡 / 中[provider·model·思考] / 右[三态灯·mode图标] ----------

class _TopBar extends StatelessWidget {
  final String providerId;
  final ValueChanged<String> onProvider;
  final String modelId;
  final ValueChanged<String> onModel;
  final String effortId;
  final ValueChanged<String> onEffort;
  final String modeId;
  final ValueChanged<String> onMode;
  final VoidCallback onPalette;

  const _TopBar({
    required this.providerId,
    required this.onProvider,
    required this.modelId,
    required this.onModel,
    required this.effortId,
    required this.onEffort,
    required this.modeId,
    required this.onMode,
    required this.onPalette,
  });

  @override
  Widget build(BuildContext context) {
    final prov = _providers.firstWhere((p) => p.id == providerId);
    final models = prov.models;
    final modelDef = models[modelId] ?? models.values.first;
    final curModelId = models.containsKey(modelId) ? modelId : models.keys.first;
    final curEffort =
        modelDef.efforts.contains(effortId) ? effortId : modelDef.efforts.first;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: Row(
        children: [
          _iconBtn(AppIcons.menu,
              onTap: () => Scaffold.of(context).openDrawer()),
          const SizedBox(width: 6),
          // 中：三个子胶囊，等分可截断
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: ChipDropdown(
                    triggerLabel: prov.label,
                    options: _providers
                        .map((p) => DropdownOption(id: p.id, label: p.label))
                        .toList(),
                    selectedId: providerId,
                    onSelect: onProvider,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: ChipDropdown(
                    triggerLabel: models[curModelId]!.label,
                    options: models.entries
                        .map((e) => DropdownOption(id: e.key, label: e.value.label))
                        .toList(),
                    selectedId: curModelId,
                    onSelect: onModel,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: ChipDropdown(
                    triggerLabel: _effortLabel[curEffort] ?? curEffort,
                    options: modelDef.efforts
                        .map((e) => DropdownOption(
                              id: e,
                              label: _effortLabel[e] ?? e,
                            ))
                        .toList(),
                    selectedId: curEffort,
                    onSelect: onEffort,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // 右：三态灯 + mode 图标菜单 + 调色板(开发期)
          const BreathingDot(color: AppColors.approve),
          const SizedBox(width: 10),
          _ModeIconMenu(modeId: modeId, onMode: onMode),
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

// ---------- mode 图标触发菜单：常驻只显图标，点开看全称+描述 ----------

class _ModeIconMenu extends StatefulWidget {
  final String modeId;
  final ValueChanged<String> onMode;
  const _ModeIconMenu({required this.modeId, required this.onMode});

  @override
  State<_ModeIconMenu> createState() => _ModeIconMenuState();
}

class _ModeIconMenuState extends State<_ModeIconMenu> {
  OverlayEntry? _entry;
  bool _down = false;
  bool get _open => _entry != null;

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    final box = context.findRenderObject() as RenderBox;
    final off = box.localToGlobal(Offset.zero);
    _entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.shrink(),
            ),
          ),
          Positioned(
            top: off.dy + box.size.height + 6,
            right: 8,
            width: 220,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                boxShadow: AppShadows.popup,
              ),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _modeOptions
                    .map((m) => _MenuRow(
                          icon: m.icon,
                          label: m.label,
                          subtitle: m.subtitle,
                          selected: m.id == widget.modeId,
                          onTap: () {
                            widget.onMode(m.id);
                            _close();
                          },
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = _modeIcon[widget.modeId] ?? AppIcons.modeManual;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: _toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: _down ? const Color(0xFFDADAE0) : AppColors.keyCap,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: AppColors.textPrimary),
      ),
    );
  }
}

/// 菜单行：图标(灰) + 黑字 + 灰副标题 + 蓝勾。
class _MenuRow extends StatefulWidget {
  final IconData? icon;
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _MenuRow({
    required this.label,
    this.icon,
    this.subtitle,
    this.selected = false,
    required this.onTap,
  });

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _down ? AppColors.keyCap : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.label,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      )),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(widget.subtitle!, style: AppText.caption),
                  ],
                ],
              ),
            ),
            if (widget.selected)
              const Padding(
                padding: EdgeInsets.only(left: 10),
                child: Icon(AppIcons.check, size: 16, color: AppColors.accent),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------- 会话抽屉：新建 + 搜索 + 工作区分组 + 底部设置 ----------

class _SessionDrawer extends StatefulWidget {
  final List<_Ws> workspaces;
  final String currentId;
  final ValueChanged<String> onSelect;
  final VoidCallback onOpenSettings;
  const _SessionDrawer({
    super.key,
    required this.workspaces,
    required this.currentId,
    required this.onSelect,
    required this.onOpenSettings,
  });

  @override
  State<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<_SessionDrawer> {
  String _q = '';

  bool _match(_Sess s) =>
      _q.isEmpty || s.title.toLowerCase().contains(_q.toLowerCase());

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 新建会话（淡化，无白卡无阴影）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Pressable(
              onTap: () => Navigator.of(context).pop(),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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
                        style: AppText.callout
                            .copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                boxShadow: AppShadows.input,
              ),
              child: Row(
                children: [
                  const Icon(AppIcons.search,
                      size: 15, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      style: AppText.callout,
                      onChanged: (v) => setState(() => _q = v),
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: '搜索会话',
                        hintStyle: AppText.placeholder,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('工作区', style: AppText.monoCaption),
          ),
          // 工作区分组（按搜索过滤）
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              children: [
                for (final ws in widget.workspaces)
                  Builder(builder: (_) {
                    final matched = ws.sessions.where(_match).toList();
                    if (matched.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                          child: Row(
                            children: [
                              const Icon(AppIcons.folder,
                                  size: 15, color: AppColors.textSecondary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(ws.name,
                                    style: AppText.callout.copyWith(
                                        fontWeight: FontWeight.w600),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
                        ),
                        for (final s in matched) _sessionRow(context, s),
                      ],
                    );
                  }),
              ],
            ),
          ),
          // 底部设置入口
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.hairline)),
            ),
            child: Pressable(
              onTap: widget.onOpenSettings,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    const Icon(AppIcons.settings,
                        size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 10),
                    Text('设置', style: AppText.callout),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionRow(BuildContext context, _Sess s) {
    final sel = s.id == widget.currentId;
    return Pressable(
      onTap: () {
        widget.onSelect(s.id);
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
                  child: Text(s.title,
                      style: AppText.callout.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
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
  final ScrollController scrollCtrl;
  final double bottomPad;
  final bool pending;
  final bool approved;
  final List<String> extra;
  final VoidCallback onFocus;

  const _Stream({
    required this.scrollCtrl,
    required this.bottomPad,
    required this.pending,
    required this.approved,
    required this.extra,
    required this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollCtrl,
      padding: EdgeInsets.fromLTRB(
          AppSpacing.pageMargin, 8, AppSpacing.pageMargin, bottomPad),
      children: [
        const _UserBubble('运行 echo SENTINEL 并告诉我输出'),
        const SizedBox(height: AppSpacing.lg),
        const _ThinkingBlock('用户想运行 echo，这是个无害操作，直接执行并返回输出即可…'),
        const SizedBox(height: AppSpacing.lg),
        const _ToolCardDone(
            title: 'Bash', command: 'echo SENTINEL', output: 'SENTINEL', ok: true),
        const SizedBox(height: AppSpacing.lg),
        const _ReplyText('命令输出为：`SENTINEL`'),
        const SizedBox(height: AppSpacing.lg),
        const _UserBubble('再清理一下 build 目录'),
        const SizedBox(height: AppSpacing.lg),
        const _ThinkingBlock('要删除 build 目录，这是不可逆操作，必须先取得用户许可…'),
        const SizedBox(height: AppSpacing.lg),
        if (pending)
          _ApprovalAnchor(
              command: 'rm -rf build/ && npm run deploy', onTap: onFocus)
        else
          _ToolCardDone(
              title: 'Bash',
              command: 'rm -rf build/ && npm run deploy',
              output: approved ? 'build cleaned, deployed to prod' : '已拒绝',
              ok: approved),
        for (final m in extra) ...[
          const SizedBox(height: AppSpacing.lg),
          _UserBubble(m),
        ],
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
                    Icon(_open ? AppIcons.chevronDown : AppIcons.chevronRight,
                        size: 14, color: AppColors.think),
                    const SizedBox(width: 6),
                    Text('思考',
                        style: AppText.callout.copyWith(color: AppColors.think)),
                  ],
                ),
              ),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(widget.text,
                    style: AppText.callout.copyWith(
                        color: AppColors.think, fontStyle: FontStyle.italic)),
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
  const _ToolCardDone(
      {required this.title,
      required this.command,
      required this.output,
      required this.ok});
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
                            horizontal: 12, vertical: 11),
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
                                color: AppColors.placeholder),
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
                        child: Row(
                          children: [
                            Icon(
                                widget.ok ? AppIcons.check : AppIcons.close,
                                size: 12,
                                color: statusColor),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(widget.output,
                                  style: AppText.monoCaption
                                      .copyWith(color: statusColor)),
                            ),
                          ],
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
                              overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                            color: AppColors.warning, shape: BoxShape.circle),
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
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onOpenPlus;
  final ValueChanged<String> onChip;
  final bool slashOpen;
  final List<String> slashOpts;
  final ValueChanged<String> onPickSlash;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _BottomDock({
    required this.pending,
    required this.highlight,
    required this.controller,
    required this.onSend,
    required this.onChanged,
    required this.onOpenPlus,
    required this.onChip,
    required this.slashOpen,
    required this.slashOpts,
    required this.onPickSlash,
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
              // 快捷回复 chip 行
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.pageMargin),
                  itemCount: _chips.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (_, i) => Pressable(
                    onTap: () => onChip(_chips[i]),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.keyCap,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      alignment: Alignment.center,
                      child: Text(_chips[i],
                          style: AppText.callout
                              .copyWith(color: AppColors.textPrimary)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // slash 内联候选：紧贴输入框上方，不遮挡输入框，可继续编辑
              if (slashOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.pageMargin, 0, AppSpacing.pageMargin, 8),
                  child: _SlashPanel(opts: slashOpts, onPick: onPickSlash),
                ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.pageMargin),
                child: _InputBar(
                  controller: controller,
                  onSend: onSend,
                  onChanged: onChanged,
                  onOpenPlus: onOpenPlus,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// slash 候选面板：白卡浮层，按已输入的 '/' 后串过滤。
class _SlashPanel extends StatelessWidget {
  final List<String> opts;
  final ValueChanged<String> onPick;
  const _SlashPanel({required this.opts, required this.onPick});
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.thumbnail),
        boxShadow: AppShadows.popup,
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
            child: Row(
              children: [
                const Icon(AppIcons.command,
                    size: 13, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Text('快捷命令 · 选中后填入，可继续编辑',
                    style: AppText.monoCaption),
              ],
            ),
          ),
          for (final s in opts)
            Pressable(
              onTap: () => onPick(s),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Text(s, style: AppText.mono),
              ),
            ),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onOpenPlus;
  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onChanged,
    required this.onOpenPlus,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.input,
      ),
      child: Row(
        children: [
          // 左 + = 附件入口
          Pressable(
            onTap: onOpenPlus,
            child: Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                  color: AppColors.keyCap, shape: BoxShape.circle),
              child:
                  const Icon(AppIcons.plus, size: 18, color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              style: AppText.body,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onChanged: onChanged,
              onSubmitted: onSend,
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '尽管问…',
                hintStyle: AppText.placeholder,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Pressable(
            onTap: () => onSend(controller.text),
            child: Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                  color: AppColors.textPrimary, shape: BoxShape.circle),
              child:
                  const Icon(AppIcons.send, size: 16, color: AppColors.surface),
            ),
          ),
        ],
      ),
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
                const Icon(AppIcons.terminal, size: 16, color: AppColors.reject),
                const SizedBox(width: 8),
                const Expanded(
                    child: Text('Bash · 删除构建产物', style: AppText.title2)),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.rejectSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text('关键命令',
                      style:
                          AppText.monoCaption.copyWith(color: AppColors.reject)),
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
  const _Pill(
      {required this.label,
      required this.bg,
      required this.fg,
      required this.onTap});
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

// ---------- 设置 ----------

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({super.key});
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _barkOn = true;
  bool _autoPass = false;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return SizedBox(
      height: h * 0.84,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: AppColors.keyCap,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
            child: Row(
              children: [
                const Icon(AppIcons.settings,
                    size: 18, color: AppColors.textPrimary),
                const SizedBox(width: 8),
                const Expanded(child: Text('设置', style: AppText.title1)),
                Pressable(
                  onTap: () => Navigator.of(context).pop(),
                  child: const SizedBox(
                    width: 32,
                    height: 32,
                    child: Icon(AppIcons.close,
                        size: 18, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                _group('机器体检 · 只读'),
                _ro('Provider', 'openai'),
                _ro('默认模型', 'myprovider/my-model'),
                _ro('Base URL', 'https://api.example.com/v1'),
                _ro('API Key', 'sk-••••••••1234'),
                _ro('思考强度', '随模型 support_efforts（全局 [thinking].effort）'),
                const SizedBox(height: 10),
                _mcpRow('filesystem', true),
                _mcpRow('github', true),
                const SizedBox(height: 10),
                _ro('Skills', '12 个已加载'),
                _ro('全局许可', 'manual'),
                const SizedBox(height: 10),
                const Text('关键命令清单', style: AppText.caption),
                const SizedBox(height: 6),
                const Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Tag('rm -rf'),
                    _Tag('sudo'),
                    _Tag('git push -f'),
                    _Tag('deploy'),
                    _Tag('.env / 凭证'),
                  ],
                ),
                const SizedBox(height: 22),
                _group('连接'),
                _ro('中继地址', '100.x.x.x:7331'),
                const _StatusRow(label: '连接状态', ok: true),
                const SizedBox(height: 22),
                _group('锁屏门铃'),
                _tg('Bark 推送', _barkOn, (v) => setState(() => _barkOn = v)),
                _ro('Bark URL', 'https://api.day.app/••••'),
                const SizedBox(height: 22),
                _group('许可策略'),
                _tg('非关键超时自动放行', _autoPass,
                    (v) => setState(() => _autoPass = v)),
                _ro('超时时长', '5 分钟'),
                const SizedBox(height: 22),
                _group('外观'),
                _ro('主题', '浅色（v1）'),
                const SizedBox(height: 22),
                _group('关于'),
                _ro('版本', 'v0.1.0'),
                _ro('实测基线', 'Kimi Code CLI 0.31.0'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _group(String t) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10),
        child: Text(t, style: AppText.monoCaption),
      );

  Widget _ro(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Text(k, style: AppText.callout),
            const Spacer(),
            Flexible(
              child: Text(v,
                  style: AppText.caption,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );

  Widget _mcpRow(String name, bool ok) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: ok ? AppColors.approve : AppColors.reject,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(name, style: AppText.mono),
            const Spacer(),
            Text(ok ? 'connected' : 'error',
                style: AppText.monoCaption
                    .copyWith(color: ok ? AppColors.approve : AppColors.reject)),
          ],
        ),
      );

  Widget _tg(String k, bool v, ValueChanged<bool> onChanged) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(k, style: AppText.callout)),
            Switch(
              value: v,
              activeColor: AppColors.accent,
              onChanged: onChanged,
            ),
          ],
        ),
      );
}

class _StatusRow extends StatelessWidget {
  final String label;
  final bool ok;
  const _StatusRow({required this.label, required this.ok});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Text(label, style: AppText.callout),
          const Spacer(),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: ok ? AppColors.approve : AppColors.reject,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(ok ? '在线' : '离线',
              style: AppText.caption
                  .copyWith(color: ok ? AppColors.approve : AppColors.reject)),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String t;
  const _Tag(this.t);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.rejectSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(t,
          style: AppText.monoCaption.copyWith(color: AppColors.reject)),
    );
  }
}