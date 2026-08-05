import 'dart:convert';

/// 流块类型。
enum BlockKind { user, think, text, tool }

/// 工具调用状态。
enum ToolStatus { pending, running, done, failed, cancelled }

/// Edit 差异行的语义类型。修改行同时保留旧值与新值，避免只靠颜色猜含义。
enum EditDiffKind { context, added, removed, modified }

class EditDiffLine {
  final EditDiffKind kind;
  final String text;
  final String? secondaryText;
  final int? oldLine;
  final int? newLine;

  const EditDiffLine({
    required this.kind,
    required this.text,
    this.secondaryText,
    this.oldLine,
    this.newLine,
  });

  bool get isModified => kind == EditDiffKind.modified;
}

class EditDiff {
  final String? filePath;
  final List<EditDiffLine> lines;
  final int additions;
  final int removals;
  final int modifications;

  const EditDiff({
    this.filePath,
    this.lines = const [],
    this.additions = 0,
    this.removals = 0,
    this.modifications = 0,
  });

  bool get isEmpty => lines.isEmpty;
}

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
  factory StreamBlock.tool({
    String? toolCallId,
    String? name,
    String? command,
  }) => StreamBlock._(
    BlockKind.tool,
    toolCallId: toolCallId,
    toolName: name,
    command: command,
  );

  /// 历史回放用：带完整字段的工具块（含状态与输出）。
  factory StreamBlock.toolResult({
    String? toolCallId,
    String? name,
    String? command,
    ToolStatus status = ToolStatus.done,
    String output = '',
  }) => StreamBlock._(
    BlockKind.tool,
    toolCallId: toolCallId,
    toolName: name,
    command: command,
    status: status,
    output: output,
  );
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
    return tools.any(
      (t) => t.status == ToolStatus.running || t.status == ToolStatus.pending,
    );
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

  /// 关键命令判定：relay 经 permission.request 下发（risk.IsCritical 计算），
  /// app 直接消费，不再自算。
  final bool critical;

  /// 中继设定的超时截止时刻（ms since epoch）；缺失则由端兜底 5 分钟。
  final DateTime? deadline;

  const PermissionRequest({
    required this.permissionId,
    required this.sid,
    required this.title,
    required this.command,
    required this.options,
    required this.critical,
    this.deadline,
  });

  factory PermissionRequest.fromPayload(String? sid, Map<String, dynamic> p) {
    final tc = (p['toolCall'] as Map?)?.cast<String, dynamic>() ?? {};
    final opts = ((p['options'] as List?) ?? [])
        .map(
          (o) => PermOption(
            optionId: (o as Map)['optionId']?.toString() ?? '',
            name: o['name']?.toString(),
            kind: o['kind']?.toString() ?? '',
          ),
        )
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
      critical: p['critical'] == true,
      deadline: deadline,
    );
  }
}

/// 中继运行配置快照（relay.config 下行）。设置页据此展示/编辑真实值，
/// 避免"看着能改、实际没改"的假设置（诚实原则 §12）。
class RelayConfig {
  final String barkUrl;
  final int permTimeoutSeconds;
  final bool autoPassNonCritical;
  final String configPath;
  const RelayConfig({
    required this.barkUrl,
    required this.permTimeoutSeconds,
    required this.autoPassNonCritical,
    required this.configPath,
  });

