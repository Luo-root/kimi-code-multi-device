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
  const StreamBlockView({
    super.key,
    required this.block,
    this.streaming = false,
  });

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
      crossAxisAlignment: streaming
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
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
              Icon(AppIcons.thinking, size: 14, color: triggerColor),
              const SizedBox(width: 8),
              Text(
                streaming ? '思考中…' : '思考',
                style: AppText.callout.copyWith(color: triggerColor),
              ),
              if (streaming) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.think,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Icon(
                _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: 14,
                color: triggerColor,
              ),
            ],
          ),
        ),
      ),
    );
    final content = _ModuleCard(
      status: streaming
          ? (icon: AppIcons.thinking, color: AppColors.think, label: '思考中')
          : null,
      child: _ScopedContent(
        maxHeight: _kThinkContentMaxHeight,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _ThinkMarkdown(data: widget.block.text),
        ),
      ),
    );
    return Collapsible(open: _open, trigger: trigger, content: content);
  }

  Widget _tool() {
    final b = widget.block;
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
              Icon(
                AppIcons.iconForTool(b.toolName),
                size: 14,
                color: triggerColor,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  displayText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono.copyWith(color: triggerColor),
                ),
              ),
              const SizedBox(width: 12),
              if (b.status == ToolStatus.running)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accentOf(context),
                  ),
                )
              else if (b.status == ToolStatus.failed)
                Icon(
                  AppIcons.close,
                  size: 13,
                  color: AppColors.reject.withValues(alpha: 0.78),
                )
              else if (b.status == ToolStatus.pending)
                Text(
                  '等待',
                  style: AppText.monoCaption.copyWith(color: triggerColor),
                )
              else if (b.status == ToolStatus.cancelled)
                Text(
                  '已取消',
                  style: AppText.monoCaption.copyWith(color: triggerColor),
                )
              else
                Icon(
                  AppIcons.check,
                  size: 13,
                  color: AppColors.approve.withValues(alpha: 0.72),
                ),
              const SizedBox(width: 6),
              Icon(
                _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: 14,
                color: triggerColor,
              ),
            ],
          ),
        ),
      ),
    );
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: _ToolDetails(block: b),
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
              Icon(AppIcons.thinking, size: 14, color: triggerColor),
              const SizedBox(width: 8),
              Text(label, style: AppText.callout.copyWith(color: triggerColor)),
              if (g.isRunning) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.think,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Icon(
                _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: 14,
                color: triggerColor,
              ),
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
              Icon(
                AppIcons.iconForTool(b.toolName),
                size: 13,
                color: triggerColor,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  displayText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono.copyWith(
                    fontSize: 13,
                    color: triggerColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 状态：进行中转 spinner；失败用 ×（红色）；其余状态省略，
              // 让列表整体保持克制（截图里展开的列表项不显式标完成）。
              if (b.status == ToolStatus.running)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accentOf(context),
                  ),
                )
              else if (b.status == ToolStatus.failed)
                Icon(
                  AppIcons.close,
                  size: 12,
                  color: AppColors.reject.withValues(alpha: 0.78),
                )
              else if (b.status == ToolStatus.cancelled)
                Text(
                  '已取消',
                  style: AppText.monoCaption.copyWith(color: triggerColor),
                ),
              const SizedBox(width: 6),
              Icon(
                _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: 13,
                color: triggerColor,
              ),
            ],
          ),
        ),
      ),
    );
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: _ToolDetails(block: b, compact: true),
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
              Icon(AppIcons.thinking, size: 14, color: triggerColor),
              const SizedBox(width: 8),
              Text(
                streaming ? '思考中…' : '思考',
                style: AppText.callout.copyWith(color: triggerColor),
              ),
              if (streaming) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.think,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Icon(
                _open ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: 14,
                color: triggerColor,
              ),
            ],
          ),
        ),
      ),
    );
    final content = b.text.trim().isNotEmpty
        ? _ModuleCard(
            compact: true,
            child: _ScopedContent(
              maxHeight: _kThinkContentMaxHeight,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _ThinkMarkdown(data: b.text),
              ),
            ),
          )
        : const SizedBox.shrink();
    return Collapsible(open: _open, trigger: trigger, content: content);
  }
}

/// 思考正文使用与 AI 回复一致的 Markdown 渲染器。
/// 外层降低不透明度 + 缩小一档字号（正文 15 → ~13.5，约小 1-2 号），
/// 保持思考内容的次级层级，但标题、列表、代码块等结构完整保留。
class _ThinkMarkdown extends StatelessWidget {
  final String data;
  const _ThinkMarkdown({required this.data});

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      // 思考为次级内容：整体字号缩到正文的 0.9（≈小 1-2 号），
      // 标题/列表/代码块随正文同比缩小，层级保持一致。
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(0.9),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: AppColors.textSecondaryOf(context)),
        child: Opacity(opacity: 0.72, child: MarkdownView(data: data)),
      ),
    );
  }
}

