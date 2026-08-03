// 会话视图层共享的小工具：工作区分组、按时间排序、加载更多分页。
//
// 抽到这里是为了让"工作区抽屉"和"已归档页"共用同一套派生逻辑，避免两边各
// 写一份且规则漂移。

import 'models.dart';

/// 把 [cwd] 切成工作区名：取路径最后两级（如 `code/kimi-code-multi-device`）。
/// Windows / POSIX 路径分隔符都兼容。
String sessionGroupKey(String cwd) {
  final parts = cwd
      .split(RegExp(r'[/\\]'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length >= 2) {
    return '${parts[parts.length - 2]}/${parts.last}';
  }
  return parts.isNotEmpty ? parts.last : '—';
}

/// 把会话按工作区分组返回；组内按 [updatedAt] 倒序（新→旧）。
List<MapEntry<String, List<SessionMeta>>> groupByWorkspace(
  Iterable<SessionMeta> metas, {
  String Function(SessionMeta)? groupKeyOf,
}) {
  final keyOf = groupKeyOf ?? (m) => sessionGroupKey(m.cwd);
  final byKey = <String, List<SessionMeta>>{};
  for (final m in metas) {
    byKey.putIfAbsent(keyOf(m), () => []).add(m);
  }
  for (final list in byKey.values) {
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }
  // 工作区也按"最新会话时间"倒序，让最近活跃的工程靠前。
  final entries = byKey.entries.toList()
    ..sort((a, b) {
      final aT = a.value.isEmpty ? '' : a.value.first.updatedAt;
      final bT = b.value.isEmpty ? '' : b.value.first.updatedAt;
      return bT.compareTo(aT);
    });
  return entries;
}

/// 工作区抽屉的"按工作区分组 + 加载更多"派生结果。
class WorkspaceGroups {
  final List<MapEntry<String, List<SessionMeta>>> groups;
  final Map<String, int> expanded; // 各组当前展开的行数
  const WorkspaceGroups(this.groups, this.expanded);

  /// [metas] 中各工作区仅取前 [pageSize] 条；折叠状态由 [initialExpanded] 决定。
  factory WorkspaceGroups.fold(
    Iterable<SessionMeta> metas, {
    int pageSize = 5,
    Map<String, int>? initialExpanded,
  }) {
    final groups = groupByWorkspace(metas);
    final expanded = <String, int>{};
    for (final e in groups) {
      expanded[e.key] = (initialExpanded?[e.key]) ??
          (e.value.length > pageSize ? pageSize : e.value.length);
    }
    return WorkspaceGroups(groups, expanded);
  }

  /// 工作区 [group] 还能再展开多少条；0 表示已全部展开。
  int remainingOf(String group, int total) {
    final shown = expanded[group] ?? 0;
    final left = total - shown;
    return left < 0 ? 0 : left;
  }

  WorkspaceGroups expandMore(String group, int pageSize) {
    final next = Map<String, int>.from(expanded);
    next[group] = (next[group] ?? 0) + pageSize;
    return WorkspaceGroups(groups, next);
  }
}

/// "已归档页"派生：搜索 + 工作区筛选 + 排序。
class ArchiveList {
  final List<SessionMeta> metas;
  const ArchiveList(this.metas);

  factory ArchiveList.from(
    Iterable<SessionMeta> all, {
    String query = '',
    String? workspaceKey, // 来自 sessionGroupKey；null = 全部
    ArchiveSort sort = ArchiveSort.archivedTime,
  }) {
    final q = query.trim().toLowerCase();
    var list = all.where((m) {
      if (workspaceKey != null && sessionGroupKey(m.cwd) != workspaceKey) {
        return false;
      }
      if (q.isEmpty) return true;
      return m.title.toLowerCase().contains(q) ||
          m.cwd.toLowerCase().contains(q);
    }).toList();
    list.sort((a, b) {
      switch (sort) {
        case ArchiveSort.archivedTime:
        case ArchiveSort.createdTime:
          // 暂用 updatedAt 作时间近似（kimi 不返回 createdAt/archivedAt）。
          return b.updatedAt.compareTo(a.updatedAt);
        case ArchiveSort.alphabetical:
          return a.title.compareTo(b.title);
      }
    });
    return ArchiveList(list);
  }
}

enum ArchiveSort { archivedTime, createdTime, alphabetical }

extension ArchiveSortX on ArchiveSort {
  String get label => switch (this) {
        ArchiveSort.archivedTime => '归档时间',
        ArchiveSort.createdTime => '创建时间',
        ArchiveSort.alphabetical => '按字母顺序',
      };
}
