// 已归档会话弹窗（HuxBottomSheet 形态）：搜索 + 工作区筛选 + 排序 + 卡片。
// 归档状态由 SessionArchiveStore 维护（见 relay/session_archive_store.dart）。
//
// 用 HuxBottomSheet.size=large 替代全屏 MaterialPageRoute，避免归档页喧宾夺主：
// - drag handle + 关闭按钮：和现有 modal 风格一致；
// - 大屏上限 85%，仍能容纳多张卡片；
// - 关闭后无需维护 PageRoute 生命周期。

import 'package:flutter/material.dart';
import 'package:hux/hux.dart';
import '../relay/models.dart';
import '../relay/relay_client.dart';
import '../relay/session_archive_store.dart';
import '../relay/session_store.dart';
import '../relay/session_view.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_icons.dart';
import '../theme/app_text_styles.dart';
import '../widgets/common.dart';

/// 在 [context] 之上弹出归档弹窗。
/// 走 showHuxBottomSheet 而非 push 全屏，避免点击归档变成「页面跳转」。
Future<void> showArchiveSheet(
  BuildContext context, {
  required SessionStore store,
  required SessionArchiveStore archive,
  required RelayClient client,
}) {
  return showHuxBottomSheet<void>(
    context: context,
    title: '已归档会话',
    subtitle: '搜索 / 筛选 / 恢复已归档的会话。',
    size: HuxBottomSheetSize.large,
    showDragHandle: true,
    showCloseButton: true,
    child: ArchiveSheet(store: store, archive: archive, client: client),
  );
}

/// 弹窗主体（不含底板 / drag handle / 标题——由 showHuxBottomSheet 负责）。
class ArchiveSheet extends StatefulWidget {
  final SessionStore store;
  final SessionArchiveStore archive;
  final RelayClient client;
  const ArchiveSheet({
    super.key,
    required this.store,
    required this.archive,
    required this.client,
  });

  @override
  State<ArchiveSheet> createState() => _ArchiveSheetState();
}

