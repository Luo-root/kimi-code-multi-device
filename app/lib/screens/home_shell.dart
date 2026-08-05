import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:hux/hux.dart';
import 'package:flutter/services.dart';
import '../relay/models.dart';
import '../relay/relay_client.dart';
import '../relay/session_archive_store.dart';
import '../relay/session_store.dart';
import '../relay/session_view.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';
import '../theme/theme_mode_store.dart';
import '../widgets/common.dart';
import '../widgets/stream_block.dart';
import '../widgets/kimi_core.dart';
import 'archive_sheet.dart';

// ---------- 常量 ----------

const _kDefaultRelayUrl = 'ws://127.0.0.1:7331/ws';

// 实测基线（设置页"关于"与 AI 身份标识共用同一值）。
const _kTestedBaseline = 'Kimi Code CLI 0.31.0';

// Composer 尺寸策略：单行保持紧凑，最多扩展到 6 行；超过后由 TextField
// 自己滚动，不再继续撑高 dock。行高来自 AppText.body（15px / 1.6）。
const _kComposerMinLines = 1;
const _kComposerMaxLines = 6;
const _kComposerVerticalPadding = 8.0;

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

/// 找到当前滚动位置之前最近一条已测量的用户消息。
@visibleForTesting
int? latestUserHeadBeforeOffset(
  List<AgentGroupItem> groups,
  double offset,
  double? Function(int headIndex) offsetOf,
) {
  int? first;
  int? latest;
  for (final group in groups) {
    if (group.blocks.first.kind != BlockKind.user) continue;
    final head = group.headIndex;
    final messageOffset = offsetOf(head);
    if (messageOffset == null) continue;
    first ??= head;
    if (messageOffset <= offset + 8) latest = head;
  }
  return latest ?? first;
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
  final _archive = SessionArchiveStore();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _dockKey = GlobalKey();
  final _groupKeys = <int, GlobalKey>{};
  final _userOffsets = <int, double>{};

  /// 用户是否在列表底部附近：非底部时新消息不应把视口拽回（§UX 防滚动劫持）。
  bool _atBottom = true;
  /// 最近一次用户滚动方向：向上时跳用户消息，向下时回到底部。
  ScrollDirection _scrollDirection = ScrollDirection.reverse;
  /// §UX-4.2：不在底部时累计的新消息数（驱动 FAB 角标）。
  int _newWhileAway = 0;
  int _lastBlockCount = 0;
  String? _lastSid;
  /// 底部 dock 真实高度（动态测量，替代写死的 360/230/150）。
  double _dockH = 150;

  // 输入框会在每次换行/自动折行时改变 dock 高度；尺寸通知负责把
  // 列表底部留白和滚动导航的锚点同步到新的真实高度。
  void _scheduleDockMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureDock();
    });
  }

  String _relayUrl = _kDefaultRelayUrl;
  String _effortId = 'medium'; // 占位
  String? _slashQuery;
  /// 已 toast 过的 relay.error（去重，避免同一错误反复弹；恢复后重置）。§UX-7.2-3。
  String? _lastShownError;

  @override
  void initState() {
    super.initState();
    _client.onMessage = _store.handle;
    _client.onOpen = () => _store.markConnected();
    _client.onClose = () => _store.markDisconnected(reconnecting: true);
    _client.onReconnecting = () => _store.markDisconnected(reconnecting: true);
    _store.addListener(_onStore);
    _scrollCtrl.addListener(_onScroll);
    // 异步加载归档集合；失败不阻塞首屏。
    _archive.load();
    _connect(_relayUrl);
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 60;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        // 回到底部时清零新消息角标。
        if (atBottom && _newWhileAway != 0) _newWhileAway = 0;
      });
    }
  }

  bool _onUserScroll(UserScrollNotification notification) {
    if (notification.direction != ScrollDirection.idle &&
        notification.direction != _scrollDirection) {
      setState(() => _scrollDirection = notification.direction);
    }
    return false;
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _scrollToLatestUser(List<AgentGroupItem> groups) async {
    if (!_scrollCtrl.hasClients) return;
    final targetHead = latestUserHeadBeforeOffset(
      groups,
      _scrollCtrl.offset,
      (headIndex) => _userOffsets[headIndex],
    );
    if (targetHead == null) return;
    final ctx = _groupKeys[targetHead]?.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: 0.08,
      );
      return;
    }
    final targetOffset = _userOffsets[targetHead];
    if (targetOffset != null) {
      await _scrollCtrl.animateTo(
        targetOffset.clamp(
          _scrollCtrl.position.minScrollExtent,
          _scrollCtrl.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
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
    // §UX-4.2：不在底部时收到新 block，累计角标。
    final sid = _store.currentSid;
    // 切换会话时重置计数（不同会话的 blocks 不可比）。
    if (sid != _lastSid) {
      _lastSid = sid;
      _newWhileAway = 0;
      _lastBlockCount = 0;
    }
    final count = _store.blocksOf(sid).length;
    if (!_atBottom && count > _lastBlockCount) {
      _newWhileAway += count - _lastBlockCount;
    }
    _lastBlockCount = count;
    // §UX-7.2-3：relay.error 可见化——非阻断 toast，同错误去重；连接恢复后允许再次提醒。
    final err = _store.lastError;
    if (err != null && err != _lastShownError) {
      _lastShownError = err;
      _showRelayError(err);
    } else if (_store.relayState == 'ok' && _lastShownError != null) {
      _lastShownError = null;
    }
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
    if (sid == null || !_store.busyOf(sid)) return;
    // relay 的上行协议就是 `cancel` + sessionId；中继负责调用
    // ACP `session/cancel`。先收起 stop，随后由 session.busy 权威事件校正。
    _store.setBusy(sid, false);
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

  // ---- 渲染分组 ----

  /// 把 AgentGroupItem 路由到正确的 widget：SingleBlockGroup → StreamBlockView，
  /// AgentGroup → AgentGroupView（整体可折叠）。
  Widget _renderGroup(AgentGroupItem g, bool running, bool isTail) {
    final streaming = running && isTail;
    if (g is SingleBlockGroup) {
      return StreamBlockView(block: g.block, streaming: streaming);
    }
    if (g is AgentGroup) {
      return AgentGroupView(group: g, streaming: streaming);
    }
    return const SizedBox.shrink();
  }

  // ---- 输入 / slash / 附件 ----

  /// 判断 blocks[i] 是否为一个 AI 输出轮的起点（user 之后的首个 AI 块，或列表首块）。
  bool _atTurnStart(List<StreamBlock> blocks, int i) {
    if (blocks[i].kind == BlockKind.user) return false;
    return i == 0 || blocks[i - 1].kind == BlockKind.user;
  }

  /// 当前 AI 输出轮的起点索引（最后一个 user 块之后的首个 AI 块）；
  /// 返回可能等于 blocks.length（user 是最后一块，AI 块未出现），此时无有效起点。
  int _currentTurnStart(List<StreamBlock> blocks) {
    for (var i = blocks.length - 1; i >= 0; i--) {
      if (blocks[i].kind == BlockKind.user) return i + 1;
    }
    return 0;
  }

  void _send(String text) {
    final t = text.trim();
    final sid = _store.currentSid;
    if (t.isEmpty || sid == null || _store.relayState != 'ok') return;
    // §UX-5.1-2：busy 时不再静默吞掉发送——给出明确反馈。
    if (_store.busyOf(sid)) {
      context.showHuxSnackbar(
        message: 'Kimi 正在输出，完成后才能发送下一条',
        variant: HuxSnackbarVariant.warning,
        duration: const Duration(milliseconds: 1600),
      );
      return;
    }
    _store.addUser(sid, t);
    // prompt 已经写入 WS 后立即进入 running，避免 relay 的 busy 广播
    // 与当前帧之间出现 send 按钮仍可见、无法中断的空窗。
    _store.setBusy(sid, true);
    _client.send('prompt', sid: sid, payload: {'text': t});
    HapticFeedback.lightImpact(); // §UX-8.2-2：发送 = .light。
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
    context.showHuxSnackbar(
      message: '附件上传即将支持',
      variant: HuxSnackbarVariant.info,
      duration: const Duration(milliseconds: 1600),
    );
  }

  /// §UX-7.2-3：relay.error 可见化——非阻断 toast 展示错误摘要（hux 语义色），
  /// 点「详情」看全文（可选中复制）。
  void _showRelayError(String message) {
    context.showHuxSnackbar(
      message: message,
      variant: HuxSnackbarVariant.error,
      duration: const Duration(milliseconds: 4000),
      actions: [
        HuxSnackbarAction(
          label: '详情',
          onPressed: () => showHuxDialog<void>(
            context: context,
            title: '中继报错',
            content: SingleChildScrollView(
              child: SelectableText(message, style: AppText.mono),
            ),
            actions: [
              HuxButton(
                onPressed: () => Navigator.of(context).pop(),
                variant: HuxButtonVariant.secondary,
                child: Text('关闭', style: AppText.calloutStrong),
              ),
            ],
          ),
        ),
      ],
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

  void _openArchive() {
    // 弹窗（showHuxBottomSheet）从抽屉之上叠出，抽屉无需先关。
    showArchiveSheet(
      context,
      store: _store,
      archive: _archive,
      client: _client,
    );
  }

  void _decide(PermOption opt) {
    final p = _store.pendingOf(_store.currentSid);
    if (p == null) return;
    // §UX-8.2-2：拒绝 = .heavy，批准 = .medium，权重感不同。
    if (opt.kind == 'reject_once') {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
    _client.send('permission.decision',
        sid: p.sid,
        payload: {'permissionId': p.permissionId, 'optionId': opt.optionId});
    _store.resolvePermission(p);
  }

  /// 保存配置（config.set）：中继应用 + 写回配置文件；本地乐观更新，回执覆盖。
  void _saveConfig(Map<String, dynamic> patch) {
    _client.send('config.set', payload: patch);
    _store.applyRelayConfig(patch);
  }

  void _openSettings() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surfaceOf(context),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => _SettingsSheet(
          store: _store,
          relayUrl: _relayUrl,
          effortLabel: _effortLabel[_effortId] ?? _effortId,
          onSaveConfig: _saveConfig,
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
    // §3 生成状态动效：AI 输出全程（running）持续显示呼吸光点，直至输出结束收起。
    // 等待首 token（最后一块还是 user，AI 块未出现）时，标识作为列表尾部占位；
    // 一旦 AI 块出现，标识改在轮起点渲染（见 itemBuilder）。
    final needTailIdentity =
        running && (blocks.isEmpty || blocks.last.kind == BlockKind.user);
    // §UX-2.2：每条消息一个复制入口——user 块复制原文；AI 回复的末块复制整条回复。
    // 流式进行中不挂 AI 回复复制（避免复制半截内容）。
    final copyKinds = List<_MsgCopy>.filled(blocks.length, _MsgCopy.none);
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].kind == BlockKind.user) {
        copyKinds[i] = _MsgCopy.user;
      } else if (!running &&
          (i == blocks.length - 1 || blocks[i + 1].kind == BlockKind.user)) {
        copyKinds[i] = _MsgCopy.reply;
      }
    }
    // 渲染分组：把连续「思考 + 工具」合并为可折叠 AgentGroup；user / text / 孤立 tool
    // 单独成 SingleBlockGroup。一次构建完所有组，itemBuilder 按 index 取。
    final groups = buildAgentGroups(blocks);

    // 有弹层打开时拦截返回手势：先关最上层弹层，而非直接退出页面（§UX-1.5）。
    return AnimatedBuilder(
      animation: PopupRegistry.instance,
      builder: (ctx, child) => PopScope(
        canPop: !PopupRegistry.instance.hasOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) PopupRegistry.instance.closeTopmost();
        },
        child: child!,
      ),
      child: Scaffold(
      // 主聊天区使用纯净内容画布；Drawer 仍保留原浅灰背景，形成清晰层级。
      backgroundColor: AppColors.contentCanvasOf(context),
      drawer: SessionStoreScope(
        store: _store,
        child: SessionArchiveStoreScope(
          store: _archive,
          child: Drawer(
            width: 280,
            backgroundColor: AppColors.backgroundOf(context),
            child: _SessionDrawer(
              store: _store,
              archive: _archive,
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
              onOpenArchive: _openArchive,
            ),
          ),
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
                      : NotificationListener<UserScrollNotification>(
                          onNotification: _onUserScroll,
                          child: ListView.builder(
                          controller: _scrollCtrl,
                          padding: EdgeInsets.fromLTRB(
                              AppSpacing.pageMargin,
                              8,
                              AppSpacing.pageMargin,
                              dockH),
                          // 等待首 token（最后一块还是 user）时，标识作为列表尾部占位；
                          // 一旦 AI 块出现，标识渲染在轮起点，不再需要尾部占位。
                          // 渲染层：先按 buildAgentGroups 把「思考 + 工具」合并成组，
                          // 每组一个 item；user / text 单独成 SingleBlockGroup。
                          itemCount: groups.length +
                              (needTailIdentity ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i < groups.length) {
                              final g = groups[i];
                              final head = g.headIndex;
                              // §3.2-1 AI 身份标识：每轮输出顶部（KimiCore 星形 + 基线名）。
                              // 当前正在输出的轮动态转动，历史轮静止。
                              final curTurn =
                                  running ? _currentTurnStart(blocks) : null;
                              final isTail = i == groups.length - 1;
                              final children = <Widget>[
                                if (_atTurnStart(blocks, head))
                                  _AiIdentityBar(streaming: head == curTurn),
                                Padding(
                                  padding: EdgeInsets.only(
                                      bottom: isTail
                                          ? 0
                                          : (copyKinds[head] != _MsgCopy.none
                                              ? 2.0
                                              : AppSpacing.lg)),
                                  child: _renderGroup(g, running, isTail),
                                ),
                              ];
                              // §UX-2.2：按消息维度复制——用户消息复制原文；
                              // AI 回复在回复末块处复制整条回复（流式不显示）。
                              final cpy = copyKinds[head];
                              if (cpy != _MsgCopy.none) {
                                final text = cpy == _MsgCopy.user
                                    ? blocks[head].text
                                    : conversationText(blocks.sublist(
                                        _aiRunStart(blocks, head), head + 1));
                                children.add(const SizedBox(height: 0));
                                children.add(Row(
                                  mainAxisAlignment: cpy == _MsgCopy.user
                                      ? MainAxisAlignment.end
                                      : MainAxisAlignment.start,
                                  children: [
                                    CopyButton(text: text, plain: true)
                                  ],
                                ));
                              }
                              final child = Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: children,
                              );
                              final key = _groupKeys.putIfAbsent(
                                  head, () => GlobalKey());
                              return g.blocks.first.kind == BlockKind.user
                                  ? _UserMessageAnchor(
                                      key: key,
                                      scrollController: _scrollCtrl,
                                      onPosition: (offset) =>
                                          _userOffsets[head] = offset,
                                      child: child,
                                    )
                                  : KeyedSubtree(key: key, child: child);
                            }
                            // 发送后等待首 token：AI 块还没出现，标识在 user 下方、
                            // 即"即将输出内容的最上面"，动态转动。
                            return _AiIdentityBar(streaming: true);
                          },
                        ),
                      ),
                  // §3.2-4 全局生成状态条：busy 全程 2px indeterminate 进度，输出完收起。
                  if (running)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                        backgroundColor: Colors.transparent,
                        color: AppColors.accentOf(context),
                        minHeight: 2,
                      ),
                    ),
                  // 双行为导航：向下滚时回到底部；向上滚时回最近一条用户对话。
                  if (!_atBottom && blocks.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: dockH + 12,
                      child: Center(
                        child: _ScrollJumpFab(
                          direction: _scrollDirection,
                          newCount: _newWhileAway,
                          onTap: () {
                            if (_scrollDirection == ScrollDirection.forward) {
                              _scrollToLatestUser(groups);
                            } else {
                              _atBottom = true;
                              _newWhileAway = 0;
                              setState(() {});
                              _scrollToBottom();
                            }
                          },
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: NotificationListener<SizeChangedLayoutNotification>(
                      onNotification: (_) {
                        _scheduleDockMeasure();
                        return false;
                      },
                      child: SizeChangedLayoutNotifier(
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
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
      _ => AppColors.placeholderOf(context),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: Row(
        children: [
          _iconBtn(AppIcons.menu,
              onTap: () => Scaffold.of(context).openDrawer()),
          const SizedBox(width: 2),
          // 主题切换（浅色/暗色），偏好持久化。
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (_, mode, _) => _iconBtn(
              mode == ThemeMode.dark ? AppIcons.sun : AppIcons.moon,
              onTap: () => setThemeMode(
                mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
              ),
            ),
          ),
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
    return HuxButton(
      onPressed: onTap ?? () {},
      variant: HuxButtonVariant.ghost,
      size: HuxButtonSize.small,
      icon: icon,
      child: const SizedBox(width: 0),
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
  /// 退场动画中尚未移除的 entry；重开时先强制移除，避免 GlobalKey 冲突。
  OverlayEntry? _exiting;
  final _popupKey = GlobalKey<PopupAnimatorState>();
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
    _killExiting();
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
      builder: (ctx) => PopupAnimator(
        key: _popupKey,
        onScrimTap: _close,
        origin: above ? Alignment.bottomRight : Alignment.topRight,
        top: above ? null : topY,
        bottom: above ? (vh - off.dy + 6) : null,
        right: 8,
        width: 168,
        child: HuxCard(
          margin: EdgeInsets.zero,
          padding: const EdgeInsets.symmetric(vertical: 8),
          borderRadius: AppRadius.card,
          backgroundColor: AppColors.surfaceOf(context),
          borderColor: AppColors.hairlineOf(context),
          elevation: 0,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
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
      ),
    );
    Overlay.of(context).insert(_entry!);
    PopupRegistry.instance.register(_close);
    setState(() {});
  }

  void _killExiting() {
    final e = _exiting;
    if (e != null) {
      _exiting = null;
      e.remove();
    }
  }

  void _close() {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    PopupRegistry.instance.unregister(_close);
    if (mounted) setState(() {});
    // 先播退场动画再移除 entry（§UX-1.1：反向 120ms easeIn）。
    final st = _popupKey.currentState;
    if (st == null) {
      entry.remove();
      return;
    }
    _exiting = entry;
    st.dismiss().then((_) {
      if (_exiting != entry) return; // 已被重开逻辑强制移除。
      _exiting = null;
      entry.remove();
    });
  }

  @override
  void dispose() {
    if (_entry != null) PopupRegistry.instance.unregister(_close);
    _entry?.remove();
    _killExiting();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cur = _cfgCur(widget.cfg, 'mode');
    final icon = _modeIcon[cur] ?? AppIcons.modeManual;
    return Semantics(
      label: '切换模式',
      button: true,
      child: HuxButton(
        onPressed: _toggle,
        variant: HuxButtonVariant.secondary,
        size: HuxButtonSize.small,
        icon: icon,
        child: const SizedBox(width: 0),
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
          color: _down ? AppColors.keyCapOf(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 16, color: AppColors.textSecondaryOf(context)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(widget.label,
                  style: AppText.calloutStrong.copyWith(
                    color: AppColors.textPrimaryOf(context),
                  )),
            ),
            if (widget.selected)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Icon(AppIcons.check, size: 16, color: AppColors.accentOf(context)),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------- 级联配置菜单：home → provider / model / thinking（§09 级联结构）----------

/// 顶栏单一触发器，弹出后先显示 provider / model / thinking 三个入口，
/// 点击入口进入对应选择列表。选中即下发并关闭（§UX-1.2 层级过渡）。
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
  /// 退场动画中尚未移除的 entry；重开时先强制移除，避免 GlobalKey 冲突。
  OverlayEntry? _exiting;
  final _popupKey = GlobalKey<PopupAnimatorState>();
  double _menuMaxH = 300;
  /// 面板切换方向：true = 下钻（新层从右入），false = 返回（§UX-1.2 层级过渡）。
  bool _navForward = true;
  /// 当前面板：home / provider / model / effort。
  String _panel = 'home';
  bool _expandProvider = false;
  bool _expandModel = false;
  bool _expandThinking = false;
  bool get _open => _entry != null;

  List<Map<String, dynamic>> get _models => _cfgList(widget.cfg, 'model');
  String get _curModel => _cfgCur(widget.cfg, 'model');
  String get _curProvider => _provOf(_curModel);

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

  String get _curEffortLabel {
    return widget.effortLabel[widget.effortId] ??
        widget.effortOpts
            .firstWhere((e) => e.id == widget.effortId,
                orElse: () => widget.effortOpts.first)
            .label;
  }

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    _killExiting();
    _panel = 'home';
    _expandProvider = false;
    _expandModel = false;
    _expandThinking = false;
    _navForward = true;
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
    const width = 216.0;
    final left = (AppSpacing.pageMargin + width > screenW - 8)
        ? screenW - 8 - width
        : AppSpacing.pageMargin;

    _entry = OverlayEntry(builder: (ctx) {
      return StatefulBuilder(builder: (ctx2, setOverlay) {
        return PopupAnimator(
          key: _popupKey,
          onScrimTap: _close,
          origin: above ? Alignment.bottomLeft : Alignment.topLeft,
          top: above ? null : topY,
          bottom: above ? (vh - off.dy + 6) : null,
          left: left,
          width: width,
          child: HuxCard(
            margin: EdgeInsets.zero,
            padding: EdgeInsets.zero,
            borderRadius: AppRadius.card,
            backgroundColor: AppColors.surfaceOf(context),
            borderColor: AppColors.hairlineOf(context),
            elevation: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(setOverlay),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: _menuMaxH),
                  child: SingleChildScrollView(
                    // 层级切换：水平位移 + 淡入淡出，高度变化用 AnimatedSize 平滑（§UX-1.2）。
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previous,
                            ?current,
                          ],
                        ),
                        transitionBuilder: (child, anim) {
                          // 下钻：新层右侧入、旧层左侧出；返回时相反。
                          final incoming = child.key == ValueKey(_panel);
                          final begin = (_navForward == incoming)
                              ? const Offset(0.12, 0)
                              : const Offset(-0.12, 0);
                          return SlideTransition(
                            position: Tween(begin: begin, end: Offset.zero)
                                .animate(anim),
                            child: FadeTransition(opacity: anim, child: child),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(_panel),
                          child: _panelList(setOverlay),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ),
        );
      });
    });
    Overlay.of(context).insert(_entry!);
    PopupRegistry.instance.register(_close);
    setState(() {});
  }


  void _back(StateSetter setOverlay) {
    _navForward = false;
    setOverlay(() {
      _panel = 'home';
    });
  }

  void _killExiting() {
    final e = _exiting;
    if (e != null) {
      _exiting = null;
      e.remove();
    }
  }

  void _close() {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    PopupRegistry.instance.unregister(_close);
    if (mounted) setState(() {});
    // 先播退场动画再移除 entry（§UX-1.1：反向 120ms easeIn）。
    final st = _popupKey.currentState;
    if (st == null) {
      entry.remove();
      return;
    }
    _exiting = entry;
    st.dismiss().then((_) {
      if (_exiting != entry) return; // 已被重开逻辑强制移除。
      _exiting = null;
      entry.remove();
    });
  }

  @override
  void dispose() {
    if (_entry != null) PopupRegistry.instance.unregister(_close);
    _entry?.remove();
    _killExiting();
    super.dispose();
  }

  Widget _header(StateSetter setOverlay) {
    final titles = {
      'home': '配置',
      'provider': 'Provider',
      'model': 'Model',
      'effort': '思考深度',
    };
    final title = titles[_panel] ?? '配置';
    final showBack = _panel != 'home';
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairlineOf(context))),
      ),
      child: Row(
        children: [
          if (showBack)
            Pressable(
              onTap: () => _back(setOverlay),
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(AppIcons.arrowLeft,
                    size: 15, color: AppColors.textSecondaryOf(context)),
              ),
            )
          else
            const SizedBox(width: 28, height: 28),
          Expanded(
            // 标题随层级淡入淡出切换（§UX-1.2）。
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Text(
                title,
                key: ValueKey(title),
                textAlign: TextAlign.center,
                style: AppText.calloutStrong,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 28, height: 28),
        ],
      ),
    );
  }

  Widget _panelList(StateSetter setOverlay) => _homePanel(setOverlay);

  Widget _homePanel(StateSetter setOverlay) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _expandableGroup(
          title: 'Provider',
          value: _curProvider.isEmpty ? '—' : _curProvider,
          expanded: _expandProvider,
          onToggle: () => setOverlay(() => _expandProvider = !_expandProvider),
          options: _providers.map((p) => _row(
                p,
                selected: p == _curProvider,
                onTap: () {
                  final first = _modelsOf(p).firstOrNull;
                  if (first != null) {
                    widget.onModel(first['value']?.toString() ?? '');
                  }
                },
              )).toList(),
        ),
        _expandableGroup(
          title: 'Model',
          value: _curModelLabel,
          expanded: _expandModel,
          onToggle: () => setOverlay(() => _expandModel = !_expandModel),
          options: _modelsOf(_curProvider).map((o) => _row(
                o['name']?.toString() ?? o['value']?.toString() ?? '',
                selected: o['value'] == _curModel,
                onTap: () => widget.onModel(o['value']?.toString() ?? ''),
              )).toList(),
        ),
        _expandableGroup(
          title: 'Thinking',
          value: _curEffortLabel,
          expanded: _expandThinking,
          onToggle: () => setOverlay(() => _expandThinking = !_expandThinking),
          options: widget.effortOpts.map((e) => _row(
                widget.effortLabel[e.id] ?? e.label,
                selected: e.id == widget.effortId,
                onTap: () => widget.onEffort(e.id),
              )).toList(),
        ),
      ],
    );
  }

  Widget _expandableGroup({
    required String title,
    required String value,
    required bool expanded,
    required VoidCallback onToggle,
    required List<Widget> options,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: double.infinity,
          child: Pressable(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text(title,
                            style: AppText.calloutStrong.copyWith(
                              color: AppColors.textPrimaryOf(context),
                            )),
                        if (value.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(value,
                                textAlign: TextAlign.left,
                                style: AppText.caption.copyWith(
                                    color: AppColors.textSecondaryOf(context)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(AppIcons.chevronDown,
                        size: 14, color: AppColors.placeholderOf(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: options,
          ),
          crossFadeState:
              expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }


  Widget _row(String label,
      {bool selected = false, required VoidCallback onTap}) {
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: (selected ? AppText.calloutStrong : AppText.callout).copyWith(
                    color: AppColors.textPrimaryOf(context),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (selected)
              Icon(AppIcons.check, size: 15, color: AppColors.accentOf(context)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return HuxButton(
      onPressed: _toggle,
      variant: HuxButtonVariant.secondary,
      size: HuxButtonSize.small,
      icon: AppIcons.modelChip,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 128),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _curModelLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              _open ? AppIcons.chevronUp : AppIcons.chevronDown,
              size: 12,
            ),
          ],
        ),
      ),
    );
  }
}


// ---------- 会话抽屉：真实 session.list + 搜索 + 工作区分组 + 加载更多 + 归档 ----------

class _SessionDrawer extends StatefulWidget {
  final SessionStore store;
  final SessionArchiveStore archive;
  final ValueChanged<SessionMeta> onPick;
  final VoidCallback onNew;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenArchive;
  const _SessionDrawer({
    required this.store,
    required this.archive,
    required this.onPick,
    required this.onNew,
    required this.onOpenSettings,
    required this.onOpenArchive,
  });

  @override
  State<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<_SessionDrawer> {
  String _q = '';

  /// 折叠中的工作区分组（按 _groupKey）。搜索时自动忽略折叠，保证直达。
  final Set<String> _collapsed = {};

  /// 每个工作区的"已展开条数"：默认 5，足够 90% 场景。
  static const int _kPageSize = 5;
  final Map<String, int> _expanded = {};

  bool get _searching => _q.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.archive.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.archive.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _toggleGroup(String key) {
    setState(() {
      if (!_collapsed.add(key)) _collapsed.remove(key);
    });
  }

  void _expandMore(String key) {
    setState(() {
      _expanded[key] = (_expanded[key] ?? _kPageSize) + _kPageSize;
    });
  }

  // 匹配标题或工作目录路径（按目录找也是常见习惯）。
  bool _match(SessionMeta m) {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return true;
    return m.title.toLowerCase().contains(q) ||
        m.cwd.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    // 1) 搜索过滤 + 排除已归档（工作区抽屉只展示未归档的活跃/历史会话）。
    final filtered = widget.store.history
        .where(_match)
        .where((m) => !widget.archive.isArchived(m.sessionId))
        .toList();
    // 2) 工作区分组 + 组内按时间倒序。
    final wg = WorkspaceGroups.fold(
      filtered,
      pageSize: _kPageSize,
      initialExpanded: _expanded,
    );
    final cur = widget.store.currentSid;
    final archiveCount = widget.archive.ids.length;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: HuxButton(
              onPressed: widget.onNew,
              variant: HuxButtonVariant.primary,
              primaryColor: AppColors.textPrimaryOf(context),
              textColor: AppColors.surfaceOf(context),
              size: HuxButtonSize.medium,
              width: HuxButtonWidth.expand,
              icon: AppIcons.plus,
              child: Text('新建会话', style: AppText.calloutStrong),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: HuxInput(
              hint: '搜索会话',
              prefixIcon: const Icon(AppIcons.search),
              textInputAction: TextInputAction.search,
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('工作区', style: AppText.monoCaption),
          ),
          Expanded(
            child: wg.groups.isEmpty
                ? Center(
                    child: Text('无匹配会话', style: AppText.caption),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    children: [
                      for (final entry in wg.groups) ...[
                        _groupHeader(
                          entry.key,
                          entry.value.length,
                          entry.value.map((m) => m.sessionId).toList(),
                        ),
                        AnimatedCrossFade(
                          duration: const Duration(milliseconds: 180),
                          firstCurve: Curves.easeOut,
                          secondCurve: Curves.easeOut,
                          // 搜索时忽略折叠：所有匹配组展开，方便直达。
                          // 其余情况完全由用户控制。
                          crossFadeState:
                              (!_searching && _collapsed.contains(entry.key))
                                  ? CrossFadeState.showSecond
                                  : CrossFadeState.showFirst,
                          firstChild: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final m in entry.value
                                  .take(wg.expanded[entry.key] ??
                                      entry.value.length))
                                _row(m, m.sessionId == cur),
                              // 加载更多：仅当还有未展示的会话时显示。
                              if (wg.remainingOf(
                                      entry.key, entry.value.length) >
                                  0)
                                _loadMore(
                                  entry.key,
                                  wg.remainingOf(
                                      entry.key, entry.value.length),
                                ),
                            ],
                          ),
                          secondChild:
                              const SizedBox(width: double.infinity),
                        ),
                      ],
                    ],
                  ),
          ),
          // 底部两行入口：已归档 + 设置。
          Container(
            decoration: BoxDecoration(
              border:
                  Border(top: BorderSide(color: AppColors.hairlineOf(context))),
            ),
            child: Column(
              children: [
                Pressable(
                  onTap: widget.onOpenArchive,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(AppIcons.archive,
                            size: 18,
                            color: AppColors.textSecondaryOf(context)),
                        const SizedBox(width: 10),
                        Text('查看已归档', style: AppText.callout),
                        const Spacer(),
                        if (archiveCount > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.keyCapOf(context),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                            ),
                            child: Text('$archiveCount',
                                style: AppText.monoCaption),
                          ),
                        const SizedBox(width: 4),
                        Icon(AppIcons.chevronRight,
                            size: 14,
                            color: AppColors.placeholderOf(context)),
                      ],
                    ),
                  ),
                ),
                Pressable(
                  onTap: widget.onOpenSettings,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(AppIcons.settings,
                            size: 18,
                            color: AppColors.textSecondaryOf(context)),
                        const SizedBox(width: 10),
                        Text('设置', style: AppText.callout),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 工作区分组头：可点击折叠/展开，右侧显示会话数与「…」菜单。
  Widget _groupHeader(String key, int count, List<String> sids) {
    final collapsed = _collapsed.contains(key);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 4, 4),
      child: Row(
        children: [
          // 折叠按钮：单独 44×44 触控区，避免和「…」冲突。
          Expanded(
            child: Pressable(
              onTap: () => _toggleGroup(key),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                child: Row(
                  children: [
                    Icon(
                        collapsed
                            ? AppIcons.chevronRight
                            : AppIcons.chevronDown,
                        size: 14,
                        color: AppColors.textSecondaryOf(context)),
                    const SizedBox(width: 4),
                    Icon(AppIcons.folder,
                        size: 15,
                        color: AppColors.textSecondaryOf(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(key,
                          style: AppText.calloutStrong,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text('$count', style: AppText.monoCaption),
                    const SizedBox(width: 2),
                  ],
                ),
              ),
            ),
          ),
          _GroupMenu(workspaceKey: key, sessionIds: sids),
        ],
      ),
    );
  }

  Widget _loadMore(String key, int remaining) {
    return Pressable(
      onTap: () => _expandMore(key),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 6, 16, 6),
        child: Row(
          children: [
            Text('加载更多 $remaining 个对话',
                style: AppText.callout.copyWith(
                    color: AppColors.accentOf(context))),
            const SizedBox(width: 4),
            Icon(AppIcons.chevronDown,
                size: 12, color: AppColors.accentOf(context)),
          ],
        ),
      ),
    );
  }

  Widget _row(SessionMeta m, bool sel) {
    return Pressable(
      onTap: () => widget.onPick(m),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: sel ? AppColors.accentSoftOf(context) : Colors.transparent,
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
                  color: sel ? AppColors.accentOf(context) : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
                  child: Text(
                    m.title.isEmpty ? '（无标题）' : m.title,
                    style: (sel ? AppText.calloutStrong : AppText.callout)
                        .copyWith(color: AppColors.textPrimaryOf(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              // 行内"…"菜单：复制 ID / 归档 / 等等。
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _SessionRowMenu(meta: m),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 工作区抽屉的行内"…"菜单。
/// 现阶段只有复制 ID 与归档是真实能力；其它（重命名/分叉/导出）等待 kimi
/// acp 补 API（见 test/probe/session_list_probe_test gap #2），暂以占位
/// 提示呈现，不空跑。
class _SessionRowMenu extends StatelessWidget {
  final SessionMeta meta;
  const _SessionRowMenu({required this.meta});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_RowMenuAction>(
      tooltip: '更多',
      offset: const Offset(0, 28),
      color: AppColors.surfaceOf(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.popup),
        side: BorderSide(color: AppColors.hairlineOf(context)),
      ),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: _RowMenuAction.copyId,
          height: 36,
          child: _SessionMenuItem(
              icon: AppIcons.copy, label: '复制 Session ID'),
        ),
        PopupMenuItem(
          value: _RowMenuAction.rename,
          height: 36,
          child: _SessionMenuItem(icon: AppIcons.command, label: '重命名'),
        ),
        PopupMenuItem(
          value: _RowMenuAction.fork,
          height: 36,
          child:
              _SessionMenuItem(icon: AppIcons.ellipsis, label: '分叉会话'),
        ),
        PopupMenuItem(
          value: _RowMenuAction.export,
          height: 36,
          child: _SessionMenuItem(icon: AppIcons.arrowLeft, label: '导出会话'),
        ),
        PopupMenuDivider(height: 1),
        PopupMenuItem(
          value: _RowMenuAction.archive,
          height: 36,
          child: _SessionMenuItem(
            icon: AppIcons.archive,
            label: '归档',
            danger: true,
          ),
        ),
      ],
      onSelected: (a) => _onSelected(context, a),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(AppIcons.ellipsis,
            size: 16, color: AppColors.placeholderOf(context)),
      ),
    );
  }

  void _onSelected(BuildContext context, _RowMenuAction a) {
    final rootCtx = context;
    final archive = SessionArchiveStoreScope.of(rootCtx);
    switch (a) {
      case _RowMenuAction.copyId:
        copyToClipboard(rootCtx, meta.sessionId);
      case _RowMenuAction.archive:
        archive.archive(meta.sessionId);
        if (rootCtx.mounted) {
          rootCtx.showHuxSnackbar(
            message:
                '已归档：${meta.title.isEmpty ? "（无标题）" : meta.title}',
            variant: HuxSnackbarVariant.success,
            duration: const Duration(milliseconds: 1500),
          );
        }
      case _RowMenuAction.rename:
      case _RowMenuAction.fork:
      case _RowMenuAction.export:
        // 等待 kimi acp 补 API（gap #2），暂以 toast 告知，避免空跑。
        if (rootCtx.mounted) {
          rootCtx.showHuxSnackbar(
            message: '${_labelOf(a)} 即将支持',
            variant: HuxSnackbarVariant.info,
            duration: const Duration(milliseconds: 1500),
          );
        }
    }
  }

  String _labelOf(_RowMenuAction a) => switch (a) {
        _RowMenuAction.copyId => '复制 Session ID',
        _RowMenuAction.rename => '重命名',
        _RowMenuAction.fork => '分叉会话',
        _RowMenuAction.export => '导出会话',
        _RowMenuAction.archive => '归档',
      };
}

enum _RowMenuAction { copyId, rename, fork, export, archive }

class _SessionMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;
  const _SessionMenuItem(
      {required this.icon, required this.label, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.reject : AppColors.textPrimaryOf(context);
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 10),
        Text(label, style: AppText.callout.copyWith(color: color)),
      ],
    );
  }
}

/// 工作区分组头的「…」菜单：复制工作区路径 / 归档该工作区 / 重命名 / 移除工作区。
/// 仅「复制路径」与「归档」是真实能力，其余等 kimi acp 补 API（见
/// test/probe/session_list_probe_test gap #2），暂以 toast 告知。
class _GroupMenu extends StatelessWidget {
  final String workspaceKey; // sessionGroupKey（路径末两级）
  final List<String> sessionIds; // 该工作区当前可见（未归档）会话的 sid
  const _GroupMenu({required this.workspaceKey, required this.sessionIds});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_GroupMenuAction>(
      tooltip: '工作区操作',
      offset: const Offset(0, 32),
      color: AppColors.surfaceOf(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.popup),
        side: BorderSide(color: AppColors.hairlineOf(context)),
      ),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _GroupMenuAction.copyPath,
          height: 36,
          child: _SessionMenuItem(icon: AppIcons.copy, label: '复制工作区路径'),
        ),
        const PopupMenuItem(
          value: _GroupMenuAction.archiveWorkspace,
          height: 36,
          child: _SessionMenuItem(icon: AppIcons.archive, label: '归档工作区'),
        ),
        const PopupMenuItem(
          value: _GroupMenuAction.rename,
          height: 36,
          child: _SessionMenuItem(icon: AppIcons.rename, label: '重命名工作区'),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: _GroupMenuAction.remove,
          height: 36,
          child: _SessionMenuItem(
            icon: AppIcons.remove,
            label: '移除工作区',
            danger: true,
          ),
        ),
      ],
      onSelected: (a) => _onSelected(context, a),
      child: SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: Icon(AppIcons.ellipsis,
              size: 16, color: AppColors.placeholderOf(context)),
        ),
      ),
    );
  }

  void _onSelected(BuildContext context, _GroupMenuAction a) {
    final rootCtx = context;
    final archive = SessionArchiveStoreScope.of(rootCtx);
    switch (a) {
      case _GroupMenuAction.copyPath:
        // 复制完整工作区路径（而非 last two key）：从 store 里反查。
        final store = SessionStoreScope.of(rootCtx);
        final fullCwd = _resolveFullCwd(store);
        if (fullCwd == null) return;
        copyToClipboard(rootCtx, fullCwd);
      case _GroupMenuAction.archiveWorkspace:
        final n = archive.archiveAll(sessionIds);
        if (rootCtx.mounted) {
          rootCtx.showHuxSnackbar(
            message: n > 0
                ? '已归档工作区「$workspaceKey」下的 $n 个会话'
                : '工作区「$workspaceKey」下没有需要归档的会话',
            variant: n > 0
                ? HuxSnackbarVariant.success
                : HuxSnackbarVariant.info,
            duration: const Duration(milliseconds: 1800),
          );
        }
      case _GroupMenuAction.rename:
      case _GroupMenuAction.remove:
        if (rootCtx.mounted) {
          rootCtx.showHuxSnackbar(
            message: '${_labelOf(a)}即将支持',
            variant: HuxSnackbarVariant.info,
            duration: const Duration(milliseconds: 1500),
          );
        }
    }
  }

  /// 在 store.history 里反查工作区的完整 cwd。找不到时返回 null。
  String? _resolveFullCwd(SessionStore store) {
    for (final m in store.history) {
      if (sessionGroupKey(m.cwd) == workspaceKey) return m.cwd;
    }
    return null;
  }

  String _labelOf(_GroupMenuAction a) => switch (a) {
        _GroupMenuAction.copyPath => '复制工作区路径',
        _GroupMenuAction.archiveWorkspace => '归档工作区',
        _GroupMenuAction.rename => '重命名工作区',
        _GroupMenuAction.remove => '移除工作区',
      };
}

