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

  /// 历史回放用：带完整字段的工具块（含状态与输出）。
  factory StreamBlock.toolResult({
    String? toolCallId,
    String? name,
    String? command,
    ToolStatus status = ToolStatus.done,
    String output = '',
  }) =>
      StreamBlock._(BlockKind.tool,
          toolCallId: toolCallId,
          toolName: name,
          command: command,
          status: status,
          output: output);
}

/// 将一整段会话汇总为纯文本，供「复制对话」按钮使用。
/// 顺序拼接 user / think / text / tool（命令 + 输出），跳过空内容。
String conversationText(List<StreamBlock> blocks) {
  final buf = StringBuffer();
  for (final b in blocks) {
    switch (b.kind) {
      case BlockKind.user:
        if (b.text.trim().isNotEmpty) {
          buf.writeln('用户：${b.text.trim()}');
          buf.writeln();
        }
      case BlockKind.think:
        if (b.text.trim().isNotEmpty) {
          buf.writeln('（思考）${b.text.trim()}');
          buf.writeln();
        }
      case BlockKind.text:
        if (b.text.trim().isNotEmpty) {
          buf.writeln(b.text.trim());
          buf.writeln();
        }
      case BlockKind.tool:
        final cmd = (b.command ?? '').trim();
        final out = b.output.trim();
        if (cmd.isNotEmpty) buf.writeln('工具命令：$cmd');
        if (out.isNotEmpty) buf.writeln('工具输出：$out');
        if (cmd.isNotEmpty || out.isNotEmpty) buf.writeln();
    }
  }
  return buf.toString().trim();
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
  /// 中继设定的超时截止时刻（ms since epoch）；缺失则由端兜底 5 分钟。
  final DateTime? deadline;

  const PermissionRequest({
    required this.permissionId,
    required this.sid,
    required this.title,
    required this.command,
    required this.options,
    this.deadline,
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
    DateTime? deadline;
    final dl = p['deadlineMs'];
    if (dl is num) {
      deadline = DateTime.fromMillisecondsSinceEpoch(dl.toInt());
    }
    return PermissionRequest(
      permissionId: p['permissionId'],
      sid: sid ?? '',
      title: tc['title']?.toString() ?? 'tool',
      command: extractToolText(tc),
      options: opts,
      deadline: deadline,
    );
  }
}

/// §10 3.4 二元风险：内置关键命令清单，命中=红、要确认；其余中性。
/// 不维护白名单——维护痛 ＞ 误判痛。
const criticalCommandPatterns = <String>[
  r'rm\s+-rf',
  r'sudo\b',
  r'git\s+push\s+(-f|--force)',
  r'git\s+reset\s+--hard',
  r'git\s+clean\s+-fd',
  r'curl\s+.*\|\s*(sh|bash)',
  r'wget\s+.*\|\s*(sh|bash)',
  r'\bdeploy\b',
  r'drop\s+(database|table)',
  r'truncate\s+table',
  r'>\s*~?/?\.ssh',
  r'chmod\s+-R',
  r'mkfs\b',
  r'\bdd\s+if=',
  r'\btruncate\b',
];

bool isCriticalCommand(String cmd) {
  if (cmd.isEmpty) return false;
  final lower = cmd.toLowerCase();
  return criticalCommandPatterns.any((p) => RegExp(p).hasMatch(lower));
}

/// 中继运行配置快照（relay.config 下行）。设置页据此展示/编辑真实值，
/// 避免"看着能改、实际没改"的假设置（诚实原则 §12）。
class RelayConfig {
  final bool barkEnabled;
  final String barkUrl;
  final int permTimeoutSeconds;
  final bool autoPassNonCritical;
  final String configPath;
  const RelayConfig({
    required this.barkEnabled,
    required this.barkUrl,
    required this.permTimeoutSeconds,
    required this.autoPassNonCritical,
    required this.configPath,
  });

  factory RelayConfig.fromPayload(Map<String, dynamic> p) => RelayConfig(
        barkEnabled: p['barkEnabled'] == true,
        barkUrl: p['barkUrl']?.toString() ?? '',
        permTimeoutSeconds: (p['permTimeoutSeconds'] as num?)?.toInt() ?? 300,
        autoPassNonCritical: p['autoPassNonCritical'] == true,
        configPath: p['configPath']?.toString() ?? '',
      );

  /// 乐观更新：config.set 发出后本地立即反映，回执（relay.config）再以真实值覆盖。
  RelayConfig copyWith({
    String? barkUrl,
    int? permTimeoutSeconds,
    bool? autoPassNonCritical,
  }) =>
      RelayConfig(
        barkEnabled: barkUrl != null ? barkUrl.isNotEmpty : barkEnabled,
        barkUrl: barkUrl ?? this.barkUrl,
        permTimeoutSeconds: permTimeoutSeconds ?? this.permTimeoutSeconds,
        autoPassNonCritical: autoPassNonCritical ?? this.autoPassNonCritical,
        configPath: configPath,
      );
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