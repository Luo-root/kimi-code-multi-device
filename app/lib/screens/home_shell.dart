import 'dart:async';
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
  final _dockKey = GlobalKey();

  /// 用户是否在列表底部附近：非底部时新消息不应把视口拽回（§UX 防滚动劫持）。
  bool _atBottom = true;
  /// 底部 dock 真实高度（动态测量，替代写死的 360/230/150）。
  double _dockH = 150;

  String _relayUrl = _kDefaultRelayUrl;
  String _effortId = 'medium'; // 占位
  String? _slashQuery;

  @override
  void initState() {
    super.initState();
    _client.onMessage = _store.handle;
    _client.onOpen = () => _store.markConnected();
    _client.onClose = () => _store.markDisconnected(reconnecting: true);
    _client.onReconnecting = () => _store.markDisconnected(reconnecting: true);
    _store.addListener(_onStore);
    _scrollCtrl.addListener(_onScroll);
    _connect(_relayUrl);
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 60;
    if (atBottom != _atBottom) _atBottom = atBottom;
  }

  /// 测量 dock 真实高度，变化时刷新列表底部留白，避免消息被 dock 遮挡。
  void _measureDock() {
    final ctx = _dockKey.currentContext;
    if (ctx == null) return;
    final h = ctx.size?.height;
    if (h != null && (h - _dockH).abs() > 0.5) {
      setState(() => _dockH = h);
    }
  }

  void _onStore() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureDock();
      // 仅当用户停在底部（或刚发消息，见 _send 置 _atBottom=true）才自动跟随，
      // 否则保留用户当前滚动位置，长对话翻看不被拽回。
      if (_atBottom && _scrollCtrl.hasClients) {
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
    // RelayClient 自带退避重连，此处只发起首次连接；失败由 onReconnecting 接管。
    await _client.connect(url);
  }

  void _cancelCurrent() {
    final sid = _store.currentSid;
    if (sid == null) return;
    _client.send('cancel', sid: sid);
  }

  // ---- 顶栏选择回调：下发 + 乐观更新 ----

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
    if (t.isEmpty || sid == null || _store.relayState != 'ok') return;
    // 运行中（AI 还在输出）忽略发送：发送键已隐藏为「停」，Enter 也不应漏发。
    if (_store.busyOf(sid)) return;
    _store.addUser(sid, t);
    _client.send('prompt', sid: sid, payload: {'text': t});
    _inputCtrl.clear();
    setState(() => _slashQuery = null);
    // 自己发的消息：强制滚到底，确保看到最新。
    _atBottom = true;
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

  /// 关闭一个顶部活跃会话：发 close_session 给中继（尽力关闭 Kimi 会话 + 广播
  /// session.closed），并乐观移除本地 tab。
  void _closeSession(String sid) {
    _client.send('close_session', sid: sid, payload: {'sessionId': sid});
    _store.removeActive(sid);
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

  /// 侧边栏点会话 = 切换，不是给主屏加一个可切换会话。
  /// active 会话直接切 C 位；历史会话先发 open_history（恢复+回放）再切。
  void _openSession(SessionMeta m) {
    final sid = m.sessionId;
    if (!_store.activeSids.contains(sid)) {
      _client.send('open_history',
          sid: sid, payload: {'sessionId': sid, 'cwd': m.cwd});
    }
    _store.setCurrent(sid);
  }

  void _newSession() => _client.send('new_session', payload: {});

  void _decide(PermOption opt) {
    final p = _store.pendingOf(_store.currentSid);
    if (p == null) return;
    _client.send('permission.decision',
        sid: p.sid,
        payload: {'permissionId': p.permissionId, 'optionId': opt.optionId});
    _store.resolvePermission(p);
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
        ),
      );

  /// 待批准队列：全屏列出所有会话的待批准卡，按 sid 分组。
  void _openQueue() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PendingQueuePage(
          store: _store,
          client: _client,
          onPickSession: (sid) {
            _store.setCurrent(sid);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _client.disconnect();
    _store.removeListener(_onStore);
    _inputCtrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sid = _store.currentSid;
    final cfg = _store.configOf(sid);
    final blocks = _store.blocksOf(sid);
    final perm = _store.pendingOf(sid);

    final slashOpen = _slashQuery != null;
    final cmds = _store.commandsOf(sid);
    final slashOpts = _slashQuery == null
        ? const <String>[]
        : cmds
            .map((c) => '/${(c as Map)['name']}')
            .where((s) => _slashQuery!.isEmpty ||
                s.toLowerCase().contains(_slashQuery!.toLowerCase()))
            .toList();

    final dockH = _dockH; // 动态测量，替代写死的 360/230/150
    // §13「停」随 AI 输出态：busy（session/prompt 进行中）时显眼，输出完退场。
    final running = sid != null && _store.busyOf(sid);

    return Scaffold(
      backgroundColor: AppColors.background,
      drawer: Drawer(
        width: 280,
        backgroundColor: AppColors.background,
        child: _SessionDrawer(
          store: _store,
          onPick: (m) {
            Navigator.of(context).pop();
            _openSession(m);
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
              relayState: _store.relayState,
              onModel: _onModel,
              onEffort: _onEffort,
              onMode: _onMode,
            ),
            _SessionSwitcher(
              store: _store,
              onOpenQueue: _openQueue,
              onClose: _closeSession,
            ),
            _ConnBanner(
              state: _store.relayState,
              lastSyncedAt: _store.lastSyncedAt,
              onRetry: () => _client.send('restart_kimi'),
            ),
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  blocks.isEmpty
                      ? _EmptyState(online: _store.relayState == 'ok')
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
                    child: Container(
                      key: _dockKey,
                      child: _BottomDock(
                        enabled: _store.relayState == 'ok' && sid != null,
                        running: running,
                        pending: perm,
                        controller: _inputCtrl,
                        onSend: _send,
                        onStop: _cancelCurrent,
                        onChanged: _onInputChanged,
                        onOpenPlus: _onAttach,
                        onChip: _send,
                        slashOpen: slashOpen && slashOpts.isNotEmpty,
                        slashOpts: slashOpts,
                        onPickSlash: _pickSlash,
                        onDecide: _decide,
                      ),
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
  final String relayState;
  final ValueChanged<String> onModel;
  final ValueChanged<String> onEffort;
  final ValueChanged<String> onMode;

  const _TopBar({
    required this.cfg,
    required this.effortId,
    required this.relayState,
    required this.onModel,
    required this.onEffort,
    required this.onMode,
  });

  @override
  Widget build(BuildContext context) {
    final dot = switch (relayState) {
      'ok' => AppColors.approve,
      'degraded' => AppColors.warning,
      _ => AppColors.placeholder,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: Row(
        children: [
          _iconBtn(AppIcons.menu,
              onTap: () => Scaffold.of(context).openDrawer()),
          const SizedBox(width: 6),
          // provider·model·思考深度 → 一个级联主菜单（§09 级联结构）。
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _CascadeConfigMenu(
                cfg: cfg,
                effortId: effortId,
                effortOpts: _effortOpts,
                effortLabel: _effortLabel,
                onModel: onModel,
                onEffort: onEffort,
              ),
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
  double _menuMaxH = 320;
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
    // 防溢出：下方不足且上方更宽时翻到上方弹出；maxH 取可用高度。
    final vh = MediaQuery.of(context).size.height;
    final topY = off.dy + box.size.height + 6;
    final availBelow = vh - topY;
    final availAbove = off.dy - 6;
    final above = availBelow < 320 && availAbove > availBelow;
    _menuMaxH = (above ? availAbove : availBelow).clamp(160.0, 360.0);
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
            top: above ? null : topY,
            bottom: above ? (vh - off.dy + 6) : null,
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
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: _menuMaxH),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _modes
                        .map((m) => _MenuRow(
                              icon: _modeIcon[m['value']] ?? AppIcons.modeManual,
                              label: m['name']?.toString() ??
                                  m['value']?.toString() ??
                                  '',
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
  final bool selected;
  final VoidCallback onTap;
  const _MenuRow({
    required this.label,
    this.icon,
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
              child: Text(widget.label,
                  style: AppText.callout.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  )),
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

// ---------- 级联配置菜单：provider → model → 思考深度（§09 级联结构）----------

/// 一个主触发器，下钻三级子菜单。选中 model 即下发 set_model（乐观更新），
/// 思考深度为占位（会话级 ACP 切法待确认，不下发）。触发器用短标签，菜单看全称。
class _CascadeConfigMenu extends StatefulWidget {
  final dynamic cfg;
  final String effortId;
  final List<DropdownOption> effortOpts;
  final Map<String, String> effortLabel;
  final ValueChanged<String> onModel;
  final ValueChanged<String> onEffort;

  const _CascadeConfigMenu({
    required this.cfg,
    required this.effortId,
    required this.effortOpts,
    required this.effortLabel,
    required this.onModel,
    required this.onEffort,
  });

  @override
  State<_CascadeConfigMenu> createState() => _CascadeConfigMenuState();
}

class _CascadeConfigMenuState extends State<_CascadeConfigMenu> {
  OverlayEntry? _entry;
  bool _down = false;
  double _menuMaxH = 300;
  bool get _open => _entry != null;

  List<Map<String, dynamic>> get _models => _cfgList(widget.cfg, 'model');
  String get _curModel => _cfgCur(widget.cfg, 'model');

  List<String> get _providers {
    final seen = <String>[];
    for (final o in _models) {
      final p = _provOf(o['value']?.toString() ?? '');
      if (!seen.contains(p)) seen.add(p);
    }
    return seen;
  }

  List<Map<String, dynamic>> _modelsOf(String prov) => _models
      .where((o) => _provOf(o['value']?.toString() ?? '') == prov)
      .toList();

  String get _curModelLabel {
    final cur = _curModel;
    for (final o in _models) {
      if (o['value'] == cur) return o['name']?.toString() ?? cur;
    }
    return cur.isEmpty ? '选择模型' : cur;
  }

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    final cur = _curModel;
    var level = 0;
    var selProv = _provOf(cur);
    var selModel = cur;
    final box = context.findRenderObject() as RenderBox;
    final off = box.localToGlobal(Offset.zero);

    // 防溢出：下方空间不足且上方更宽时，菜单翻到触发点上方弹出；maxH 取可用高度。
    final vh = MediaQuery.of(context).size.height;
    final screenW = MediaQuery.of(context).size.width;
    final topY = off.dy + box.size.height + 6;
    final availBelow = vh - topY;
    final availAbove = off.dy - 6;
    final above = availBelow < 340 && availAbove > availBelow;
    _menuMaxH = (above ? availAbove : availBelow).clamp(160.0, 360.0);
    const width = 250.0;
    final left = (AppSpacing.pageMargin + width > screenW - 8)
        ? screenW - 8 - width
        : AppSpacing.pageMargin;

    _entry = OverlayEntry(builder: (ctx) {
      return StatefulBuilder(builder: (ctx2, setOverlay) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const SizedBox.shrink(),
              ),
            ),
            Positioned(
              top: above ? null : topY,
              bottom: above ? (vh - off.dy + 6) : null,
              left: left,
              width: width,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  boxShadow: AppShadows.popup,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(level, selProv, selModel, setOverlay, () {
                      setOverlay(() {
                        if (level > 0) level--;
                      });
                    }),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: _menuMaxH),
                      child: SingleChildScrollView(
                        child: _levelList(level, selProv, (prov) {
                          setOverlay(() {
                            selProv = prov;
                            level = 1;
                          });
                        }, (modelVal) {
                          widget.onModel(modelVal);
                          _close();
                        }, (effId) {
                          widget.onEffort(effId);
                          _close();
                        }, setOverlay),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      });
    });
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

  Widget _header(int level, String selProv, String selModel,
      StateSetter setOverlay, VoidCallback onBack) {
    final titles = ['Provider', selProv, _effortName(selModel)];
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Row(
        children: [
          if (level > 0)
            Pressable(
              onTap: onBack,
              child: const SizedBox(
                width: 28,
                height: 28,
                child: Icon(AppIcons.arrowLeft,
                    size: 15, color: AppColors.textSecondary),
              ),
            )
          else
            const SizedBox(width: 28, height: 28),
          Expanded(
            child: Text(
              titles[level],
              textAlign: TextAlign.center,
              style: AppText.callout.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 28, height: 28),
        ],
      ),
    );
  }

  String _effortName(String modelVal) {
    for (final o in _models) {
      if (o['value'] == modelVal) return o['name']?.toString() ?? modelVal;
    }
    return modelVal;
  }

  Widget _levelList(
    int level,
    String selProv,
    ValueChanged<String> onPickProv,
    ValueChanged<String> onPickModel,
    ValueChanged<String> onPickEffort,
    StateSetter setOverlay,
  ) {
    if (level == 0) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final p in _providers)
            _row(p,
                trailing: AppIcons.chevronRight,
                selected: p == _provOf(_curModel),
                onTap: () => onPickProv(p)),
        ],
      );
    }
    if (level == 1) {
      final models = _modelsOf(selProv);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in models)
            _row(o['name']?.toString() ?? o['value']?.toString() ?? '',
                trailing: AppIcons.chevronRight,
                selected: o['value'] == _curModel,
                onTap: () => onPickModel(o['value']?.toString() ?? '')),
          // 显式「思考深度」入口：选模型不再强制下钻（深度占位暂不下发），
          // 想调深度再单独点进来（§9 级联，去摩擦）。
          _row('思考深度',
              trailing: AppIcons.chevronRight,
              onTap: () => setOverlay(() {
                    level = 2;
                  })),
        ],
      );
    }
    // level 2：思考深度
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in widget.effortOpts)
          _row(widget.effortLabel[e.id] ?? e.label,
              selected: e.id == widget.effortId,
              onTap: () => onPickEffort(e.id)),
      ],
    );
  }

  Widget _row(String label,
      {IconData? trailing, bool selected = false, required VoidCallback onTap}) {
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: AppText.callout.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (selected)
              const Icon(AppIcons.check, size: 15, color: AppColors.accent)
            else if (trailing != null)
              Icon(trailing, size: 14, color: AppColors.placeholder),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: _toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: _down ? const Color(0xFFDADAE0) : AppColors.keyCap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.modelChip,
                size: 13, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _curModelLabel,
                style: AppText.callout.copyWith(color: AppColors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(_open ? AppIcons.chevronUp : AppIcons.chevronDown,
                size: 12, color: AppColors.textSecondary),
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
  final bool running;
  final PermissionRequest? pending;
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final ValueChanged<String> onChanged;
  final VoidCallback onOpenPlus;
  final ValueChanged<String> onChip;
  final bool slashOpen;
  final List<String> slashOpts;
  final ValueChanged<String> onPickSlash;
  final ValueChanged<PermOption> onDecide;

  const _BottomDock({
    required this.enabled,
    required this.running,
    required this.pending,
    required this.controller,
    required this.onSend,
    required this.onStop,
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
                  running: running,
                  controller: controller,
                  onSend: onSend,
                  onStop: onStop,
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
  final bool running;
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final ValueChanged<String> onChanged;
  final VoidCallback onOpenPlus;
  const _InputBar({
    required this.enabled,
    required this.running,
    required this.controller,
    required this.onSend,
    required this.onStop,
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
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Pressable(
            onTap: onOpenPlus,
            child: Container(
              width: 32,
              height: 32,
              margin: const EdgeInsets.only(bottom: 4),
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
              // 多行：写代码/长指令不被压成一行；Enter 发送，Shift+Enter 换行。
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.send,
              // 代码 agent：关闭自动纠错/自动大写，避免被改词。
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
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
          // §13「停」可见性随状态：流式中亮且显眼（占发送位），空闲时是发送。
          running
              ? Pressable(
                  onTap: onStop,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: AppColors.reject,
                      shape: BoxShape.circle,
                    ),
                    child:
                        const Icon(AppIcons.stop, size: 14, color: AppColors.surface),
                  ),
                )
              : Pressable(
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
                        color:
                            enabled ? AppColors.surface : AppColors.placeholder),
                  ),
                ),
        ],
      ),
    );
  }
}