enum _GroupMenuAction { copyPath, archiveWorkspace, rename, remove }

/// 让 _SessionRowMenu（无 BuildContext 上下文）能拿到全局 SessionStore / Archive。
/// 抽屉由 _HomeShellState 直接 build，所以这两个对象就近放在 InheritedWidget。
class SessionStoreScope extends InheritedWidget {
  final SessionStore store;
  const SessionStoreScope(
      {super.key, required this.store, required super.child});
  static SessionStore of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<SessionStoreScope>()!.store;
  @override
  bool updateShouldNotify(SessionStoreScope old) => old.store != store;
}

class SessionArchiveStoreScope extends InheritedWidget {
  final SessionArchiveStore store;
  const SessionArchiveStoreScope(
      {super.key, required this.store, required super.child});
  static SessionArchiveStore of(BuildContext c) => c
      .dependOnInheritedWidgetOfExactType<SessionArchiveStoreScope>()!
      .store;
  @override
  bool updateShouldNotify(SessionArchiveStoreScope old) =>
      old.store != store;
}

// ---------- AI 身份标识（§3.2-1：每轮输出顶部）----------

/// AI 输出轮的身份标识：KimiCore 星形 + 实测基线名。
/// 该轮正在流式输出时星形动态转动，输出结束/历史轮静止（身份标识语义）。
class _AiIdentityBar extends StatelessWidget {
  final bool streaming;
  const _AiIdentityBar({required this.streaming});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          KimiCoreIndicator(
            size: 30,
            alignment: Alignment.centerLeft,
            animated: streaming,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(_kTestedBaseline, style: AppText.monoCaption),
          ),
        ],
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
            style: AppText.body.copyWith(color: AppColors.textSecondaryOf(context)),
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

