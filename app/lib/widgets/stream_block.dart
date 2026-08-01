import 'package:flutter/material.dart';
import '../relay/models.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';

/// 渲染一个流块。home_shell 与验证页共用。
class StreamBlockView extends StatefulWidget {
  final StreamBlock block;
  const StreamBlockView({super.key, required this.block});

  @override
  State<StreamBlockView> createState() => _StreamBlockViewState();
}

class _StreamBlockViewState extends State<StreamBlockView> {
  bool _open = false; // think / tool 折叠态

  @override
  Widget build(BuildContext context) {
    switch (widget.block.kind) {
      case BlockKind.user:
        return _user();
      case BlockKind.think:
        return _think();
      case BlockKind.text:
        return Text(widget.block.text, style: AppText.body);
      case BlockKind.tool:
        return _tool();
    }
  }

  Widget _user() {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.accentSoft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(widget.block.text, style: AppText.body),
      ),
    );
  }

  Widget _think() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.thinkSoft,
        borderRadius: BorderRadius.circular(AppRadius.thumbnail),
      ),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(_open ? AppIcons.chevronDown : AppIcons.chevronRight,
                        size: 14, color: AppColors.think),
                    const SizedBox(width: 6),
                    Text('思考',
                        style: AppText.callout.copyWith(color: AppColors.think)),
                  ],
                ),
              ),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(widget.block.text,
                    style: AppText.callout.copyWith(
                        color: AppColors.think, fontStyle: FontStyle.italic)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tool() {
    final b = widget.block;
    final color = switch (b.status) {
      ToolStatus.done => AppColors.approve,
      ToolStatus.failed => AppColors.reject,
      ToolStatus.running => AppColors.accent,
      ToolStatus.pending => AppColors.warning,
    };
    final label = switch (b.status) {
      ToolStatus.done => '完成',
      ToolStatus.failed => '失败',
      ToolStatus.running => '执行中',
      ToolStatus.pending => '等待',
    };
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.thumbnail),
        boxShadow: AppShadows.card,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.thumbnail),
                  bottomLeft: Radius.circular(AppRadius.thumbnail),
                ),
              ),
            ),
            Expanded(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _open = !_open),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 11),
                        child: Row(
                          children: [
                            Icon(AppIcons.terminal,
                                size: 14, color: AppColors.textSecondary),
                            const SizedBox(width: 8),
                            Text(b.toolName ?? 'tool', style: AppText.mono),
                            const Spacer(),
                            if (b.status == ToolStatus.running)
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.accent),
                              )
                            else
                              Icon(
                                  b.status == ToolStatus.failed
                                      ? AppIcons.close
                                      : AppIcons.check,
                                  size: 13,
                                  color: color),
                            const SizedBox(width: 4),
                            Text(label,
                                style:
                                    AppText.monoCaption.copyWith(color: color)),
                            const SizedBox(width: 6),
                            Icon(
                                _open
                                    ? AppIcons.chevronDown
                                    : AppIcons.chevronRight,
                                size: 13,
                                color: AppColors.placeholder),
                          ],
                        ),
                      ),
                    ),
                    if (_open && (b.command?.isNotEmpty ?? false))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(b.command!, style: AppText.mono),
                        ),
                      ),
                    if (_open && b.output.isNotEmpty)
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
                                  style:
                                      AppText.monoCaption.copyWith(color: color)),
                            ),
                          ],
                        ),
                      ),
                    if (_open &&
                        (b.command == null || b.command!.isEmpty) &&
                        b.output.isEmpty &&
                        (b.status == ToolStatus.running ||
                            b.status == ToolStatus.pending))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Row(
                          children: [
                            const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppColors.accent)),
                            const SizedBox(width: 8),
                            Text('准备命令…', style: AppText.monoCaption),
                          ],
                        ),
                      ),
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
                                  style:
                                      AppText.monoCaption.copyWith(color: color)),
                            ),
                          ],
                        ),
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
}