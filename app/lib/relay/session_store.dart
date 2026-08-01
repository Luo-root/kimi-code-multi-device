import 'package:flutter/foundation.dart';
import 'models.dart';

/// 会话数据中心：把中继下行的流式 chunk 累积成块，按 sid 维护。
/// 这是 Phase 2 的核心——Kimi 的增量 update 在这里拼成可渲染的流。
///
/// 待批准按会话排队（§11 防串味）：每个 sid 一条独立队列，互不覆盖。
/// 角标 = 有待批准的会话数；切换器🟠 = 该会话队列非空。
class SessionStore extends ChangeNotifier {
  final Map<String, List<StreamBlock>> _streams = {};
  final Map<String, dynamic> _configs = {}; // sid -> configOptions
  final Map<String, List<dynamic>> _commands = {}; // sid -> slash commands
  final List<SessionMeta> _history = [];

  /// 活跃会话 sid（session.created 顺序，去重）。
  final List<String> _activeSids = [];
  List<String> get activeSids => List.unmodifiable(_activeSids);

  /// 按 sid 排队的待批准请求。Kimi 的 request_permission 同步阻塞，
  /// 单会话通常 0 或 1 条；多会话各自独立，故用 `Map<sid, List>`。
  final Map<String, List<PermissionRequest>> _pending = {};

  List<SessionMeta> get history => List.unmodifiable(_history);

  String? currentSid;
  String? lastError;
  DateTime? lastSyncedAt;

  // ---- 连接态（§12 诚实三态）----
  // WS 层与 kimi 健康分开：WS 断 = offline/connecting；WS 通但 kimi 死 = degraded。
  bool _wsConnected = false;
  bool _reconnecting = false;
  String _kimiHealth = 'ok'; // relay 报告：ok / degraded

  /// 派生连接态：ok / degraded / offline / connecting。
  String get relayState {
    if (!_wsConnected) return _reconnecting ? 'connecting' : 'offline';
    return _kimiHealth == 'degraded' ? 'degraded' : 'ok';
  }

  void markConnected() {
    _wsConnected = true;
    _reconnecting = false;
    _touchSynced();
    notifyListeners();
  }

  void markDisconnected({bool reconnecting = false}) {
    _wsConnected = false;
    _reconnecting = reconnecting;
    notifyListeners();
  }

  List<StreamBlock> blocksOf(String? sid) {
    if (sid == null) return const [];
    return _streams.putIfAbsent(sid, () => []);
  }

  dynamic configOf(String? sid) => sid == null ? null : _configs[sid];
  List<dynamic> commandsOf(String? sid) =>
      sid == null ? const [] : (_commands[sid] ?? const []);

  // ---- 待批准：按会话队列 ----

  /// 当前会话的待批准（队列首条）。底部浮层用它。
  PermissionRequest? pendingOf(String? sid) {
    if (sid == null) return null;
    final q = _pending[sid];
    return (q != null && q.isNotEmpty) ? q.first : null;
  }

  /// 全部待批准总数（跨会话）。角标用它。
  int get pendingCount =>
      _pending.values.fold(0, (n, q) => n + q.length);

  /// 有待批准的会话 sid 集合。切换器🟠用它。
  Set<String> get pendingSids =>
      _pending.entries.where((e) => e.value.isNotEmpty).map((e) => e.key).toSet();

  /// 全部待批准（供队列视图按 sid 分组）。
  Map<String, List<PermissionRequest>> get allPending =>
      Map.unmodifiable(_pending);

  /// 会话状态点：🟠待批准 优先，其次 🟢在跑，否则 idle（不显点）。
  /// 'pending' / 'running' / 'idle'
  String sessionStatus(String sid) {
    if ((_pending[sid]?.isNotEmpty) ?? false) return 'pending';
    final blocks = _streams[sid];
    if (blocks == null || blocks.isEmpty) return 'idle';
    final last = blocks.last;
    if (last.kind == BlockKind.tool) {
      return (last.status == ToolStatus.running ||
              last.status == ToolStatus.pending)
          ? 'running'
          : 'idle';
    }
    // think / text 末块视为正在流式产出。
    return (last.kind == BlockKind.think || last.kind == BlockKind.text)
        ? 'running'
        : 'idle';
  }

  /// 处理一条中继下行消息。
  void handle(String type, String? sid, Map<String, dynamic> payload) {
    switch (type) {
      case 'session.created':
        if (sid != null) {
          _streams.putIfAbsent(sid, () => []);
          if (payload['configOptions'] != null) {
            _configs[sid] = payload['configOptions'];
          }
          if (!_activeSids.contains(sid)) _activeSids.add(sid);
          currentSid ??= sid;
        }
        notifyListeners();
      case 'session.update':
        if (sid != null) _applyUpdate(sid, payload);
        _touchSynced();
        notifyListeners();
      case 'permission.request':
        if (sid != null) {
          final req = PermissionRequest.fromPayload(sid, payload);
          _pending.putIfAbsent(sid, () => []).add(req);
        }
        notifyListeners();
      case 'permission.invalidate':
        _pending.clear();
        notifyListeners();
      case 'relay.state':
        _kimiHealth = payload['state']?.toString() ?? 'ok';
        if (_kimiHealth == 'ok') _touchSynced();
        notifyListeners();
      case 'session.list':
        _history
          ..clear()
          ..addAll(((payload['sessions'] as List?) ?? [])
              .map((j) => SessionMeta.fromJson((j as Map).cast<String, dynamic>()))
              .toList());
        notifyListeners();
      case 'session.history':
        // 历史回放：用中继解析好的 blocks 重建该 sid 的流。
        if (sid != null) {
          final list = (payload['blocks'] as List?) ?? [];
          _streams[sid] = list
              .map((b) => _blockFromHistory((b as Map).cast<String, dynamic>()))
              .toList();
          if (!_activeSids.contains(sid)) _activeSids.add(sid);
        }
        notifyListeners();
      case 'relay.error':
        lastError = payload['message']?.toString();
        notifyListeners();
    }
  }