// ---------- 双行为滚动导航 FAB ----------

class _UserMessageAnchor extends StatefulWidget {
  final ScrollController scrollController;
  final ValueChanged<double> onPosition;
  final Widget child;
  const _UserMessageAnchor({
    super.key,
    required this.scrollController,
    required this.onPosition,
    required this.child,
  });

  @override
  State<_UserMessageAnchor> createState() => _UserMessageAnchorState();
}

class _UserMessageAnchorState extends State<_UserMessageAnchor> {
  void _reportPosition() {
    if (!mounted || !widget.scrollController.hasClients) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    widget.onPosition(
        box.localToGlobal(Offset.zero).dy + widget.scrollController.offset);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportPosition());
    return widget.child;
  }
}

/// 屏幕中心底部的滚动导航：向下滚时回到底部，向上滚时回最近一条用户对话。
class _ScrollJumpFab extends StatelessWidget {
  final ScrollDirection direction;
  final int newCount;
  final VoidCallback onTap;
  const _ScrollJumpFab({
    required this.direction,
    required this.newCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final toUser = direction == ScrollDirection.forward;
    return Semantics(
      button: true,
      label: toUser ? '回到最近一条用户对话' : '回到底部',
      child: Pressable(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.surfaceOf(context),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.hairlineOf(context)),
            boxShadow: AppShadows.popup,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedRotation(
                turns: toUser ? 0.5 : 0,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                child: Icon(AppIcons.chevronDown,
                    size: 20, color: AppColors.textPrimaryOf(context)),
              ),
              if (!toUser && newCount > 0)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColors.accentOf(context),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    constraints: const BoxConstraints(minWidth: 16),
                    child: Text(
                      newCount > 99 ? '99+' : '$newCount',
                      textAlign: TextAlign.center,
                      style: AppText.monoCaption.copyWith(
                          color: AppColors.surfaceOf(context), fontSize: 9),
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

// ---------- 每条消息（用户 / AI 回复）的复制按钮（§UX-2.2：按消息维度，非整段会话）----------

/// 一条消息的复制动作类型：无 / 复制用户原文 / 复制整条 AI 回复。
enum _MsgCopy { none, user, reply }

/// 返回某条 AI 块所属回复的起点（向前找到上一个 user 块之后）。
int _aiRunStart(List<StreamBlock> blocks, int i) {
  var s = i;
  while (s - 1 >= 0 && blocks[s - 1].kind != BlockKind.user) {
    s--;
  }
  return s;
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
        // dock 与主聊天画布同底，不再叠一整块浅灰区域。
        // 保留 4px 纯色呼吸带，避免恢复会在暗色下产生白条的透明渐变。
        Container(
          height: 4,
          color: AppColors.contentCanvasOf(context),
        ),
        Container(
          color: AppColors.contentCanvasOf(context),
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
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (_, i) => Pressable(
                    onTap: () => onChip(_chips[i]),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 13, vertical: 8),
                      decoration: BoxDecoration(
                        // 快捷语句从实心灰 chip 改为画布同色 + 极淡描边，
                        // 降低 dock 内连续灰色填充的密度。
                        color: AppColors.contentCanvasOf(context),
                        border: Border.all(
                          color: AppColors.hairlineOf(context),
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      alignment: Alignment.center,
                      child: Text(_chips[i],
                          style: AppText.callout
                              .copyWith(color: AppColors.textPrimaryOf(context))),
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
                child: ComposerInputBar(
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
        color: AppColors.surfaceOf(context),
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
                Icon(AppIcons.command,
                    size: 13, color: AppColors.textSecondaryOf(context)),
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

class ComposerInputBar extends StatelessWidget {
  final bool enabled;
  final bool running;
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;
  final ValueChanged<String> onChanged;
  final VoidCallback onOpenPlus;
  const ComposerInputBar({
    super.key,
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
    void submitFromKeyboard() {
      if (running) return;
      final value = controller.value;
      // 中文输入法正在组合候选词时，Enter 是确认候选，不应发送消息。
      if (value.composing.isValid && !value.composing.isCollapsed) return;
      onSend(value.text);
    }

    void insertNewline() {
      final value = controller.value;
      // Shift+Enter 在输入法组合态下交给 IME，避免破坏候选词。
      if (value.composing.isValid && !value.composing.isCollapsed) return;
      final selection = value.selection.isValid
          ? value.selection
          : TextSelection.collapsed(offset: value.text.length);
      final start = selection.start;
      final end = selection.end;
      final text = value.text.replaceRange(start, end, '\\n');
      controller.value = value.copyWith(
        text: text,
        selection: TextSelection.collapsed(offset: start + 1),
        composing: TextRange.empty,
      );
      onChanged(text);
    }

    // 药丸形 composer：使用主内容专属 quietSurface，而非更重的通用 keyCap；
    // 保留轮廓和聚焦感，但避免与快捷 chips、画布叠成连续灰块。
    // 三键（+ / send / stop）统一用 Material+InkWell 圆形，与外层药丸视觉对齐。
    return Container(
      key: const ValueKey('composer-bar'),
      decoration: BoxDecoration(
        color: AppColors.quietSurfaceOf(context),
        // 不能使用 pill：多行时会把圆角半径固定到高度的一半，
        // 看起来始终像椭圆。固定卡片圆角后，内容增高会自然变成长方形。
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairlineOf(context)),
      ),
      padding: const EdgeInsets.all(6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _circleIconBtn(
            key: const ValueKey('composer-plus'),
            bg: AppColors.surfaceOf(context),
            icon: AppIcons.plus,
            iconColor: AppColors.textPrimaryOf(context),
            onTap: onOpenPlus,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                SingleActivator(LogicalKeyboardKey.enter, shift: true):
                    insertNewline,
                SingleActivator(LogicalKeyboardKey.enter): submitFromKeyboard,
              },
              child: TextField(
                controller: controller,
              enabled: enabled,
              style: AppText.body,
              key: const ValueKey('composer-input'),
              // 多行：写代码/长指令不被压成一行；达到 6 行后仅在输入区内滚动。
              minLines: _kComposerMinLines,
              maxLines: _kComposerMaxLines,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.send,
              // 代码 agent：关闭自动纠错/自动大写，避免被改词。
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              onChanged: onChanged,
              // 移动端软键盘的发送 action 仍走 onSubmitted；桌面端的
              // Enter/Shift+Enter 通过 Shortcuts 在 TextField 外显式分流。
              onSubmitted: onSend,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                // 主题默认会给 InputDecorationTheme 一个 enabledBorder 描边，
                // 这里在 composer 里彻底关掉，否则会看到内嵌一圈淡灰线条。
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                hintText: enabled ? '尽管问…' : '先连接中继',
                hintStyle: AppText.placeholder,
                contentPadding: const EdgeInsets.symmetric(
                  vertical: _kComposerVerticalPadding,
                ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // §13「停」可见性随状态：流式中亮且显眼（圆 + reject 红），空闲时是发送（圆 + 黑）。
          if (running)
            _circleIconBtn(
              key: const ValueKey('composer-stop'),
              bg: AppColors.reject,
              icon: AppIcons.stop,
              iconColor: AppColors.surfaceOf(context),
              onTap: onStop,
            )
          else
            _circleIconBtn(
              key: const ValueKey('composer-send'),
              bg: AppColors.textPrimaryOf(context),
              icon: AppIcons.send,
              iconColor: AppColors.surfaceOf(context),
              onTap: enabled ? () => onSend(controller.text) : null,
            ),
        ],
      ),
    );
  }

  /// 36×36 圆形图标按钮：与 + 按钮共用同一形状，三键视觉对齐。
  /// disabled 时整体 0.45 透明，比换灰底色更克制、不抢焦点。
  Widget _circleIconBtn({
    Key? key,
    required Color bg,
    required IconData icon,
    required Color iconColor,
    required VoidCallback? onTap,
  }) {
    final isEnabled = onTap != null;
    return Opacity(
      opacity: isEnabled ? 1.0 : 0.45,
      key: key,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 18, color: iconColor),
          ),
        ),
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

class _PermSheetState extends State<_PermSheet>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final DateTime _deadline;
  /// 倒计时初始总时长：作为进度环比例的分母（§UX-6.2-2）。
  late final Duration _total;
  Timer? _t;
  Duration _remaining = Duration.zero;

  /// 入场动画：translateY 24→0 + fade，220ms easeOut（§UX-6.2-1）。
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final CurvedAnimation _enterCurve =
      CurvedAnimation(parent: _enter, curve: Curves.easeOut);
  late final Animation<Offset> _slide =
      Tween(begin: const Offset(0, 0.16), end: Offset.zero)
          .animate(_enterCurve);

  @override
  void initState() {
    super.initState();
    _deadline = widget.perm.deadline ??
        DateTime.now().add(_kDefaultPermTimeout);
    _total = _deadline.difference(DateTime.now());
    _tick();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _tick();
    });
    _enter.forward();
    HapticFeedback.mediumImpact(); // 批准请求是最高优先级交互，给触觉提醒。
  }

  @override
  void dispose() {
    _t?.cancel();
    _enterCurve.dispose();
    _enter.dispose();
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
    final critical = p.critical;
    final barColor = critical ? AppColors.reject : AppColors.textSecondaryOf(context);
    final out = _remaining == Duration.zero;

    // §UX-6.2-1 入场：translateY 24→0 + fade，220ms easeOut。
    return FadeTransition(
      opacity: _enterCurve,
      child: SlideTransition(
        position: _slide,
        child: _card(p, critical, barColor, out),
      ),
    );
  }

  Widget _card(PermissionRequest p, bool critical, Color barColor, bool out) {
    return HuxCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      borderRadius: AppRadius.card,
      backgroundColor: AppColors.surfaceOf(context),
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
                    // §UX-6.2-3 超时态：明确说明 + 按钮组灰化禁用，不留下可操作但无效的按钮。
                    if (out) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          const Icon(AppIcons.alertTriangle,
                              size: 13, color: AppColors.reject),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('已超时 · Kimi 已按默认策略处理',
                                style: AppText.caption
                                    .copyWith(color: AppColors.reject)),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        for (final opt in p.options) ...[
                          // §UX-6.2-4：主操作「批准」占更大宽度比（2:1:1）。
                          Expanded(
                            flex: opt.kind == 'allow_once' ? 2 : 1,
                            child: _permBtn(opt, disabled: out),
                          ),
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
          color: AppColors.backgroundOf(context),
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
              color: AppColors.textSecondaryOf(context),
            ),
          ],
        ),
      ),
    );
  }

  /// §UX-6.2-2：倒计时 chip = 3px 进度环（随剩余比例消减）+ mm:ss，
  /// 颜色随剩余比例 green→orange→red；超时后只显示「已超时」。
  Widget _countdownChip(bool critical) {
    final m = _remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final out = _remaining == Duration.zero;
    final frac = _total.inMilliseconds > 0
        ? (_remaining.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final color = out || critical
        ? AppColors.reject
        : frac > 0.5
            ? AppColors.approve
            : frac > 0.2
                ? AppColors.warning
                : AppColors.reject;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!out) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                value: frac,
                strokeWidth: 2.5,
                color: color,
                backgroundColor: color.withValues(alpha: 0.18),
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(out ? '已超时' : '$m:$s',
              style: AppText.monoCaption.copyWith(color: color)),
        ],
      ),
    );
  }

  Widget _permBtn(PermOption opt, {bool disabled = false}) {
    final (primaryColor, variant, label, lightText) = switch (opt.kind) {
      'allow_once' =>
        (AppColors.approve, HuxButtonVariant.primary, '批准', true),
      'allow_always' =>
        (null, HuxButtonVariant.secondary, '本会话', false),
      'reject_once' => (AppColors.reject, HuxButtonVariant.primary, '拒绝', true),
      _ => (null, HuxButtonVariant.secondary, opt.name ?? opt.optionId, false),
    };
    return HuxButton(
      onPressed: disabled ? null : () => widget.onDecide(opt),
      variant: variant,
      primaryColor: primaryColor,
      textColor: lightText ? AppColors.surfaceOf(context) : null,
      size: HuxButtonSize.medium,
      width: HuxButtonWidth.expand,
      isDisabled: disabled,
      child: Text(label,
          style: AppText.calloutStrong),
    );
  }
}

// ---------- 设置（机器体检真实值 + 中继地址可重连）----------

class _SettingsSheet extends StatefulWidget {
  final SessionStore store;
  final String relayUrl;
  final String effortLabel;
  final ValueChanged<String> onReconnect;
  final ValueChanged<Map<String, dynamic>> onSaveConfig;
  const _SettingsSheet({
    required this.store,
    required this.relayUrl,
    required this.effortLabel,
    required this.onReconnect,
    required this.onSaveConfig,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _urlCtrl =
      TextEditingController(text: widget.relayUrl);
  late final TextEditingController _barkUrlCtrl = TextEditingController();
  late final TextEditingController _timeoutCtrl = TextEditingController();
  late bool _autoPass = false;
  /// 用户动过表单后不再跟随 store 刷新（避免保存回执覆盖编辑中的值）。
  bool _userEdited = false;
  VoidCallback? _sub;

  @override
  void initState() {
    super.initState();
    _syncFromStore();
    _sub = () {
      if (mounted && !_userEdited) setState(_syncFromStore);
    };
    widget.store.addListener(_sub!);
  }

  void _syncFromStore() {
    final rc = widget.store.relayConfig;
    _barkUrlCtrl.text = rc?.barkUrl ?? '';
    _timeoutCtrl.text = (rc?.permTimeoutSeconds ?? 300).toString();
    _autoPass = rc?.autoPassNonCritical ?? false;
  }

  @override
  void dispose() {
    if (_sub != null) widget.store.removeListener(_sub!);
    _urlCtrl.dispose();
    _barkUrlCtrl.dispose();
    _timeoutCtrl.dispose();
    super.dispose();
  }

  /// 保存并应用：把表单值发给中继（写回配置文件 + 热切换），本地乐观更新。
  void _save() {
    setState(() => _userEdited = true); // 保存后以服务端回执为准
    widget.onSaveConfig({
      'barkUrl': _barkUrlCtrl.text.trim(),
      'permTimeoutSeconds': int.tryParse(_timeoutCtrl.text.trim()) ?? 300,
      'autoPassNonCritical': _autoPass,
    });
    context.showHuxSnackbar(
      message: '配置已保存并应用',
      variant: HuxSnackbarVariant.success,
      duration: const Duration(milliseconds: 1600),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final rc = widget.store.relayConfig;
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
                color: AppColors.keyCapOf(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
            child: Row(
              children: [
                Icon(AppIcons.settings,
                    size: 18, color: AppColors.textPrimaryOf(context)),
                const SizedBox(width: 8),
                const Expanded(child: Text('设置', style: AppText.title1)),
                HuxButton(
                  onPressed: () => Navigator.of(context).pop(),
                  variant: HuxButtonVariant.ghost,
                  size: HuxButtonSize.small,
                  icon: AppIcons.close,
                  child: const SizedBox(width: 0),
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
                HuxInput(
                  controller: _urlCtrl,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => widget.onReconnect(_urlCtrl.text.trim()),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: HuxButton(
                    onPressed: () => widget.onReconnect(_urlCtrl.text.trim()),
                    variant: HuxButtonVariant.primary,
                    primaryColor: AppColors.textPrimaryOf(context),
                    textColor: AppColors.surfaceOf(context),
                    size: HuxButtonSize.medium,
                    child: Text('保存并重连', style: AppText.calloutStrong),
                  ),
                ),
                const SizedBox(height: 8),
                _StatusRow(
                    label: '连接状态',
                    ok: widget.store.relayState == 'ok' ||
                        widget.store.relayState == 'connecting'),
                const SizedBox(height: 22),
                _group('锁屏门铃'),
                _ro('Bark 推送', '留空则关闭门铃'),
                HuxInput(
                  controller: _barkUrlCtrl,
                  hint: 'https://api.day.app/{key}',
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() => _userEdited = true),
                ),
                const SizedBox(height: 22),
                _group('许可策略'),
                _tg('非关键超时自动放行', _autoPass, (v) {
                  setState(() {
                    _userEdited = true;
                    _autoPass = v;
                  });
                }),
                _ro('超时时长', 'manual 模式到期未决的代答阈值'),
                HuxInput(
                  controller: _timeoutCtrl,
                  hint: '秒，如 300',
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() => _userEdited = true),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: HuxButton(
                    onPressed: _save,
                    variant: HuxButtonVariant.primary,
                    primaryColor: AppColors.textPrimaryOf(context),
                    textColor: AppColors.surfaceOf(context),
                    size: HuxButtonSize.medium,
                    child: Text('保存并应用', style: AppText.calloutStrong),
                  ),
                ),
                const SizedBox(height: 14),
                _ro(
                    '配置文件',
                    rc?.configPath.isNotEmpty == true
                        ? rc!.configPath
                        : '电脑端 relay.toml'),
                const SizedBox(height: 22),
                _group('外观'),
                _ro('主题', '浅色（v1）'),
                const SizedBox(height: 22),
                _group('关于'),
                _ro('版本', 'v0.1.0'),
                _ro('实测基线', _kTestedBaseline),
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
            HuxSwitch(
              value: v,
              onChanged: onChanged,
              size: HuxSwitchSize.medium,
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
          ? (AppColors.textSecondaryOf(context), AppIcons.history, '连接中…')
          : (AppColors.warning, AppIcons.history, '重连中…'),
      'degraded' =>
          (AppColors.warning, AppIcons.modeManual, 'Kimi 未响应 · 可重试拉起'),
      'offline' => never
          ? (AppColors.textSecondaryOf(context), AppIcons.history, '连接中…')
          : (AppColors.placeholderOf(context), AppIcons.close, '已断开 · 最后同步于 ${_hm(lastSyncedAt)}'),
      _ => (AppColors.textSecondaryOf(context), AppIcons.history, ''),
    };

    return HuxCard(
      margin: const EdgeInsets.fromLTRB(AppSpacing.pageMargin, 0, AppSpacing.pageMargin, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      borderRadius: AppRadius.thumbnail,
      backgroundColor: AppColors.surfaceOf(context),
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
            HuxButton(
              onPressed: onRetry,
              variant: HuxButtonVariant.primary,
              primaryColor: AppColors.warning,
              textColor: AppColors.surfaceOf(context),
              size: HuxButtonSize.small,
              child: Text('重试', style: AppText.calloutStrong),
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
              height: 44, // §UX-10.2-1：触控目标高度合规
              // 多会话横向滚动浏览（单屏放不下时不截断）。
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                itemCount: sids.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final sid = sids[i];
                  return _SessionTab(
                    title: store.titleOf(sid),
                    status: store.sessionStatus(sid),
                    selected: sid == cur,
                    onTap: () {
                      HapticFeedback.selectionClick(); // §UX-8.2-2：切换会话 = .selection。
                      store.setCurrent(sid);
                    },
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
        height: 44, // §UX-10.2-1：触控目标高度合规
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentSoftOf(context)
              : AppColors.contentCanvasOf(context),
          border: Border.all(
            color: selected
                ? AppColors.accentOf(context).withValues(alpha: 0.42)
                : AppColors.hairlineOf(context),
            width: selected ? 1.2 : 1,
          ),
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
              constraints: const BoxConstraints(maxWidth: 96),
              child: Text(
                title,
                style: (selected ? AppText.calloutStrong : AppText.callout).copyWith(
                  color: selected
                      ? AppColors.textPrimaryOf(context)
                      : AppColors.placeholderOf(context),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 关闭按钮：视觉 13px 图标，命中区域 44×44（§UX-10.2-1）。
            Pressable(
              onTap: onClose,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Icon(
                    AppIcons.close,
                    size: 13,
                    color: selected
                        ? AppColors.textSecondaryOf(context)
                        : AppColors.placeholderOf(context),
                  ),
                ),
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
            Icon(AppIcons.bell, size: 14, color: AppColors.surfaceOf(context)),
            const SizedBox(width: 6),
            Text('$count',
                style: AppText.badge.copyWith(color: AppColors.surfaceOf(context))),
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
      backgroundColor: AppColors.backgroundOf(context),
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
                                  .copyWith(color: AppColors.textSecondaryOf(context))),
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
                                Icon(AppIcons.folder,
                                    size: 14, color: AppColors.textSecondaryOf(context)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(widget.store.titleOf(g.key),
                                      style: AppText.calloutStrong,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ),
                                Pressable(
                                  onTap: () =>
                                      widget.onPickSession(g.key),
                                  child: Text('切到该会话',
                                      style: AppText.caption.copyWith(
                                          color: AppColors.accentOf(context))),
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
    return HuxButton(
      onPressed: onTap ?? () {},
      variant: HuxButtonVariant.ghost,
      size: HuxButtonSize.small,
      icon: icon,
      child: const SizedBox(width: 0),
    );
  }
}