class _ArchiveSheetState extends State<ArchiveSheet> {
  String _query = '';
  String? _workspace; // null = 全部
  ArchiveSort _sort = ArchiveSort.archivedTime;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStore);
    widget.archive.addListener(_onStore);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    widget.archive.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  void _open(SessionMeta m) {
    final sid = m.sessionId;
    if (!widget.store.activeSids.contains(sid)) {
      widget.client.send('open_history',
          sid: sid, payload: {'sessionId': sid, 'cwd': m.cwd});
    }
    widget.store.setCurrent(sid);
    Navigator.of(context).pop();
  }

  void _restore(SessionMeta m) {
    widget.archive.restore(m.sessionId);
    if (!mounted) return;
    showAppToast(context,
        message: '已恢复：${m.title.isEmpty ? "（无标题）" : m.title}',
        variant: AppToastVariant.success);
  }

  void _copyId(SessionMeta m) => copyToClipboard(context, m.sessionId);

  @override
  Widget build(BuildContext context) {
    final archived = widget.store.history
        .where((m) => widget.archive.isArchived(m.sessionId))
        .toList();
    final list = ArchiveList.from(
      archived,
      query: _query,
      workspaceKey: _workspace,
      sort: _sort,
    );
    final workspaceOptions = <String>{
      for (final m in archived) sessionGroupKey(m.cwd),
    }.toList()
      ..sort();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 搜索框
        HuxInput(
          hint: '搜索已归档会话',
          prefixIcon: const Icon(AppIcons.search),
          textInputAction: TextInputAction.search,
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 10),
        // 工作区筛选
        _WorkspaceFilter(
          options: workspaceOptions,
          value: _workspace,
          onChanged: (v) => setState(() => _workspace = v),
        ),
        const SizedBox(height: 8),
        // 排序 tabs
        _SortTabs(
          value: _sort,
          onChanged: (v) => setState(() => _sort = v),
        ),
        const SizedBox(height: 10),
        // 列表 / 空态
        if (list.metas.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('无已归档会话',
                  style: AppText.caption.copyWith(
                      color: AppColors.placeholderOf(context))),
            ),
          )
        else
          for (final m in list.metas) ...[
            _ArchiveCard(
              meta: m,
              workspace: sessionGroupKey(m.cwd),
              onTap: () => _open(m),
              onRestore: () => _restore(m),
              onCopyId: () => _copyId(m),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _ArchiveCard extends StatelessWidget {
  final SessionMeta meta;
  final String workspace;
  final VoidCallback onTap;
  final VoidCallback onRestore;
  final VoidCallback onCopyId;
  const _ArchiveCard({
    required this.meta,
    required this.workspace,
    required this.onTap,
    required this.onRestore,
    required this.onCopyId,
  });

  @override
  Widget build(BuildContext context) {
    final display = meta.title.isEmpty ? '（无标题）' : meta.title;
    return Pressable(
      onTap: onTap,
      child: HuxCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        backgroundColor: AppColors.surfaceOf(context),
        borderRadius: AppRadius.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(AppIcons.folder,
                    size: 14, color: AppColors.textSecondaryOf(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(workspace,
                      style: AppText.monoCaption
                          .copyWith(color: AppColors.textSecondaryOf(context)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(display,
                      style: AppText.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                HuxButton(
                  onPressed: onRestore,
                  variant: HuxButtonVariant.secondary,
                  size: HuxButtonSize.small,
                  child: Text('恢复', style: AppText.calloutStrong),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('归档于  ${_fmtTime(meta.updatedAt)}',
                    style: AppText.caption.copyWith(
                        color: AppColors.placeholderOf(context))),
                const Spacer(),
                _RowMenu(
                  items: [
                    _MenuItem(
                      icon: AppIcons.copy,
                      label: '复制 Session ID',
                      onTap: onCopyId,
                    ),
                    _MenuItem(
                      icon: AppIcons.check,
                      label: '恢复',
                      onTap: onRestore,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class _RowMenu extends StatelessWidget {
  final List<_MenuItem> items;
  const _RowMenu({required this.items});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_MenuItem>(
      tooltip: '更多',
      offset: const Offset(0, 28),
      color: AppColors.surfaceOf(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.popup),
        side: BorderSide(color: AppColors.hairlineOf(context)),
      ),
      itemBuilder: (_) => [
        for (final it in items)
          PopupMenuItem<_MenuItem>(
            value: it,
            height: 36,
            child: Row(
              children: [
                Icon(it.icon, size: 14, color: AppColors.textPrimaryOf(context)),
                const SizedBox(width: 10),
                Text(it.label, style: AppText.callout),
              ],
            ),
          ),
      ],
      onSelected: (it) => it.onTap(),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(AppIcons.ellipsis,
            size: 16, color: AppColors.placeholderOf(context)),
      ),
    );
  }
}

class _WorkspaceFilter extends StatelessWidget {
  final List<String> options;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _WorkspaceFilter({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final labels = <String>['所有工作区', ...options];
    final current = value ?? '所有工作区';
    final items = [
      for (final l in labels)
        HuxDropdownItem<String>(
          value: l,
          child: Row(
            children: [
              Icon(
                l == current ? AppIcons.check : AppIcons.folder,
                size: 14,
                color: AppColors.textSecondaryOf(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l,
                  style: AppText.monoCaption
                      .copyWith(color: AppColors.textPrimaryOf(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ];
    return SizedBox(
      // 显式 trigger 宽度，menu 跟随（hux 内部 showDialog 用 buttonSize.width）。
      key: const ValueKey('archive-ws-dropdown'),
      width: double.infinity,
      child: HuxDropdown<String>(
        items: items,
        value: current,
        // trigger 直接复用 item widget（folder/check 图标 + 文字 + ellipsis）。
        useItemWidgetAsValue: true,
        variant: HuxButtonVariant.secondary,
        size: HuxButtonSize.medium,
        onChanged: (v) => onChanged(v == '所有工作区' ? null : v),
      ),
    );
  }
}

class _SortTabs extends StatelessWidget {
  final ArchiveSort value;
  final ValueChanged<ArchiveSort> onChanged;
  const _SortTabs({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in ArchiveSort.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Chip(
                label: s.label,
                selected: s == value,
                onTap: () => onChanged(s),
                compact: true,
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      // 唯一的 Key 让 widget 测试在多张卡片同名 Text 仍能精确定位 chip。
      key: ValueKey('archive-ws-chip:$label'),
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 14, vertical: compact ? 6 : 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentSoftOf(context)
              : AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: selected
                  ? AppColors.accentOf(context).withValues(alpha: 0.35)
                  : AppColors.hairlineOf(context)),
        ),
        child: Text(
          label,
          style: (selected ? AppText.calloutStrong : AppText.callout)
              .copyWith(color: AppColors.textPrimaryOf(context)),
        ),
      ),
    );
  }
}

String _fmtTime(String iso) {
  if (iso.isEmpty) return '—';
  final t = DateTime.tryParse(iso);
  if (t == null) return iso;
  final local = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
