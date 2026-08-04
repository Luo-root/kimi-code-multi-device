import 'package:flutter/material.dart';
import '../relay/models.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_icons.dart';
import '../widgets/common.dart';
import 'markdown.dart';
import 'generating.dart';

/// 渲染一个流块。home_shell 与验证页共用。
class StreamBlockView extends StatefulWidget {
  final StreamBlock block;
  /// 是否为当前正在流式追加的末块（用于尾部光标 / 思考中态）。§3 生成状态动效。
  final bool streaming;
  const StreamBlockView({super.key, required this.block, this.streaming = false});

  @override
  State<StreamBlockView> createState() => _StreamBlockViewState();
}

class _StreamBlockViewState extends State<StreamBlockView> {
  bool _open = false; // think / tool 折叠态
  bool _thinkHover = false; // think 触发区 hover
  bool _toolHover = false; // tool 触发区 hover

  @override
  Widget build(BuildContext context) {
    switch (widget.block.kind) {
      case BlockKind.user:
        return _user();
      case BlockKind.think:
        return _think();
      case BlockKind.text:
        // AI 输出按 Markdown 渲染（标题/加粗/行内码/代码块/列表…）。
        return _textBlock();
      case BlockKind.tool:
        return _tool();
    }
  }

  Widget _textBlock() {
    final streaming = widget.streaming;
    return Row(
      // 流式时光标落在底部右侧，读作「正在输入」；非流式保持原顶对齐。
      crossAxisAlignment:
          streaming ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Expanded(child: MarkdownView(data: widget.block.text)),
        if (streaming) const BlinkingCursor(),
      ],
    );
  }

  /// §UX-2.2：用户气泡不带复制按钮（自己发的话无需复制入口）。
  Widget _user() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              // 用户消息只需轻微区别于纯白内容画布，不再使用更重的选中态淡底。
              color: AppColors.quietSurfaceOf(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(widget.block.text, style: AppText.body),
          ),
        ),
      ],
    );
  }

  Widget _think() {
    final streaming = widget.streaming;
    // 触发态：默认 placeholder 浅银灰，鼠标 hover 变 textPrimary 黑；
    // chevron 与文字色同步切换。展开内容去掉 italic，正常字重。
    // 触发区自然宽度：mainAxisSize.min + chevron 在文字右侧；折叠态不画竖杠、紧凑。
    // 展开用 Collapsible（SizeTransition + 淡入下滑），与模型切换同款 slide+fade，无翻页闪烁。
    final triggerColor = _thinkHover
        ? AppColors.textPrimaryOf(context)
        : AppColors.placeholderOf(context);
    final trigger = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _thinkHover = true),
      onExit: (_) => setState(() => _thinkHover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(streaming ? '思考中…' : '思考',
                  style: AppText.callout.copyWith(color: triggerColor)),
              if (streaming) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.think),
                ),
              ],
              const SizedBox(width: 6),
              Icon(
                  _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                  size: 14,
                  color: triggerColor),
            ],
          ),
        ),
      ),
    );
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Text(widget.block.text,
          style: AppText.callout.copyWith(color: AppColors.think)),
    );
    return Collapsible(open: _open, trigger: trigger, content: content);
  }

  Widget _tool() {
    final b = widget.block;
    final color = switch (b.status) {
      ToolStatus.done => AppColors.approve,
      ToolStatus.failed => AppColors.reject,
      ToolStatus.running => AppColors.accentOf(context),
      ToolStatus.pending => AppColors.warning,
    };
    // 工具块：未触碰时整行保持银灰（与思考一致），hover 变黑；去掉外层灰底卡片。
    // 折叠态与 AgentGroupView 视觉一致：单行文字 + chevron，无背景无边框。
    // 展开用 Collapsible（SizeTransition + 淡入下滑），与模型切换同款 slide+fade。
    final triggerColor = _toolHover
        ? AppColors.textPrimaryOf(context)
        : AppColors.placeholderOf(context);
    final action = toolActionLabel(b.toolName ?? 'tool', b.command ?? '');
    final displayText = action.target.isEmpty
        ? action.verb
        : '${action.verb} ${action.target}';
    final trigger = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _toolHover = true),
      onExit: (_) => setState(() => _toolHover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.iconForTool(b.toolName),
                  size: 14, color: triggerColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(displayText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono.copyWith(color: triggerColor)),
              ),
              const SizedBox(width: 12),
              if (b.status == ToolStatus.running)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.accentOf(context)),
                )
              else if (b.status == ToolStatus.failed)
                Icon(AppIcons.close,
                    size: 13, color: AppColors.reject)
              else if (b.status == ToolStatus.pending)
                Text('等待',
                    style: AppText.monoCaption.copyWith(color: triggerColor))
              else
                Icon(AppIcons.check,
                    size: 13, color: AppColors.approve),
              const SizedBox(width: 6),
              Icon(
                  _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                  size: 14,
                  color: triggerColor),
            ],
          ),
        ),
      ),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (b.command?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            // 命令用深色代码块呈现（与 Markdown 代码块一致），等宽、可选中、横向滚动。
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1D1D1F),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(10),
                      child: SelectableText(
                        b.command!,
                        style: AppText.mono.copyWith(
                            color: const Color(0xFFECECEF), height: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                CopyButton(text: b.command!),
              ],
            ),
          ),
        if (b.output.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Icon(
                    b.status == ToolStatus.failed
                        ? AppIcons.close
                        : AppIcons.check,
                    size: 12,
                    color: color),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(b.output,
                      style: AppText.monoCaption.copyWith(color: color)),
                ),
              ],
            ),
          ),
        if ((b.command == null || b.command!.isEmpty) &&
            b.output.isEmpty &&
            (b.status == ToolStatus.running ||
                b.status == ToolStatus.pending))
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accentOf(context))),
                const SizedBox(width: 8),
                Text('准备命令…', style: AppText.monoCaption),
              ],
            ),
          ),
      ],
    );
    return Collapsible(open: _open, trigger: trigger, content: content);
  }
}

