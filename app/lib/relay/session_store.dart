import 'package:flutter/foundation.dart';
import 'models.dart';

/// 会话数据中心：把中继下行的流式 chunk 累积成块，按 sid 维护。
/// 这是 Phase 2 的核心——Kimi 的增量 update 在这里拼成可渲染的流。
class SessionStore extends ChangeNotifier {
  final Map<String, List<StreamBlock>> _streams = {};
  final Map<String, dynamic> _configs = {}; // sid -> configOptions
  final Map<String, List<dynamic>> _commands = {}; // sid -> slash commands
  final List<SessionMeta> _history = [];

  List<SessionMeta> get history => List.unmodifiable(_history);

  String? currentSid;
  PermissionRequest? pendingPermission;
  String relayState = 'connecting'; // connecting / ok / degraded
  String? lastError;

  List<StreamBlock> blocksOf(String? sid) {
    if (sid == null) return const [];
    return _streams.putIfAbsent(sid, () => []);
  }

  dynamic configOf(String? sid) => sid == null ? null : _configs[sid];
  List<dynamic> commandsOf(String? sid) =>
      sid == null ? const [] : (_commands[sid] ?? const []);

  /// 处理一条中继下行消息。
  void handle(String type, String? sid, Map<String, dynamic> payload) {
    switch (type) {
      case 'session.created':
        if (sid != null) {
          _streams.putIfAbsent(sid, () => []);
          if (payload['configOptions'] != null) {
            _configs[sid] = payload['configOptions'];
          }
          currentSid ??= sid;
        }
        notifyListeners();
      case 'session.update':
        if (sid != null) _applyUpdate(sid, payload);
        notifyListeners();
      case 'permission.request':
        pendingPermission = PermissionRequest.fromPayload(sid, payload);
        notifyListeners();
      case 'permission.invalidate':
        pendingPermission = null;
        notifyListeners();
      case 'relay.state':
        relayState = payload['state']?.toString() ?? 'ok';
        notifyListeners();
      case 'session.list':
        _history
          ..clear()
          ..addAll(((payload['sessions'] as List?) ?? [])
              .map((j) => SessionMeta.fromJson((j as Map).cast<String, dynamic>()))
              .toList());
        notifyListeners();
      case 'session.history':
        // 历史回放：用中继解析好的 blocks 重建该 sid 的流（这一刀验证页先不展开）
        notifyListeners();
      case 'relay.error':
        lastError = payload['message']?.toString();
        notifyListeners();
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
      // 不是增量 delta——绝不追加、也不显示，那是协议层流式细节。      case 'config_option_update':
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

  void setCurrent(String sid) {
    currentSid = sid;
    notifyListeners();
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