  factory RelayConfig.fromPayload(Map<String, dynamic> p) => RelayConfig(
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
  }) => RelayConfig(
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

/// 从 Edit 的 command/output 中提取可展示的行级差异。
///
/// relay 当前统一保存 command 与 output，因此这里兼容三类常见形态：
/// 1. JSON 的 path + old_string/new_string；2. unified diff；3. 纯文本降级。
/// 解析失败时返回空 diff，调用方仍应展示原始输入/输出，不丢失信息。
EditDiff parseEditDiff(String? command, String output) {
  final sources = [
    command ?? '',
    output,
  ].where((s) => s.trim().isNotEmpty).toList();
  for (final source in sources) {
    final parsed = _parseEditJson(source);
    if (parsed != null && !parsed.isEmpty) return parsed;
    final unified = _parseUnifiedDiff(source);
    if (unified != null && !unified.isEmpty) return unified;
  }
  return const EditDiff();
}

EditDiff? _parseEditJson(String source) {
  dynamic decoded;
  try {
    decoded = jsonDecode(source);
  } catch (_) {
    return null;
  }
  final map = decoded is Map ? decoded.cast<String, dynamic>() : null;
  if (map == null) return null;
  final oldText = _firstString(map, const <String>[
    'old_string', 'oldString', 'old_text', 'oldText',
    'before', 'find', 'search', 'search_text', 'searchText',
    'match', 'match_text', 'matchText', 'original', 'source',
    'from', 'old_content', 'oldContent', 'previous', 'prev',
  ]);
  final newText = _firstString(map, const <String>[
    'new_string', 'newString', 'new_text', 'newText',
    'after', 'replace', 'replacement', 'substitute',
    'new_content', 'newContent', 'replacement_text', 'replacementText',
    'to', 'destination', 'target_text', 'targetText', 'next',
  ]);
  if (oldText == null || newText == null) return null;
  return _diffTexts(
    oldText,
    newText,
    filePath: _firstString(map, const <String>[
      'file_path', 'filePath', 'filepath', 'path', 'filename',
      'file', 'uri', 'target', 'name', 'target_file', 'targetFile',
    ]),
  );
}

String? _firstString(
  Map<String, dynamic> map,
  List<String> keys, {
  int depth = 0,
}) {
  if (depth > 3) return null;
  for (final key in keys) {
    final value = map[key];
    if (value is String) return value;
  }
  for (final value in map.values) {
    if (value is Map) {
      final nested = _firstString(
        value.cast<String, dynamic>(),
        keys,
        depth: depth + 1,
      );
      if (nested != null) return nested;
    }
  }
  return null;
}

EditDiff? _parseUnifiedDiff(String source) {
  final rawLines = source.replaceAll('\r\n', '\n').split('\n');
  final hasPatchMarker = rawLines.any(
    (line) =>
        line.startsWith('@@ ') ||
        line.startsWith('diff --git ') ||
        line.startsWith('--- ') ||
        line.startsWith('+++ '),
  );
  final hasChange = rawLines.any(
    (line) =>
        line.startsWith('+') && !line.startsWith('+++') ||
        line.startsWith('-') && !line.startsWith('---'),
  );
  if (!hasPatchMarker || !hasChange) return null;

  final lines = <EditDiffLine>[];
  var oldLine = 0;
  var newLine = 0;
  String? filePath;
  for (final line in rawLines) {
    if (line.startsWith('+++ ')) {
      filePath = line.substring(4).trim();
      if (filePath.startsWith('b/')) filePath = filePath.substring(2);
      continue;
    }
    if (line.startsWith('@@ ')) {
      final match = RegExp(r'@@ -(\d+)(?:,\d+)? \+(\d+)').firstMatch(line);
      if (match != null) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
      }
      continue;
    }
    if (line.startsWith('--- ') ||
        line.startsWith('diff --git ') ||
        line == '\\ No newline at end of file') {
      continue;
    }
    if (line.startsWith('+')) {
      lines.add(
        EditDiffLine(
          kind: EditDiffKind.added,
          text: line.substring(1),
          newLine: newLine++,
        ),
      );
    } else if (line.startsWith('-')) {
      lines.add(
        EditDiffLine(
          kind: EditDiffKind.removed,
          text: line.substring(1),
          oldLine: oldLine++,
        ),
      );
    } else if (line.startsWith(' ')) {
      lines.add(
        EditDiffLine(
          kind: EditDiffKind.context,
          text: line.substring(1),
          oldLine: oldLine++,
          newLine: newLine++,
        ),
      );
    }
  }
  final normalized = _pairModifiedLines(lines);
  return EditDiff(
    filePath: filePath,
    lines: normalized,
    additions: normalized.where((l) => l.kind == EditDiffKind.added).length,
    removals: normalized.where((l) => l.kind == EditDiffKind.removed).length,
    modifications: normalized
        .where((l) => l.kind == EditDiffKind.modified)
        .length,
  );
}