/// 把一组「思考 + 多个工具」折叠为一个可展开的卡片。
/// 折叠态：浅灰圆角一行「思考 >」或「思考中… >」，若含工具则带上工具数。
/// 把一组「思考 + 多个工具」（任意顺序）折叠为一个可展开的标签。
/// 折叠态：一行「思考 + N 个工具」或「N 个思考 + M 个工具」+ chevron，无背景；
/// 展开后：按 parts 原顺序展示思考文本（去斜体）与工具行（紧凑 _InlineToolRow）。
class AgentGroupView extends StatefulWidget {
  final AgentGroup group;
  /// 是否仍处在这段的流式追加期（用于光标等）。
  final bool streaming;
  const AgentGroupView({
    super.key,
    required this.group,
    this.streaming = false,
  });

  @override
  State<AgentGroupView> createState() => _AgentGroupViewState();
}

class _AgentGroupViewState extends State<AgentGroupView> {
  bool _open = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final triggerColor = _hover
        ? AppColors.textPrimaryOf(context)
        : AppColors.placeholderOf(context);
    final label = g.isRunning ? '思考中…' : _groupLabel(g);

    final trigger = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: AppText.callout.copyWith(color: triggerColor)),
              if (g.isRunning) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.think),
                ),
              ],
              const SizedBox(width: 6),
              Icon(
                  _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                  size: 14,
                  color: triggerColor),
            ],
          ),
        ),
      ),
    );
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      // 展开后按 parts 原序渲染成「列表」：每条思考 / 工具各为一行可折叠子项，
      // 不默认把思考内容摊开（点击「思考」行才展开）。列表整体相对触发区缩进。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < g.parts.length; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            if (g.parts[i].kind == BlockKind.think)
              _InlineThinkRow(think: g.parts[i])
            else if (g.parts[i].kind == BlockKind.tool)
              _InlineToolRow(tool: g.parts[i]),
          ],
        ],
      ),
    );
    return Collapsible(open: _open, trigger: trigger, content: content);
  }

  /// 折叠态标签：按工具类型分组的可读总结。
  /// 例：「思考 5 次，查看 6 个文件，执行 6 条命令」「思考，执行 1 条命令」「3 条命令」。
  /// 顺序：思考数（单数不带「1 次」） → 工具按出现顺序、按名称聚合。
  static String _groupLabel(AgentGroup g) {
    final segments = <String>[];
    // 1) 思考数：单数简洁表达，复数加次数
    final tc = g.thinkCount;
    if (tc > 0) {
      segments.add(tc == 1 ? '思考' : '思考 $tc 次');
    }
    // 2) 工具按首次出现顺序聚合
    final counts = <String, int>{};
    final order = <String>[];
    for (final t in g.tools) {
      final name = t.toolName ?? 'tool';
      if (!counts.containsKey(name)) order.add(name);
      counts[name] = (counts[name] ?? 0) + 1;
    }
    for (final name in order) {
      segments.add(_summarizeTool(name, counts[name]!));
    }
    return segments.join('，');
  }

  static String _summarizeTool(String name, int count) {
    switch (name) {
      case 'Read':
        return count == 1 ? '查看 1 个文件' : '查看 $count 个文件';
      case 'Write':
        return count == 1 ? '写入 1 个文件' : '写入 $count 个文件';
      case 'Edit':
        return count == 1 ? '编辑 1 个文件' : '编辑 $count 个文件';
      case 'Bash':
        return count == 1 ? '执行 1 条命令' : '执行 $count 条命令';
      case 'Grep':
        return count == 1 ? '搜索 1 处' : '搜索 $count 处';
      case 'Glob':
        return count == 1 ? '匹配 1 个文件' : '匹配 $count 个文件';
      case 'WebFetch':
        return count == 1 ? '访问 1 个网页' : '访问 $count 个网页';
      case 'WebSearch':
        return count == 1 ? '搜索 1 处' : '搜索 $count 处';
      case 'TodoWrite':
        return count == 1 ? '更新 1 次任务' : '更新 $count 次任务';
      default:
        return count == 1 ? '调用 1 次 $name' : '调用 $count 次 $name';
    }
  }
}

