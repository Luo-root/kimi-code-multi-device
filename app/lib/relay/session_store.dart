import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'manage_messages.dart';
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

  /// 每会话 busy：session/prompt 进行中（AI 还在输出）。中继下发 session.busy。
  final Map<String, bool> _busy = {};

  /// 该会话是否在跑（AI 还没输出完）——驱动「停」可见性与 running 状态点。
  bool busyOf(String? sid) => sid != null && _busy[sid] == true;

  /// 本地发送/取消时的即时状态更新。
  ///
  /// 中继随后仍会下发权威的 `session.busy` 覆盖它；这里仅用于消除
  /// prompt 发出到 busy 事件到达之间的 UI 空窗，避免 stop 按钮晚出现。
  void setBusy(String sid, bool busy) {
    if (_busy[sid] == busy) return;
    _busy[sid] = busy;
    notifyListeners();
  }

  List<SessionMeta> get history => List.unmodifiable(_history);

  String? currentSid;
  String? lastError;
  /// 最近一次会话管理操作回执（下行 session.managed）。供 UI 弹 toast 反馈
  /// 成功/失败。每次收到新回执都赋新实例，UI 端用 identical 去重。
  ManagedResult? lastManaged;
  DateTime? lastSyncedAt;

  /// 中继运行配置快照（relay.config 下行），设置页展示真实值。
  RelayConfig? _relayConfig;
  RelayConfig? get relayConfig => _relayConfig;

  /// 乐观应用端侧发起的配置修改（config.set）。回执 relay.config 会以真实值覆盖。
  void applyRelayConfig(Map<String, dynamic> patch) {
    final cur = _relayConfig;
    if (cur == null) return;
    _relayConfig = cur.copyWith(
      barkUrl: patch['barkUrl'] as String?,
      permTimeoutSeconds: (patch['permTimeoutSeconds'] as num?)?.toInt(),
      autoPassNonCritical: patch['autoPassNonCritical'] as bool?,
    );
    notifyListeners();
  }

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
  int get pendingCount => _pending.values.fold(0, (n, q) => n + q.length);

  /// 有待批准的会话 sid 集合。切换器🟠用它。
  Set<String> get pendingSids => _pending.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => e.key)
      .toSet();

  /// 全部待批准（供队列视图按 sid 分组）。
  Map<String, List<PermissionRequest>> get allPending =>
      Map.unmodifiable(_pending);

  /// 会话状态点：🟠待批准 优先，其次 🟢在跑（busy），否则 idle（不显点）。
  /// 'pending' / 'running' / 'idle'
  String sessionStatus(String sid) {
    if ((_pending[sid]?.isNotEmpty) ?? false) return 'pending';
    if (_busy[sid] == true) return 'running';
    return 'idle';
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
      case 'session.busy':
        if (sid != null) _busy[sid] = payload['busy'] == true;
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
      case 'session.closed':
        if (sid != null) {
          _activeSids.remove(sid);
          if (currentSid == sid) {
            currentSid = _activeSids.isNotEmpty ? _activeSids.last : null;
          }
        }
        notifyListeners();
      case 'relay.state':
        _kimiHealth = payload['state']?.toString() ?? 'ok';
        if (_kimiHealth == 'ok') _touchSynced();
        notifyListeners();
      case 'session.list':
        _history
          ..clear()
          ..addAll(
            ((payload['sessions'] as List?) ?? [])
                .map(
                  (j) =>
                      SessionMeta.fromJson((j as Map).cast<String, dynamic>()),
                )
                .toList(),
          );
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
      case 'relay.config':
        _relayConfig = RelayConfig.fromPayload(payload);
        notifyListeners();
      case 'relay.error':
        lastError = payload['message']?.toString();
        notifyListeners();
      case kDownSessionManaged:
        // 通道②：会话管理操作（archive/rename/fork/delete/restore/export）回执。
        // 解析失败（缺 action/sessionId）时置 null，UI 不弹 toast。
        lastManaged = ManagedResult.fromPayload(payload);
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
        blocks.add(
          StreamBlock.tool(
            toolCallId: u['toolCallId']?.toString(),
            name: u['title']?.toString(),
            command: extractToolText(u),
          ),
        );
      case 'tool_call_update':
        final id = u['toolCallId']?.toString();
        final blk = _findTool(blocks, id);
        if (blk == null) break;
        blk.status = _status(u['status']?.toString());
        // 输入：Bash 优先 rawInput.command；Edit 等结构化工具保留完整 JSON，
        // 让历史与完成态都能重建行级 diff 和变更摘要。
        final rawInAny = u['rawInput'];
        if (rawInAny is String && rawInAny.trim().startsWith('{')) {
          blk.command = rawInAny;
        } else if (rawInAny is Map) {
          final rawIn = rawInAny.cast<String, dynamic>();
          if (rawIn['command'] is String) {
            blk.command = rawIn['command'].toString();
          } else if (looksLikeEditInput(rawIn) ||
              looksLikeEditTitle(blk.toolName)) {
            blk.command = _encodeToolInput(rawIn);
          }
        }
        // Kimi ACP 的 in_progress content.text 是「工具参数 JSON 的累积快照」，
        // 不是输出也不是 delta。rawInput 往往只在完成态出现，Edit 必须在这里
        // 先保存完整 JSON；否则完成后只剩 rawOutput 的 "Replaced ..."，无法构造 diff。
        final contentSnapshot = _toolInputSnapshot(u);
        if (contentSnapshot != null &&
            (looksLikeEditTitle(blk.toolName) ||
                _looksLikeEditJson(contentSnapshot))) {
          blk.command = contentSnapshot;
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

  /// 关闭一个活跃会话（来自顶部切换器的 × 按钮，乐观移除）。
  /// 中继随后推 session.closed 时再做一次幂等移除。
  void removeActive(String sid) {
    if (!_activeSids.contains(sid)) return;
    _activeSids.remove(sid);
    if (currentSid == sid) {
      currentSid = _activeSids.isNotEmpty ? _activeSids.last : null;
    }
    notifyListeners();
  }

  /// 彻底移除一个会话（来自 direct-storage 删除成功后的回执）。
  /// 同时清掉活跃态与历史表，抽屉列表据此即时消失，无需等待重连。
  void removeSession(String sid) {
    final had = _history.any((m) => m.sessionId == sid);
    _history.removeWhere((m) => m.sessionId == sid);
    _activeSids.remove(sid);
    if (currentSid == sid) {
      currentSid = _activeSids.isNotEmpty ? _activeSids.last : null;
    }
    if (had || _activeSids.contains(sid)) notifyListeners();
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

  String _encodeToolInput(Map<String, dynamic> value) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }

  /// tool_call_update.content 可能是 `{type:text,text:<累计 JSON>}`，也可能
  /// 是 ACP content-block 数组。只返回完整可解析的 JSON 快照，绝不拼接 delta。
  String? _toolInputSnapshot(Map<String, dynamic> update) {
    final content = update['content'];
    String? text;
    if (content is Map) {
      text = content['text']?.toString();
    } else if (content is List) {
      final buffer = StringBuffer();
      for (final item in content) {
        if (item is! Map) continue;
        final inner = item['content'];
        final part = inner is Map
            ? inner['text']?.toString()
            : item['text']?.toString();
        if (part != null) buffer.write(part);
      }
      if (buffer.isNotEmpty) text = buffer.toString();
    }
    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty || !trimmed.startsWith('{')) {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map ? trimmed : null;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeEditJson(String source) {
    try {
      return looksLikeEditInput(jsonDecode(source));
    } catch (_) {
      return false;
    }
  }

  ToolStatus _status(String? s) {
    switch (s) {
      case 'in_progress':
        return ToolStatus.running;
      case 'completed':
        return ToolStatus.done;
      case 'failed':
        return ToolStatus.failed;
      case 'cancelled':
      case 'canceled':
      case 'cancel':
        return ToolStatus.cancelled;
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