  void _touchSynced() => lastSyncedAt = DateTime.now();

  /// 从历史回放 block 构造 StreamBlock（只读历史流）。
  StreamBlock _blockFromHistory(Map<String, dynamic> b) {
    switch (b['kind']) {
      case 'user':
        return StreamBlock.user(b['text']?.toString() ?? '');
      case 'think':
        return StreamBlock.think(b['text']?.toString() ?? '');
      case 'text':
        return StreamBlock.text(b['text']?.toString() ?? '');
      case 'tool':
        final st = b['output'] != null && (b['output'] as String).isNotEmpty
            ? ToolStatus.done
            : ToolStatus.pending;
        return StreamBlock.toolResult(
          toolCallId: b['toolCallId']?.toString(),
          name: b['toolName']?.toString(),
          command: b['command']?.toString(),
          status: st,
          output: b['output']?.toString() ?? '',
        );
      default:
        return StreamBlock.text(b['text']?.toString() ?? '');
    }
  }

  void _applyUpdate(String sid, Map<String, dynamic> u) {
    final blocks = blocksOf(sid);
    switch (u['sessionUpdate']) {
      case 'agent_thought_chunk':
        final t = _chunkText(u);
        if (t.isEmpty) break;
        if (blocks.isNotEmpty && blocks.last.kind == BlockKind.think) {
          blocks.last.text += t;
        } else {
          blocks.add(StreamBlock.think(t));
        }
      case 'agent_message_chunk':
        final t = _chunkText(u);
        if (blocks.isNotEmpty && blocks.last.kind == BlockKind.text) {
          blocks.last.text += t;
        } else {
          blocks.add(StreamBlock.text(t));
        }
      case 'tool_call':
        blocks.add(StreamBlock.tool(
          toolCallId: u['toolCallId']?.toString(),
          name: u['title']?.toString(),
          command: extractToolText(u),
        ));
      case 'tool_call_update':
        final id = u['toolCallId']?.toString();
        final blk = _findTool(blocks, id);
        if (blk == null) break;
        blk.status = _status(u['status']?.toString());
        // 命令：rawInput.command 在命令流完后出现（结构化、最准）。
        final rawIn = (u['rawInput'] as Map?)?.cast<String, dynamic>();
        if (rawIn != null && rawIn['command'] != null) {
          blk.command = rawIn['command'].toString();
        }
        // 兜底：in_progress 带 "Running: xxx" 标题时，截出命令预览。
        if (blk.command == null || blk.command!.isEmpty) {
          final title = u['title']?.toString() ?? '';
          const prefix = 'Running: ';
          if (title.startsWith(prefix)) {
            blk.command = title.substring(prefix.length);
          }
        }
        // 输出：completed / failed 时取 rawOutput。
        if (u['rawOutput'] != null) {
          blk.output = u['rawOutput'].toString();
        }
        // 关键：in_progress 的 content.text 是「命令 JSON 的累积快照」，
        // 不是增量 delta——绝不追加、也不显示，那是协议层流式细节。
      case 'config_option_update':
        _configs[sid] = u['configOptions'];
      case 'available_commands_update':
        _commands[sid] = (u['availableCommands'] as List?) ?? [];
    }
  }

  /// 乐观更新某会话的某个 config 选项当前值（下发 set 后立即反映到 UI）。
  void applyConfigOption(String? sid, String configId, String value) {
    if (sid == null) return;
    final cfg = _configs[sid];
    if (cfg is List) {
      for (final c in cfg) {
        if (c is Map && c['id'] == configId) c['currentValue'] = value;
      }
    }
    notifyListeners();
  }

  /// 用户发送：本地乐观追加 user 块（Kimi 的 update 流不回显用户消息）。
  void addUser(String sid, String text) {
    blocksOf(sid).add(StreamBlock.user(text));
    notifyListeners();
  }

  /// 用户已对该批准拍板：从队列移除（乐观，Kimi 随后推 tool_call_update）。
  void resolvePermission(PermissionRequest req) {
    final q = _pending[req.sid];
    if (q != null) {
      q.removeWhere((p) => p.permissionId == req.permissionId);
      if (q.isEmpty) _pending.remove(req.sid);
    }
    notifyListeners();
  }

  void setCurrent(String sid) {
    currentSid = sid;
    if (!_activeSids.contains(sid)) _activeSids.add(sid);
    notifyListeners();
  }

  /// 会话显示名：优先历史标题，否则取 sid 前缀。
  String titleOf(String sid) {
    for (final m in _history) {
      if (m.sessionId == sid) {
        return m.title.isEmpty ? '（无标题）' : m.title;
      }
    }
    final short = sid.length > 6 ? sid.substring(0, 6) : sid;
    return '会话 $short';
  }

  // ---- helpers ----

  String _chunkText(Map<String, dynamic> u) {
    final c = (u['content'] as Map?)?.cast<String, dynamic>();
    return c?['text']?.toString() ?? '';
  }

  ToolStatus _status(String? s) {
    switch (s) {
      case 'in_progress':
        return ToolStatus.running;
      case 'completed':
        return ToolStatus.done;
      case 'failed':
        return ToolStatus.failed;
      default:
        return ToolStatus.pending;
    }
  }

  StreamBlock? _findTool(List<StreamBlock> blocks, String? id) {
    for (var i = blocks.length - 1; i >= 0; i--) {
      if (blocks[i].kind == BlockKind.tool && blocks[i].toolCallId == id) {
        return blocks[i];
      }
    }
    return null;
  }
}