/// AgentGroup 展开后的工具子行：与独立 _tool() 视觉一致但不带整体卡片背景。
class _InlineToolRow extends StatefulWidget {
  final StreamBlock tool;
  const _InlineToolRow({required this.tool});

  @override
  State<_InlineToolRow> createState() => _InlineToolRowState();
}

class _InlineToolRowState extends State<_InlineToolRow> {
  bool _open = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final b = widget.tool;
    final color = switch (b.status) {
      ToolStatus.done => AppColors.approve,
      ToolStatus.failed => AppColors.reject,
      ToolStatus.running => AppColors.accentOf(context),
      ToolStatus.pending => AppColors.warning,
    };
    // 与思考一致的银灰→黑 hover；折叠态为 AgentGroup 列表里的一行子项。
    // 展开用 Collapsible（SizeTransition + 淡入下滑），与模型切换同款 slide+fade。
    final triggerColor = _hover
        ? AppColors.textPrimaryOf(context)
        : AppColors.placeholderOf(context);
    final action = toolActionLabel(b.toolName ?? 'tool', b.command ?? '');
    final displayText = action.target.isEmpty
        ? action.verb
        : '${action.verb} ${action.target}';
    final trigger = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.iconForTool(b.toolName),
                  size: 13, color: triggerColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(displayText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono.copyWith(
                        fontSize: 13, color: triggerColor)),
              ),
              const SizedBox(width: 8),
              // 状态：进行中转 spinner；失败用 ×（红色）；其余状态省略，
              // 让列表整体保持克制（截图里展开的列表项不显式标完成）。
              if (b.status == ToolStatus.running)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.accentOf(context)),
                )
              else if (b.status == ToolStatus.failed)
                Icon(AppIcons.close, size: 12, color: AppColors.reject),
              const SizedBox(width: 6),
              Icon(
                  _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                  size: 13,
                  color: triggerColor),
            ],
          ),
        ),
      ),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (b.command?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1D1D1F),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(10),
                      child: SelectableText(
                        b.command!,
                        style: AppText.mono.copyWith(
                            color: const Color(0xFFECECEF), height: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                CopyButton(text: b.command!),
              ],
            ),
          ),
        if (b.output.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Icon(
                    b.status == ToolStatus.failed
                        ? AppIcons.close
                        : AppIcons.check,
                    size: 12,
                    color: color),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(b.output,
                      style: AppText.monoCaption.copyWith(color: color)),
                ),
              ],
            ),
          ),
      ],
    );
    return Collapsible(open: _open, trigger: trigger, content: content);
  }
}

/// AgentGroup 展开后列表里的「思考」子行：与独立 _think() 触发区一致
/// （银灰→黑 hover、chevron 在右），默认折叠，点击才展开思考文本。
class _InlineThinkRow extends StatefulWidget {
  final StreamBlock think;
  const _InlineThinkRow({required this.think});

  @override
  State<_InlineThinkRow> createState() => _InlineThinkRowState();
}