/// 统一模块卡：工具 / 思考模块展开后的统一容器。
/// 视觉基准 = 编辑文件卡：白底 surface + 圆角 12 + hairline 边框 + 轻外扩 shadow。
/// 折叠触发行已展示工具图标与名称，展开后不再重复；标题栏只留
/// 信息性副标题（文件路径/命令摘要）与状态标识，两者皆无时不渲染标题栏。
class _ModuleCard extends StatelessWidget {
  final String? subtitle;
  final ({IconData icon, Color color, String label})? status;
  final Widget child;
  final bool compact;
  const _ModuleCard({
    this.subtitle,
    this.status,
    required this.child,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    final showHeader = hasSubtitle || status != null;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.detailHairlineOf(context)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.12
                  : 0.035,
            ),
            blurRadius: 0,
            spreadRadius: 4,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader)
            Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                compact ? 8 : 10,
                10,
                compact ? 8 : 10,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: hasSubtitle
                        ? Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.mono.copyWith(
                              color: AppColors.textSecondaryOf(context),
                              height: 1.35,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (status != null) ...[
                    Icon(status!.icon, size: 13, color: status!.color),
                    const SizedBox(width: 5),
                    Text(
                      status!.label,
                      style: AppText.captionStrong.copyWith(color: status!.color),
                    ),
                  ],
                ],
              ),
            ),
          if (showHeader)
            Divider(
              height: 1,
              thickness: 1,
              color: AppColors.detailHairlineOf(context),
            ),
          child,
        ],
      ),
    );
  }
}

/// 展开内容区的纵向高度控制：内容超过 [maxHeight] 时在区内滚动，
/// 避免长内容把页面撑得无限高。横向滚动由内容块自持（命令 / diff）。
/// Scrollable 默认支持鼠标滚轮、触控与键盘方向键。
class _ScopedContent extends StatelessWidget {
  final double maxHeight;
  final Widget child;
  const _ScopedContent({required this.maxHeight, required this.child});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: child,
      ),
    );
  }
}

// 展开内容区行高上限（约行数换算）：思考 ≈10 行 markdown、命令/输出 ≈10 行 mono、diff ≈10 行。
const _kThinkContentMaxHeight = 280.0;
const _kSectionContentMaxHeight = 220.0;
const _kDiffContentMaxHeight = 240.0;

