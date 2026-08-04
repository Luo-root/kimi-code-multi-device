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

/// 渲染分组：把连续的「思考 + 工具」块折叠成一个 AgentGroup，
/// 单块（user / text / 单独 tool）独立成 SingleBlockGroup。
/// 渲染时 AgentGroup 整体可折叠为「思考 >」，展开后展示思考文本 + 工具列表。
/// headIndex 是该 group 在原 blocks 列表中的首块索引；home_shell 用它把 group
/// 倒查回 blocks 索引以计算复制/轮起点。
sealed class AgentGroupItem {
  const AgentGroupItem();
  int get headIndex;
  List<StreamBlock> get blocks;
}

class SingleBlockGroup extends AgentGroupItem {
  final StreamBlock block;
  @override
  final int headIndex;
  const SingleBlockGroup(this.block, {required this.headIndex});
  @override
  List<StreamBlock> get blocks => [block];
}

class AgentGroup extends AgentGroupItem {
  /// 思考块 + 工具块任意顺序、连续出现（中间无 user/text）就归到同一组。
  /// 渲染时整组可折叠为一行「思考 + N 个工具」之类的标签，展开后按 parts 顺序
  /// 展示思考文本与工具行。
  final List<StreamBlock> parts;
  @override
  final int headIndex;
  AgentGroup(this.parts, {required this.headIndex});

  /// 所有思考块（去斜体的原文段落）。
  List<StreamBlock> get thinks =>
      parts.where((p) => p.kind == BlockKind.think).toList();
  /// 所有工具块。
  List<StreamBlock> get tools =>
      parts.where((p) => p.kind == BlockKind.tool).toList();
  int get thinkCount => thinks.length;
  int get toolCount => tools.length;

  /// 是否仍在流式追加：任一思考文本为空、任一工具未完成即视为进行中。
  bool get isRunning {
    if (thinks.any((t) => t.text.trim().isEmpty)) return true;
    return tools.any((t) =>
        t.status == ToolStatus.running ||
        t.status == ToolStatus.pending);
  }

  @override
  List<StreamBlock> get blocks => parts;
}

/// 把整轮 block 序列按相邻规则分组成 AgentGroupItem。
/// 规则（v2）：
/// - think / tool 任意顺序、连续出现都合并进同一个 AgentGroup；
/// - 遇到 user / text，先关闭当前 AgentGroup（若非空），再开新 SingleBlockGroup。
/// 这样「思考 + 工具」、「工具 + 思考」、「思考 + 工具 + 思考 + 工具」都会并成一组。
///
/// 收尾时若整组只有 1 个 part（单 think 或单 tool），自动降级为 SingleBlockGroup，
/// 避免出现「思考 › 思考 ›」的双层折叠嵌套——单 part 的 group 与其底层块完全等价。
List<AgentGroupItem> buildAgentGroups(List<StreamBlock> blocks) {
  final result = <AgentGroupItem>[];
  AgentGroup? group;

  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    switch (b.kind) {
      case BlockKind.think:
      case BlockKind.tool:
        final g = group;
        if (g != null) {
          g.parts.add(b);
        } else {
          group = AgentGroup([b], headIndex: i);
        }
      case BlockKind.user:
      case BlockKind.text:
        final g = group;
        if (g != null) {
          result.add(_finalizeGroup(g));
          group = null;
        }
        result.add(SingleBlockGroup(b, headIndex: i));
    }
  }
  final last = group;
  if (last != null) result.add(_finalizeGroup(last));
  return result;
}

/// 单 part 的 group 退化成 SingleBlockGroup，消除双重折叠标签。
AgentGroupItem _finalizeGroup(AgentGroup g) {
  if (g.parts.length == 1) {
    return SingleBlockGroup(g.parts.first, headIndex: g.headIndex);
  }
  return g;
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
///
/// 注：当前 kimi acp 不返回 archived / archivedAt / createdAt（见
/// test/probe/session_list_probe_test gap #1）。归档状态由端侧
/// SessionArchiveStore 维护，updatedAt 暂作为"创建/更新时间"近似。
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