// ---------- 批准浮层（真实 permission）----------

/// 批准卡超时兜底（中继未给 deadline 时用）。与中继默认阈值对齐。
const _kDefaultPermTimeout = Duration(minutes: 5);

class _PermSheet extends StatefulWidget {
  final PermissionRequest perm;
  final ValueChanged<PermOption> onDecide;
  const _PermSheet({required this.perm, required this.onDecide});

  @override
  State<_PermSheet> createState() => _PermSheetState();
}

class _PermSheetState extends State<_PermSheet> {
  bool _expanded = false;
  late final DateTime _deadline;
  Timer? _t;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _deadline = widget.perm.deadline ??
        DateTime.now().add(_kDefaultPermTimeout);
    _tick();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _tick();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _tick() {
    _remaining = _deadline.difference(DateTime.now());
    if (_remaining.isNegative) _remaining = Duration.zero;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.perm;
    final critical = isCriticalCommand(p.command);
    final barColor = critical ? AppColors.reject : AppColors.textSecondary;

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
            // §UI规范五：左侧 3px 语义色条（关键=红，普通=中性）。
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: barColor,
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
                    Row(
                      children: [
                        Icon(AppIcons.terminal, size: 16, color: barColor),
                        const SizedBox(width: 8),
                        Expanded(child: Text(p.title, style: AppText.title2)),
                        _countdownChip(critical),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.warningSoft,
                            borderRadius:
                                BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text('待批准',
                              style: AppText.monoCaption
                                  .copyWith(color: AppColors.warning)),
                        ),
                      ],
                    ),
                    if (p.command.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      _commandBox(p.command),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        for (final opt in p.options) ...[
                          Expanded(child: _permBtn(opt)),
                          if (opt != p.options.last)
                            const SizedBox(width: AppSpacing.sm),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// §10 3.1 命令原文：单行截断，全文靠展开。§3.3 展开是一次免费窥探，不触发 outcome。
  Widget _commandBox(String cmd) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.thumbnail),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                cmd,
                style: AppText.mono,
                maxLines: _expanded ? null : 1,
                overflow: _expanded ? null : TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
              size: 14,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _countdownChip(bool critical) {
    final m = _remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final out = _remaining == Duration.zero;
    final color = out
        ? AppColors.reject
        : (critical || _remaining.inSeconds < 60
            ? AppColors.reject
            : AppColors.textSecondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(out ? '已超时' : '$m:$s',
          style: AppText.monoCaption.copyWith(color: color)),
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
      onTap: () => widget.onDecide(opt),
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
  const _SettingsSheet({
    super.key,
    required this.store,
    required this.relayUrl,
    required this.effortLabel,
    required this.onReconnect,
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
          // 拖拽把手：stretch 列里须居中，否则会被拉成全宽横杠。
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: AppColors.keyCap,
                borderRadius: BorderRadius.circular(2),
              ),
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
              activeThumbColor: AppColors.accent,
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

// ---------- 连接诚实横幅（§12：不诚实即一票否决）----------

class _ConnBanner extends StatelessWidget {
  final String state; // ok / degraded / offline / connecting
  final DateTime? lastSyncedAt;
  final VoidCallback onRetry;
  const _ConnBanner({
    required this.state,
    required this.lastSyncedAt,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (state == 'ok') return const SizedBox.shrink();

    final never = lastSyncedAt == null;
    final (color, icon, text) = switch (state) {
      'connecting' => never
          ? (AppColors.textSecondary, AppIcons.history, '连接中…')
          : (AppColors.warning, AppIcons.history, '重连中…'),
      'degraded' =>
          (AppColors.warning, AppIcons.modeManual, 'Kimi 未响应 · 可重试拉起'),
      'offline' => never
          ? (AppColors.textSecondary, AppIcons.history, '连接中…')
          : (AppColors.placeholder, AppIcons.close, '已断开 · 最后同步于 ${_hm(lastSyncedAt)}'),
      _ => (AppColors.textSecondary, AppIcons.history, ''),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.pageMargin, 0, AppSpacing.pageMargin, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.thumbnail),
        boxShadow: AppShadows.input,
      ),
      child: Row(
        children: [
          if (state == 'connecting' || (state == 'offline' && never))
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: color),
            )
          else
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: AppText.caption.copyWith(color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          if (state == 'degraded')
            Pressable(
              onTap: onRetry,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.warning,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text('重试',
                    style: AppText.callout.copyWith(
                        color: AppColors.surface,
                        fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
    );
  }

  String _hm(DateTime? t) {
    if (t == null) return '';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

// ---------- 多会话切换器（§11：单会话退场，多会话现身）----------

class _SessionSwitcher extends StatelessWidget {
  final SessionStore store;
  final VoidCallback onOpenQueue;
  final ValueChanged<String> onClose;
  const _SessionSwitcher({
    required this.store,
    required this.onOpenQueue,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final sids = store.activeSids;
    // 单会话退场：不暗示"该切换"。
    if (sids.length < 2) return const SizedBox.shrink();
    final cur = store.currentSid;
    final pending = store.pendingCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 34,
              // 多会话横向滚动浏览（单屏放不下时不截断）。
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                itemCount: sids.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final sid = sids[i];
                  return _SessionTab(
                    title: store.titleOf(sid),
                    status: store.sessionStatus(sid),
                    selected: sid == cur,
                    onTap: () => store.setCurrent(sid),
                    onClose: () => onClose(sid),
                  );
                },
              ),
            ),
          ),
          if (pending > 0) ...[
            const SizedBox(width: 6),
            _PendingBadge(count: pending, onTap: onOpenQueue),
          ],
        ],
      ),
    );
  }
}

class _SessionTab extends StatelessWidget {
  final String title;
  final String status; // pending / running / idle
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  const _SessionTab({
    required this.title,
    required this.status,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = switch (status) {
      'pending' => AppColors.warning,
      'running' => AppColors.approve,
      _ => null,
    };
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.keyCap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                title,
                style: AppText.callout.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 2),
            // 关闭按钮：移除此活跃会话 tab（§11 多会话管理）。
            Pressable(
              onTap: onClose,
              child: const SizedBox(
                width: 18,
                height: 18,
                child: Icon(AppIcons.close, size: 13, color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 待批准角标：圆底 + 数字，点开进入队列视图。
class _PendingBadge extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _PendingBadge({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.warning,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.bell, size: 14, color: AppColors.surface),
            const SizedBox(width: 6),
            Text('$count',
                style: AppText.callout.copyWith(
                    color: AppColors.surface, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

// ---------- 待批准队列全屏视图（§11：按 sid 分组）----------

class _PendingQueuePage extends StatefulWidget {
  final SessionStore store;
  final RelayClient client;
  final ValueChanged<String> onPickSession;
  const _PendingQueuePage({
    required this.store,
    required this.client,
    required this.onPickSession,
  });

  @override
  State<_PendingQueuePage> createState() => _PendingQueuePageState();
}

class _PendingQueuePageState extends State<_PendingQueuePage> {
  late VoidCallback _sub;

  @override
  void initState() {
    super.initState();
    _sub = () => setState(() {});
    widget.store.addListener(_sub);
  }

  @override
  void dispose() {
    widget.store.removeListener(_sub);
    super.dispose();
  }

  void _decide(String sid, PermissionRequest p, PermOption opt) {
    widget.client.send('permission.decision',
        sid: sid,
        payload: {'permissionId': p.permissionId, 'optionId': opt.optionId});
    widget.store.resolvePermission(p);
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.store.allPending;
    final groups = all.entries.where((e) => e.value.isNotEmpty).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
              child: Row(
                children: [
                  _iconBtn(AppIcons.arrowLeft,
                      onTap: () => Navigator.of(context).pop()),
                  const SizedBox(width: 4),
                  const Expanded(child: Text('待批准队列', style: AppText.title1)),
                  Text('${widget.store.pendingCount} 条',
                      style: AppText.caption),
                ],
              ),
            ),
            Expanded(
              child: groups.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _DotMatrix(),
                          const SizedBox(height: AppSpacing.xl),
                          Text('没有等待你的批准',
                              style: AppText.body
                                  .copyWith(color: AppColors.textSecondary)),
                        ],
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.pageMargin, 4, AppSpacing.pageMargin, 24),
                      children: [
                        for (final g in groups) ...[
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(4, 12, 4, 8),
                            child: Row(
                              children: [
                                const Icon(AppIcons.folder,
                                    size: 14, color: AppColors.textSecondary),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(widget.store.titleOf(g.key),
                                      style: AppText.callout.copyWith(
                                          fontWeight: FontWeight.w600),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ),
                                Pressable(
                                  onTap: () =>
                                      widget.onPickSession(g.key),
                                  child: Text('切到该会话',
                                      style: AppText.caption.copyWith(
                                          color: AppColors.accent)),
                                ),
                              ],
                            ),
                          ),
                          for (final p in g.value)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _PermSheet(
                                perm: p,
                                onDecide: (opt) => _decide(g.key, p, opt),
                              ),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
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