class _InlineThinkRowState extends State<_InlineThinkRow> {
  bool _open = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final b = widget.think;
    final streaming = b.text.trim().isEmpty;
    final triggerColor = _hover
        ? AppColors.textPrimaryOf(context)
        : AppColors.placeholderOf(context);
    final trigger = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(streaming ? '思考中…' : '思考',
                  style: AppText.callout.copyWith(color: triggerColor)),
              if (streaming) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.think),
                ),
              ],
              const SizedBox(width: 6),
              Icon(
                  _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                  size: 14,
                  color: triggerColor),
            ],
          ),
        ),
      ),
    );
    final content = b.text.trim().isNotEmpty
        ? Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
            child: Text(
              b.text,
              style: AppText.callout.copyWith(color: AppColors.think),
            ),
          )
        : const SizedBox.shrink();
    return Collapsible(open: _open, trigger: trigger, content: content);
  }
}

/// 折叠/展开容器：展开时高度随 SizeTransition 平滑增长，内容同步做
/// 淡入 + 轻微下滑（slide+fade），与模型切换的过渡同款手感，避免 AnimatedSize
/// 把内容"一页页掀开"的闪烁。折叠时反向收起。
class Collapsible extends StatefulWidget {
  final bool open;
  final Widget trigger; // 始终可见的触发行
  final Widget content; // 展开时显示的内容
  final Duration duration;
  const Collapsible({
    super.key,
    required this.open,
    required this.trigger,
    required this.content,
    this.duration = const Duration(milliseconds: 140),
  });

  @override
  State<Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<Collapsible>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.open ? 1 : 0,
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -0.03),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void didUpdateWidget(covariant Collapsible old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) {
      if (widget.open) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 仅在展开或正在收起动画期间构建内容；完全折叠后移除，避免隐藏内容仍留在树里
    // （也防止折叠态下被测试/无障碍遍历到多余节点）。
    final showContent = widget.open || _ctrl.value > 0.0001;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.trigger,
        SizeTransition(
          sizeFactor: _ctrl,
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(
              position: _slide,
              child: showContent ? widget.content : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

/// 工具行展示用的「动词 + 目标」拆分。
/// `verb` 是中文动作词（读取文件 / 终端 / 搜索 …），`target` 是从 command 里
/// 抽取的目标（文件名 / 命令片段 / 搜索 pattern）。两者拼接成列表行单行文本。
({String verb, String target}) toolActionLabel(String name, String command) {
  switch (name) {
    case 'Read':
      return (verb: '读取文件', target: _basename(command));
    case 'Write':
      return (verb: '写入文件', target: _basename(command));
    case 'Edit':
      return (verb: '编辑文件', target: _basename(command));
    case 'Bash':
    case 'KillBash':
      return (verb: '终端', target: _truncate(command, 60));
    case 'Grep':
      return (verb: '搜索', target: _extractPattern(command));
    case 'Glob':
      return (verb: '匹配文件', target: _truncate(command, 40));
    case 'WebFetch':
      return (verb: '访问网页', target: _truncate(command, 40));
    case 'WebSearch':
      return (verb: '搜索', target: _extractPattern(command));
    case 'TodoWrite':
      return (verb: '更新任务', target: _truncate(command, 40));
    default:
      return (verb: name, target: _truncate(command, 50));
  }
}

/// 取路径最后一段作为「文件名」展示。空路径返回空串。
String _basename(String path) {
  if (path.isEmpty) return '';
  final n = path.replaceAll('\\', '/');
  final i = n.lastIndexOf('/');
  return i == -1 ? n : n.substring(i + 1);
}

/// 单行截断：合并空白 + 限长，超长用 … 结尾。
String _truncate(String s, int max) {
  if (s.isEmpty) return '';
  final oneline = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneline.length <= max) return oneline;
  return '${oneline.substring(0, max - 1)}…';
}

/// 从 Grep / WebSearch 类命令里抽出搜索模式。
/// 优先找 "--pattern X" / "-e X" / 首个带引号的串，回退到首个 token。
String _extractPattern(String cmd) {
  final flag = RegExp(r'(?:--pattern|-e)\s+(\S+)').firstMatch(cmd);
  if (flag != null) return _truncate(flag.group(1)!, 40);
  final quoted = RegExp(r'"([^"]+)"').firstMatch(cmd);
  if (quoted != null) return _truncate(quoted.group(1)!, 40);
  return _truncate(cmd.split(RegExp(r'\s+')).first, 40);
}