EditDiff _diffTexts(String oldText, String newText, {String? filePath}) {
  final oldLines = _splitLines(oldText);
  final newLines = _splitLines(newText);
  final rows = oldLines.length + 1;
  final cols = newLines.length + 1;
  final lcs = List.generate(rows, (_) => List<int>.filled(cols, 0));
  for (var i = oldLines.length - 1; i >= 0; i--) {
    for (var j = newLines.length - 1; j >= 0; j--) {
      lcs[i][j] = oldLines[i] == newLines[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] > lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final lines = <EditDiffLine>[];
  var i = 0;
  var j = 0;
  var oldNo = 1;
  var newNo = 1;
  while (i < oldLines.length && j < newLines.length) {
    if (oldLines[i] == newLines[j]) {
      lines.add(
        EditDiffLine(
          kind: EditDiffKind.context,
          text: oldLines[i],
          oldLine: oldNo++,
          newLine: newNo++,
        ),
      );
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      lines.add(
        EditDiffLine(
          kind: EditDiffKind.removed,
          text: oldLines[i++],
          oldLine: oldNo++,
        ),
      );
    } else {
      lines.add(
        EditDiffLine(
          kind: EditDiffKind.added,
          text: newLines[j++],
          newLine: newNo++,
        ),
      );
    }
  }
  while (i < oldLines.length) {
    lines.add(
      EditDiffLine(
        kind: EditDiffKind.removed,
        text: oldLines[i++],
        oldLine: oldNo++,
      ),
    );
  }
  while (j < newLines.length) {
    lines.add(
      EditDiffLine(
        kind: EditDiffKind.added,
        text: newLines[j++],
        newLine: newNo++,
      ),
    );
  }
  final normalized = _pairModifiedLines(lines);
  return EditDiff(
    filePath: filePath,
    lines: normalized,
    additions: normalized.where((l) => l.kind == EditDiffKind.added).length,
    removals: normalized.where((l) => l.kind == EditDiffKind.removed).length,
    modifications: normalized
        .where((l) => l.kind == EditDiffKind.modified)
        .length,
  );
}

List<String> _splitLines(String value) =>
    value.replaceAll('\r\n', '\n').split('\n');

/// 相邻的删除 + 新增视为一次修改，仍保留两侧原文。
List<EditDiffLine> _pairModifiedLines(List<EditDiffLine> source) {
  final result = <EditDiffLine>[];
  var i = 0;
  while (i < source.length) {
    if (i + 1 < source.length &&
        source[i].kind == EditDiffKind.removed &&
        source[i + 1].kind == EditDiffKind.added) {
      final removed = source[i];
      final added = source[i + 1];
      result.add(
        EditDiffLine(
          kind: EditDiffKind.modified,
          text: removed.text,
          secondaryText: added.text,
          oldLine: removed.oldLine,
          newLine: added.newLine,
        ),
      );
      i += 2;
    } else {
      result.add(source[i]);
      i++;
    }
  }
  return result;
}

/// 从 tool_call / toolCall 结构里提取命令文本（兼容多种字段）。
String extractToolText(Map<String, dynamic> tc) {
  // 0) rawInput 是字符串：可能是 Edit 序列化的 JSON 整体。
  final rawAny = tc['rawInput'];
  if (rawAny is String && rawAny.trim().startsWith('{')) {
    return rawAny;
  }
  final raw = rawAny is Map ? rawAny.cast<String, dynamic>() : null;
  // 1) rawInput.command（Bash 等结构化、最准）。
  if (raw != null && raw['command'] is String) {
    return _stripCmdPrefix(raw['command'] as String);
  }
  // 2) Edit：rawInput 含旧/新字符串键即按结构识别（不再只依赖标题字符串）。
  if (raw != null && looksLikeEditInput(raw)) {
    try {
      return jsonEncode(raw);
    } catch (_) {
      return raw.toString();
    }
  }
  // 3) Edit 标题兜底（容忍大小写、连字符、前后空格）。
  if (raw != null && looksLikeEditTitle(tc['title']?.toString())) {
    try {
      return jsonEncode(raw);
    } catch (_) {
      return raw.toString();
    }
  }
  // 4) content[].content.text 或 content[].text
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

/// rawInput 是否呈现 Edit 工具的形态（含旧/新字符串键）。
///
/// 公开给 session_store 等其他模块复用。最多向下递归两层。
bool looksLikeEditInput(dynamic rawInput) {
  if (rawInput is! Map) return false;
  return _containsEditKey(rawInput, 0);
}

bool _containsEditKey(Map map, int depth) {
  if (depth > 2) return false;
  const keys = {
    'old_string', 'oldString', 'old_text', 'oldText', 'before',
    'new_string', 'newString', 'new_text', 'newText', 'after',
    'replace', 'substitute', 'replacement',
  };
  for (final entry in map.entries) {
    final key = entry.key.toString();
    final value = entry.value;
    if (keys.contains(key) && value is String && value.isNotEmpty) return true;
    if (value is Map && _containsEditKey(value, depth + 1)) return true;
  }
  return false;
}

/// 标题是否指 Edit 工具（容忍大小写与常见变体）。
bool looksLikeEditTitle(String? title) {
  if (title == null) return false;
  final t = title.trim().toLowerCase();
  if (t.isEmpty) return false;
  return t == 'edit' ||
      t == 'editfile' ||
      t == 'edit_file' ||
      t.startsWith('edit ') ||
      t.endsWith(' edit') ||
      t.contains('editfile') ||
      t.contains('edit_file');
}

/// 剥掉 Kimi 在命令文本前加的口语前缀。
String _stripCmdPrefix(String s) {
  const markers = ['Requesting approval to Running: ', 'Running: '];
  for (final m in markers) {
    if (s.startsWith(m)) return s.substring(m.length);
  }
  return s;
}
