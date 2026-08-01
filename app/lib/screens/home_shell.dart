import 'package:flutter/material.dart';
import '../relay/models.dart';
import '../relay/relay_client.dart';
import '../relay/session_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/stream_block.dart';
import 'design_showcase.dart';

// ---------- 常量 ----------

const _kDefaultRelayUrl = 'ws://127.0.0.1:7331/ws';

// chip = 你的自由文本常用语（点选即发）；slash = Kimi 命令（来自 available_commands）。
const _chips = ['跑下测试', 'commit 一下', '解释刚干了啥'];

// 思考强度：会话级 ACP 切法待探针确认，此刀占位（受控本地态，不下发）。
const _effortOpts = [
  DropdownOption(id: 'low', label: '低'),
  DropdownOption(id: 'medium', label: '中'),
  DropdownOption(id: 'high', label: '高'),
];
const _effortLabel = {'low': '低', 'medium': '中', 'high': '高'};

const _modeIcon = {
  'default': AppIcons.modeManual,
  'plan': AppIcons.modePlan,
  'auto': AppIcons.modeAuto,
  'yolo': AppIcons.modeYolo,
};
const _modeFallbackDesc = {
  'default': '危险动作逐一问你',
  'plan': '只规划，不执行工具',
  'auto': 'agent 自主决策',
  'yolo': '自动批准，但可能问你',
};

// ---------- configOptions 解析（展示层，纯函数）----------

String _provOf(String v) {
  final i = v.indexOf('/');
  return i < 0 ? v : v.substring(0, i);
}

List<Map<String, dynamic>> _cfgList(dynamic cfg, String id) {
  if (cfg is! List) return const [];
  for (final c in cfg) {
    if (c is Map && c['id'] == id) {
      final o = c['options'];
      if (o is List) {
        return o
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      }
    }
  }
  return const [];
}

String _cfgCur(dynamic cfg, String id) {
  if (cfg is! List) return '';
  for (final c in cfg) {
    if (c is Map && c['id'] == id) return c['currentValue']?.toString() ?? '';
  }
  return '';
}

