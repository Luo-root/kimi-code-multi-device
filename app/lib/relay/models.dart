/// 流块类型。
enum BlockKind { user, think, text, tool }

/// 工具调用状态。
enum ToolStatus { pending, running, done, failed }

/// 流里的一个内容块。流式累积，字段可变。
class StreamBlock {
  final BlockKind kind;
  String text; // user / think / text
  // tool 专用
  String? toolCallId;
  String? toolName;
  String? command;
  ToolStatus status;
  String output; // 工具最终输出

  StreamBlock._(
    this.kind, {
    this.text = '',
    this.toolCallId,
    this.toolName,
    this.command,
    this.status = ToolStatus.pending,
    this.output = '',
  });

  factory StreamBlock.user(String t) => StreamBlock._(BlockKind.user, text: t);
  factory StreamBlock.think(String t) =>
      StreamBlock._(BlockKind.think, text: t);
  factory StreamBlock.text(String t) => StreamBlock._(BlockKind.text, text: t);
  factory StreamBlock.tool({String? toolCallId, String? name, String? command}) =>
      StreamBlock._(BlockKind.tool,
          toolCallId: toolCallId, toolName: name, command: command);
}

/// 批准请求的一个选项。
class PermOption {
  final String optionId;
  final String? name;
  final String kind; // allow_once / allow_always / reject_once
  const PermOption({required this.optionId, this.name, required this.kind});
}

/// 一次批准请求（来自中继 permission.request）。
class PermissionRequest {
  final dynamic permissionId; // Kimi 的 request id，原样回传
  final String sid;
  final String title;
  final String command;
  final List<PermOption> options;

  const PermissionRequest({
    required this.permissionId,
    required this.sid,
    required this.title,
    required this.command,
    required this.options,
  });

  factory PermissionRequest.fromPayload(String? sid, Map<String, dynamic> p) {
    final tc = (p['toolCall'] as Map?)?.cast<String, dynamic>() ?? {};
    final opts = ((p['options'] as List?) ?? [])
        .map((o) => PermOption(
              optionId: (o as Map)['optionId']?.toString() ?? '',
              name: o['name']?.toString(),
              kind: o['kind']?.toString() ?? '',
            ))
        .toList();
    return PermissionRequest(
      permissionId: p['permissionId'],
      sid: sid ?? '',
      title: tc['title']?.toString() ?? 'tool',
      command: extractToolText(tc),
      options: opts,
    );
  }
}

/// 会话元信息（来自 session.list）。
class SessionMeta {
  final String sessionId;
  final String cwd;
  final String title;
  final String updatedAt;
  const SessionMeta({
    required this.sessionId,
    required this.cwd,
    required this.title,
    required this.updatedAt,
  });

  factory SessionMeta.fromJson(Map<String, dynamic> j) => SessionMeta(
        sessionId: j['sessionId']?.toString() ?? '',
        cwd: j['cwd']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        updatedAt: j['updatedAt']?.toString() ?? '',
      );
}

/// 从 tool_call / toolCall 结构里提取命令文本（兼容多种字段）。
String extractToolText(Map<String, dynamic> tc) {
  // 1) rawInput.command（结构化、最准）
  final raw = (tc['rawInput'] as Map?)?.cast<String, dynamic>();
  if (raw != null && raw['command'] != null) {
    return _stripCmdPrefix(raw['command'].toString());
  }
  // 2) content[].content.text 或 content[].text
  final content = tc['content'] as List?;
  if (content != null) {
    final buf = StringBuffer();
    for (final c in content) {
      final m = (c as Map?)?.cast<String, dynamic>();
      if (m == null) continue;
      final inner = (m['content'] as Map?)?.cast<String, dynamic>();
      final t = inner?['text']?.toString() ?? m['text']?.toString();
      if (t != null) buf.write(t);
    }
    if (buf.isNotEmpty) return _stripCmdPrefix(buf.toString());
  }
  return '';
}

/// 剥掉 Kimi 在命令文本前加的口语前缀。
String _stripCmdPrefix(String s) {
  const markers = ['Requesting approval to Running: ', 'Running: '];
  for (final m in markers) {
    if (s.startsWith(m)) return s.substring(m.length);
  }
  return s;
}