/// Read / Bash 等工具统一使用结构化详情卡，独立工具块与 AgentGroup 子项共用。
/// 卡片保持中性：标题栏承载工具类型和状态，内容区再拆成输入与输出，避免一整块深色代码框。
class _ToolDetails extends StatelessWidget {
  final StreamBlock block;
  final bool compact;
  const _ToolDetails({required this.block, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final command = block.command?.trim() ?? '';
    final output = block.output.trim();
    final status = _toolStatusPresentation(context, block.status);
    final isRead = block.toolName == 'Read';
    final isShell = _isShellTool(block.toolName);
    final isEdit = block.toolName == 'Edit' || _isEditTool(block.toolName);
    final editDiff = isEdit ? parseEditDiff(block.command, output) : null;

    String? subtitle;
    if (isRead && command.isNotEmpty) {
      subtitle = _basename(command);
    } else if (isEdit && editDiff?.filePath != null) {
      subtitle = editDiff!.filePath;
    } else if (isShell && command.isNotEmpty) {
      subtitle = _truncate(command, 60);
    }

    // 折叠触发行已展示工具图标与名称（如「终端 flutter test」），
    // 展开卡标题栏只保留信息性副标题（路径/命令摘要）与状态。
    return _ModuleCard(
      subtitle: subtitle,
      status: status,
      compact: compact,
      child: _ToolCardBody(
        block: block,
        command: command,
        output: output,
        status: status,
        isRead: isRead,
        isShell: isShell,
        isEdit: isEdit,
        editDiff: editDiff,
        compact: compact,
      ),
    );
  }
}

/// 统一卡的内容区：按模块类型组装（Edit diff / 命令+输出 / 空态）。
class _ToolCardBody extends StatelessWidget {
  final StreamBlock block;
  final String command;
  final String output;
  final ({IconData icon, Color color, String label}) status;
  final bool isRead;
  final bool isShell;
  final bool isEdit;
  final EditDiff? editDiff;
  final bool compact;
  const _ToolCardBody({
    required this.block,
    required this.command,
    required this.output,
    required this.status,
    required this.isRead,
    required this.isShell,
    required this.isEdit,
    required this.editDiff,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    // Edit diff 遵循参考图的轻量结构：文件路径 +「差异」+ 连续红删绿增行块。
    // `Replaced N occurrence...` 只是工具回执，不再伪装成用户要看的「输出」。
    if (isEdit && editDiff != null && !editDiff!.isEmpty) {
      return _EditDiffDetails(diff: editDiff!, compact: compact);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (command.isNotEmpty)
          _ToolSection(
            label: isRead
                ? '路径'
                : isShell
                    ? '命令'
                    : '输入',
            value: command,
            copyable: true,
            dark: isShell,
            compact: compact,
          ),
        if (output.isNotEmpty) ...[
          if (command.isNotEmpty)
            Divider(
              height: 1,
              thickness: 1,
              color: AppColors.detailHairlineOf(context),
            ),
          _ToolSection(
            label: isRead
                ? '读取结果'
                : isShell
                    ? '执行输出'
                    : '输出',
            value: output,
            copyable: true,
            dark: false,
            compact: compact,
            failed: block.status == ToolStatus.failed,
          ),
        ],
        if (command.isEmpty && output.isEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, compact ? 10 : 12),
            child: Row(
              children: [
                if (block.status == ToolStatus.running ||
                    block.status == ToolStatus.pending)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: status.color,
                    ),
                  )
                else
                  Icon(status.icon, size: 12, color: status.color),
                const SizedBox(width: 8),
                Text(
                  switch (block.status) {
                    ToolStatus.pending => '等待执行…',
                    ToolStatus.cancelled => '已取消',
                    _ => '暂无详细输出',
                  },
                  style: AppText.monoCaption.copyWith(
                    color: AppColors.textSecondaryOf(context),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _EditDiffDetails extends StatelessWidget {
  final EditDiff diff;
  final bool compact;
  const _EditDiffDetails({required this.diff, required this.compact});

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('edit-diff-details'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(12, compact ? 8 : 10, 12, 8),
          child: Row(
            children: [
              Text(
                '变更摘要',
                style: AppText.captionStrong.copyWith(
                  color: AppColors.detailLabelOf(context),
                ),
              ),
              const SizedBox(width: 10),
              _DiffSummaryItem(
                label: '新增 ${diff.additions}',
                marker: '+',
                color: AppColors.diffAddedMarkOf(context),
              ),
              const SizedBox(width: 8),
              _DiffSummaryItem(
                label: '删除 ${diff.removals}',
                marker: '−',
                color: AppColors.diffRemovedMarkOf(context),
              ),
              const SizedBox(width: 8),
              _DiffSummaryItem(
                label: '修改 ${diff.modifications}',
                marker: '~',
                color: AppColors.diffModifiedMarkOf(context),
              ),
            ],
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          color: AppColors.detailHairlineOf(context),
        ),
        // 纵向限高 + 横向滚动：diff 行多时在区内滚动，不撑高页面。
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _kDiffContentMaxHeight),
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: IntrinsicWidth(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final line in diff.lines) _DiffLineView(line: line),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DiffSummaryItem extends StatelessWidget {
  final String label;
  final String marker;
  final Color color;
  const _DiffSummaryItem({
    required this.label,
    required this.marker,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(marker, style: AppText.monoCaption.copyWith(color: color)),
        const SizedBox(width: 3),
        Text(
          label,
          style: AppText.caption.copyWith(
            color: AppColors.detailLabelOf(context),
          ),
        ),
      ],
    );
  }
}

class _DiffLineView extends StatelessWidget {
  final EditDiffLine line;
  const _DiffLineView({required this.line});

  @override
  Widget build(BuildContext context) {
    final background = switch (line.kind) {
      EditDiffKind.added => AppColors.diffAddedBgOf(context),
      EditDiffKind.removed => AppColors.diffRemovedBgOf(context),
      EditDiffKind.modified => AppColors.diffModifiedBgOf(context),
      EditDiffKind.context => AppColors.detailSurfaceOf(context),
    };
    final markerColor = switch (line.kind) {
      EditDiffKind.added => AppColors.diffAddedMarkOf(context),
      EditDiffKind.removed => AppColors.diffRemovedMarkOf(context),
      EditDiffKind.modified => AppColors.diffModifiedMarkOf(context),
      EditDiffKind.context => AppColors.detailLabelOf(context),
    };
    final marker = switch (line.kind) {
      EditDiffKind.added => '+',
      EditDiffKind.removed => '-',
      EditDiffKind.modified => '~',
      EditDiffKind.context => ' ',
    };
    // 参考图不展示双行号列；只保留一个窄标记列，让代码内容成为视觉主体。
    return Container(
      key: ValueKey(
        'diff-${line.kind.name}-${line.oldLine ?? 0}-${line.newLine ?? 0}',
      ),
      color: background,
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 18),
          SizedBox(
            width: 14,
            child: Text(
              marker,
              style: AppText.monoCaption.copyWith(color: markerColor),
            ),
          ),
          const SizedBox(width: 4),
          SelectableText(
            line.text,
            style: AppText.mono.copyWith(
              color: line.kind == EditDiffKind.context
                  ? AppColors.textSecondaryOf(context)
                  : markerColor,
              height: 1.5,
            ),
          ),
          if (line.isModified && line.secondaryText != null) ...[
            const SizedBox(width: 16),
            Text('→', style: AppText.mono.copyWith(color: markerColor)),
            const SizedBox(width: 8),
            SelectableText(
              line.secondaryText!,
              style: AppText.mono.copyWith(
                color: AppColors.diffAddedMarkOf(context),
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(width: 18),
        ],
      ),
    );
  }
}

class _ToolSection extends StatelessWidget {
  final String label;
  final String value;
  final bool copyable;
  final bool dark;
  final bool compact;
  final bool failed;
  const _ToolSection({
    required this.label,
    required this.value,
    required this.copyable,
    required this.dark,
    required this.compact,
    this.failed = false,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = dark
        ? const Color(0xFFECECEF)
        : failed
        ? AppColors.reject
        : AppColors.textPrimaryOf(context);
    final background = dark
        ? const Color(0xFF1D1D1F)
        : failed
        ? AppColors.diffRemovedBgOf(context)
        : AppColors.detailSurfaceOf(context);

    return Container(
      width: double.infinity,
      color: background,
      padding: EdgeInsets.fromLTRB(12, compact ? 8 : 10, 6, compact ? 8 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.captionStrong.copyWith(
                    color: dark
                        ? const Color(0xFF8C8C92)
                        : AppColors.detailLabelOf(context),
                  ),
                ),
                const SizedBox(height: 5),
                // 纵向限高 + 横向滚动：长输出在区内滚动，不撑高页面；
                // 鼠标滚轮 / 触控 / 键盘（Scrollable 默认）均可用。
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: _kSectionContentMaxHeight,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        value,
                        style: AppText.mono.copyWith(
                          color: foreground,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (copyable) ...[
            const SizedBox(width: 4),
            CopyButton(text: value, dark: dark, plain: true),
          ],
        ],
      ),
    );
  }
}

({String label, IconData icon, Color color}) _toolStatusPresentation(
  BuildContext context,
  ToolStatus status,
) {
  return switch (status) {
    ToolStatus.done => (
      label: '完成',
      icon: AppIcons.check,
      color: AppColors.approve.withValues(alpha: 0.72),
    ),
    ToolStatus.failed => (
      label: '失败',
      icon: AppIcons.close,
      color: AppColors.reject.withValues(alpha: 0.78),
    ),
    ToolStatus.running => (
      label: '执行中',
      icon: AppIcons.terminal,
      color: AppColors.accentOf(context).withValues(alpha: 0.72),
    ),
    ToolStatus.pending => (
      label: '等待',
      icon: AppIcons.chevronRight,
      color: AppColors.warning.withValues(alpha: 0.72),
    ),
    ToolStatus.cancelled => (
      label: '已取消',
      icon: AppIcons.stop,
      color: AppColors.placeholderOf(context).withValues(alpha: 0.8),
    ),
  };
}

/// 工具名是否属于 Shell/Bash 类（容忍大小写与常见变体）。
bool _isShellTool(String? name) {
  if (name == null) return false;
  switch (name.toLowerCase()) {
    case 'bash':
    case 'killbash':
    case 'shell':
    case 'terminal':
    case 'sh':
    case 'zsh':
      return true;
  }
  return false;
}

/// 工具名是否属于 Edit/写文件类（与协议字段命名解耦，按 models.looksLikeEditTitle）。
bool _isEditTool(String? name) {
  if (name == null) return false;
  return looksLikeEditTitle(name);
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
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );
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
      final diff = parseEditDiff(command, '');
      return (verb: '编辑文件', target: _basename(diff.filePath ?? command));
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
      // Edit 变体（edit / EditFile / edit_file 等）：复用 diff 解析拿到 filePath。
      if (_isEditTool(name)) {
        final diff = parseEditDiff(command, '');
        return (verb: '编辑文件', target: _basename(diff.filePath ?? command));
      }
      // Shell 变体（Terminal / shell / sh / zsh）：统一视为终端。
      if (_isShellTool(name)) {
        return (verb: '终端', target: _truncate(command, 60));
      }
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