// ---------- 主页 ----------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _client = RelayClient();
  final _store = SessionStore();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  String _relayUrl = _kDefaultRelayUrl;
  String _effortId = 'medium'; // 占位
  String? _slashQuery;

  bool get _online => _client.connected;

  @override
  void initState() {
    super.initState();
    _client.onMessage = _store.handle;
    _client.onOpen = () => setState(() {});
    _client.onClose = () => setState(() {});
    _store.addListener(_onStore);
    _connect(_relayUrl);
  }

  void _onStore() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _connect(String url) async {
    _relayUrl = url;
    try {
      await _client.connect(url);
    } catch (_) {
      setState(() {});
    }
  }

  // ---- 顶栏选择回调：下发 + 乐观更新 ----

  void _onProvider(String prov) {
    final sid = _store.currentSid;
    final cfg = _store.configOf(sid);
    final models = _cfgList(cfg, 'model')
        .where((o) => _provOf(o['value']?.toString() ?? '') == prov)
        .toList();
    if (models.isEmpty || sid == null) return;
    final target = models.first['value']?.toString() ?? '';
    _client.send('set_model', sid: sid, payload: {'value': target});
    _store.applyConfigOption(sid, 'model', target);
  }

  void _onModel(String value) {
    final sid = _store.currentSid;
    if (sid == null) return;
    _client.send('set_model', sid: sid, payload: {'value': value});
    _store.applyConfigOption(sid, 'model', value);
  }

  void _onMode(String m) {
    final sid = _store.currentSid;
    if (sid == null) return;
    _client.send('set_mode', sid: sid, payload: {'modeId': m});
    _store.applyConfigOption(sid, 'mode', m);
  }

  void _onEffort(String e) => setState(() => _effortId = e); // 占位，不下发

  // ---- 输入 / slash / 附件 ----

  void _send(String text) {
    final t = text.trim();
    final sid = _store.currentSid;
    if (t.isEmpty || sid == null || !_online) return;
    _store.addUser(sid, t);
    _client.send('prompt', sid: sid, payload: {'text': t});
    _inputCtrl.clear();
    setState(() => _slashQuery = null);
  }

  void _onInputChanged(String v) {
    final q = (v.startsWith('/') && !v.contains(' ')) ? v.substring(1) : null;
    if (q != _slashQuery) setState(() => _slashQuery = q);
  }

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

  // ---- 抽屉动作 ----

  void _openHistory(SessionMeta m) {
    _client.send('open_history',
        sid: m.sessionId, payload: {'sessionId': m.sessionId, 'cwd': m.cwd});
  }

  void _newSession() => _client.send('new_session', payload: {});

  void _decide(PermOption opt) {
    final p = _store.pendingPermission;
    if (p == null) return;
    _client.send('permission.decision',
        sid: p.sid,
        payload: {'permissionId': p.permissionId, 'optionId': opt.optionId});
    setState(() => _store.pendingPermission = null);
  }

  void _openSettings() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => _SettingsSheet(
          store: _store,
          relayUrl: _relayUrl,
          effortLabel: _effortLabel[_effortId] ?? _effortId,
          onReconnect: (url) {
            Navigator.of(context).pop();
            _client.disconnect();
            _connect(url);
          },
          onPalette: () {
            Navigator.of(context).pop();
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DesignShowcase()),
            );
          },
        ),
      );

  @override
  void dispose() {
    _client.disconnect();
    _store.removeListener(_onStore);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sid = _store.currentSid;
    final cfg = _store.configOf(sid);
    final blocks = _store.blocksOf(sid);
    final perm = _store.pendingPermission;

    final slashOpen = _slashQuery != null;
    final cmds = _store.commandsOf(sid);
    final slashOpts = _slashQuery == null
        ? const <String>[]
        : cmds
            .map((c) => '/${(c as Map)['name']}')
            .where((s) => _slashQuery!.isEmpty ||
                s.toLowerCase().contains(_slashQuery!.toLowerCase()))
            .toList();

    final dockH = perm != null ? 360.0 : (slashOpen ? 230.0 : 150.0);

    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: Drawer(
        width: 280,
        backgroundColor: AppColors.background,
        child: _SessionDrawer(
          store: _store,
          onPick: (m) {
            Navigator.of(context).pop();
            _openHistory(m);
          },
          onNew: () {
            Navigator.of(context).pop();
            _newSession();
          },
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
              cfg: cfg,
              effortId: _effortId,
              online: _online,
              relayState: _store.relayState,
              onProvider: _onProvider,
              onModel: _onModel,
              onEffort: _onEffort,
              onMode: _onMode,
              onPalette: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DesignShowcase()),
              ),
            ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  blocks.isEmpty
                      ? _EmptyState(online: _online)
                      : ListView.builder(
                          controller: _scrollCtrl,
                          padding: EdgeInsets.fromLTRB(
                              AppSpacing.pageMargin,
                              8,
                              AppSpacing.pageMargin,
                              dockH),
                          itemCount: blocks.length,
                          itemBuilder: (_, i) => Padding(
                            padding: EdgeInsets.only(
                                bottom: i == blocks.length - 1
                                    ? 0
                                    : AppSpacing.lg),
                            child: StreamBlockView(block: blocks[i]),
                          ),
                        ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _BottomDock(
                      enabled: _online && sid != null,
                      pending: perm,
                      controller: _inputCtrl,
                      onSend: _send,
                      onChanged: _onInputChanged,
                      onOpenPlus: _onAttach,
                      onChip: _send,
                      slashOpen: slashOpen && slashOpts.isNotEmpty,
                      slashOpts: slashOpts,
                      onPickSlash: _pickSlash,
                      onDecide: _decide,
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

// ---------- 顶部导航 ----------

class _TopBar extends StatelessWidget {
  final dynamic cfg;
  final String effortId;
  final bool online;
  final String relayState;
  final ValueChanged<String> onProvider;
  final ValueChanged<String> onModel;
  final ValueChanged<String> onEffort;
  final ValueChanged<String> onMode;
  final VoidCallback onPalette;

  const _TopBar({
    required this.cfg,
    required this.effortId,
    required this.online,
    required this.relayState,
    required this.onProvider,
    required this.onModel,
    required this.onEffort,
    required this.onMode,
    required this.onPalette,
  });

  @override
  Widget build(BuildContext context) {
    final modelOpts = _cfgList(cfg, 'model');
    final curModel = _cfgCur(cfg, 'model');
    final providers =
        modelOpts.map((o) => _provOf(o['value']?.toString() ?? '')).toSet().toList();
    final curProv = _provOf(curModel);
    final modelsOfProv = modelOpts
        .where((o) => _provOf(o['value']?.toString() ?? '') == curProv)
        .toList();
    final curModelLabel = modelsOfProv
            .firstWhere((o) => o['value'] == curModel,
                orElse: () => <String, dynamic>{})
            .let((m) => (m['name']?.toString() ?? curModel));

    final dot = online
        ? (relayState == 'degraded' ? AppColors.warning : AppColors.approve)
        : AppColors.placeholder;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: Row(
        children: [
          _iconBtn(AppIcons.menu,
              onTap: () => Scaffold.of(context).openDrawer()),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: ChipDropdown(
                    triggerLabel: providers.isEmpty ? '—' : curProv,
                    options: providers
                        .map((p) => DropdownOption(id: p, label: p))
                        .toList(),
                    selectedId: curProv,
                    onSelect: onProvider,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: ChipDropdown(
                    triggerLabel:
                        modelsOfProv.isEmpty ? '—' : (curModelLabel.isEmpty ? '—' : curModelLabel),
                    options: modelsOfProv
                        .map((o) => DropdownOption(
                            id: o['value']?.toString() ?? '',
                            label: o['name']?.toString() ?? ''))
                        .toList(),
                    selectedId: curModel,
                    onSelect: onModel,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: ChipDropdown(
                    triggerLabel: _effortLabel[effortId] ?? effortId,
                    options: _effortOpts,
                    selectedId: effortId,
                    onSelect: onEffort,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          _ModeIconMenu(cfg: cfg, onMode: onMode),
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

/// 给 Map 加一个 let，方便链式取 name 兜底。
extension _MapLet<K, V> on Map<K, V> {
  R let<R>(R Function(Map<K, V>) f) => f(this);
}

// ---------- mode 图标菜单（真实 mode options）----------

class _ModeIconMenu extends StatefulWidget {
  final dynamic cfg;
  final ValueChanged<String> onMode;
  const _ModeIconMenu({required this.cfg, required this.onMode});

  @override
  State<_ModeIconMenu> createState() => _ModeIconMenuState();
}

class _ModeIconMenuState extends State<_ModeIconMenu> {
  OverlayEntry? _entry;
  bool _down = false;
  bool get _open => _entry != null;

  void _toggle() => _open ? _close() : _openMenu();

  List<Map<String, dynamic>> get _modes {
    final real = _cfgList(widget.cfg, 'mode');
    if (real.isNotEmpty) return real;
    return _modeIcon.keys
        .map((k) => <String, dynamic>{
              'value': k,
              'name': k,
              'description': _modeFallbackDesc[k],
            })
        .toList();
  }

  void _openMenu() {
    final box = context.findRenderObject() as RenderBox;
    final off = box.localToGlobal(Offset.zero);
    final cur = _cfgCur(widget.cfg, 'mode');
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
                children: _modes
                    .map((m) => _MenuRow(
                          icon: _modeIcon[m['value']] ?? AppIcons.modeManual,
                          label: m['name']?.toString() ?? m['value']?.toString() ?? '',
                          subtitle: m['description']?.toString() ??
                              _modeFallbackDesc[m['value']],
                          selected: m['value'] == cur,
                          onTap: () {
                            widget.onMode(m['value']?.toString() ?? '');
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
    final cur = _cfgCur(widget.cfg, 'mode');
    final icon = _modeIcon[cur] ?? AppIcons.modeManual;
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

// ---------- 会话抽屉：真实 session.list + 搜索 + 工作区分组 ----------

class _SessionDrawer extends StatefulWidget {
  final SessionStore store;
  final ValueChanged<SessionMeta> onPick;
  final VoidCallback onNew;
  final VoidCallback onOpenSettings;
  const _SessionDrawer({
    super.key,
    required this.store,
    required this.onPick,
    required this.onNew,
    required this.onOpenSettings,
  });

  @override
  State<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<_SessionDrawer> {
  String _q = '';

  String _groupKey(SessionMeta m) {
    final parts = m.cwd.split('/').where((p) => p.isNotEmpty).toList();
    return parts.length >= 2
        ? '${parts[parts.length - 2]}/${parts.last}'
        : (parts.isNotEmpty ? parts.last : '—');
  }

  bool _match(SessionMeta m) =>
      _q.isEmpty || m.title.toLowerCase().contains(_q.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final all = widget.store.history.where(_match).toList();
    final groups = <String, List<SessionMeta>>{};
    for (final m in all) {
      groups.putIfAbsent(_groupKey(m), () => []).add(m);
    }
    final cur = widget.store.currentSid;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Pressable(
              onTap: widget.onNew,
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
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: Text('无匹配会话', style: AppText.caption),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    children: [
                      for (final entry in groups.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                          child: Row(
                            children: [
                              const Icon(AppIcons.folder,
                                  size: 15, color: AppColors.textSecondary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(entry.key,
                                    style: AppText.callout.copyWith(
                                        fontWeight: FontWeight.w600),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
                        ),
                        for (final m in entry.value) _row(m, m.sessionId == cur),
                      ],
                    ],
                  ),
          ),
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

  Widget _row(SessionMeta m, bool sel) {
    return Pressable(
      onTap: () => widget.onPick(m),
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
                    m.title.isEmpty ? '（无标题）' : m.title,
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

// ---------- 空状态：点阵装饰（规范 7.1）----------

class _EmptyState extends StatelessWidget {
  final bool online;
  const _EmptyState({required this.online});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _DotMatrix(),
          const SizedBox(height: AppSpacing.xl),
          Text(
            online ? '尽管问，Kimi 在听' : '连接中继后开始',
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

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

// ---------- 底部 dock ----------

class _BottomDock extends StatelessWidget {
  final bool enabled;
  final PermissionRequest? pending;
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onOpenPlus;
  final ValueChanged<String> onChip;
  final bool slashOpen;
  final List<String> slashOpts;
  final ValueChanged<String> onPickSlash;
  final ValueChanged<PermOption> onDecide;

  const _BottomDock({
    required this.enabled,
    required this.pending,
    required this.controller,
    required this.onSend,
    required this.onChanged,
    required this.onOpenPlus,
    required this.onChip,
    required this.slashOpen,
    required this.slashOpts,
    required this.onPickSlash,
    required this.onDecide,
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
              if (pending != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.pageMargin),
                  child: _PermSheet(perm: pending!, onDecide: onDecide),
                ),
                const SizedBox(height: 8),
              ],
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
                  enabled: enabled,
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
  final bool enabled;
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onOpenPlus;
  const _InputBar({
    required this.enabled,
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
              enabled: enabled,
              style: AppText.body,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onChanged: onChanged,
              onSubmitted: onSend,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: enabled ? '尽管问…' : '先连接中继',
                hintStyle: AppText.placeholder,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Pressable(
            onTap: enabled ? () => onSend(controller.text) : () {},
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: enabled ? AppColors.textPrimary : AppColors.keyCap,
                shape: BoxShape.circle,
              ),
              child: Icon(AppIcons.send,
                  size: 16,
                  color: enabled ? AppColors.surface : AppColors.placeholder),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 批准浮层（真实 permission）----------

class _PermSheet extends StatelessWidget {
  final PermissionRequest perm;
  final ValueChanged<PermOption> onDecide;
  const _PermSheet({required this.perm, required this.onDecide});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.card,
        border: Border.all(color: AppColors.warning, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(AppIcons.terminal, size: 16, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(child: Text(perm.title, style: AppText.title2)),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.warningSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text('待批准',
                      style: AppText.monoCaption
                          .copyWith(color: AppColors.warning)),
                ),
              ],
            ),
            if (perm.command.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(AppRadius.thumbnail),
                ),
                child: Text(perm.command, style: AppText.mono),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                for (final opt in perm.options) ...[
                  Expanded(child: _permBtn(opt)),
                  if (opt != perm.options.last)
                    const SizedBox(width: AppSpacing.sm),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _permBtn(PermOption opt) {
    final (bg, fg, label) = switch (opt.kind) {
      'allow_once' => (AppColors.approve, AppColors.surface, '批准'),
      'allow_always' => (AppColors.keyCap, AppColors.textPrimary, '本会话'),
      'reject_once' => (AppColors.rejectSoft, AppColors.reject, '拒绝'),
      _ => (AppColors.keyCap, AppColors.textPrimary, opt.name ?? opt.optionId),
    };
    return Pressable(
      onTap: () => onDecide(opt),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: AppText.callout.copyWith(color: fg, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ---------- 设置（机器体检真实值 + 中继地址可重连）----------

class _SettingsSheet extends StatefulWidget {
  final SessionStore store;
  final String relayUrl;
  final String effortLabel;
  final ValueChanged<String> onReconnect;
  final VoidCallback onPalette;
  const _SettingsSheet({
    super.key,
    required this.store,
    required this.relayUrl,
    required this.effortLabel,
    required this.onReconnect,
    required this.onPalette,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _urlCtrl =
      TextEditingController(text: widget.relayUrl);
  bool _barkOn = true;
  bool _autoPass = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final cfg = widget.store.configOf(widget.store.currentSid);
    final prov = _provOf(_cfgCur(cfg, 'model'));
    final modelOpts = _cfgList(cfg, 'model');
    final curModel = _cfgCur(cfg, 'model');
    final modelLabel = modelOpts
            .firstWhere((o) => o['value'] == curModel,
                orElse: () => <String, dynamic>{})
            .let((m) => m['name']?.toString() ?? curModel);
    final mode = _cfgCur(cfg, 'mode');

    return SizedBox(
      height: h * 0.86,
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
                  onTap: widget.onPalette,
                  child: const SizedBox(
                    width: 32,
                    height: 32,
                    child: Icon(AppIcons.palette,
                        size: 18, color: AppColors.textSecondary),
                  ),
                ),
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
                _ro('Provider', prov.isEmpty ? '—' : prov),
                _ro('当前模型', modelLabel.isEmpty ? '—' : modelLabel),
                _ro('当前模式', mode.isEmpty ? '—' : mode),
                _ro('思考强度', '${widget.effortLabel}（会话级待接通）'),
                const SizedBox(height: 22),
                _group('连接'),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(AppRadius.thumbnail),
                  ),
                  child: TextField(
                    controller: _urlCtrl,
                    style: AppText.monoCaption,
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Pressable(
                    onTap: () => widget.onReconnect(_urlCtrl.text.trim()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 9),
                      decoration: BoxDecoration(
                        color: AppColors.textPrimary,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text('保存并重连',
                          style: AppText.callout.copyWith(
                              color: AppColors.surface,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _StatusRow(
                    label: '连接状态',
                    ok: widget.store.relayState == 'ok' ||
                        widget.store.relayState == 'connecting'),
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