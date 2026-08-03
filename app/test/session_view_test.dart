// 验证 test/probe/session_list_probe_test 的派生规则已经稳定在生产代码里：
// 工作区分组、按时间排序、加载更多分页、归档搜索/筛选/排序。

import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/models.dart';
import 'package:sentinel/relay/session_view.dart';

void main() {
  SessionMeta m(String id, String cwd, String updatedAt, {String title = ''}) =>
      SessionMeta(
        sessionId: id,
        cwd: cwd,
        title: title.isEmpty ? id : title,
        updatedAt: updatedAt,
      );

  group('sessionGroupKey', () {
    test('取路径最后两级', () {
      expect(sessionGroupKey(r'D:\a\b\relay'), 'b/relay');
      expect(sessionGroupKey(r'D:\a\b\relay\'), 'b/relay');
      expect(
          sessionGroupKey(
              r'D:\Github-Project\kimi-code-multi-device\code\kimi-code-multi-device'),
          'code/kimi-code-multi-device');
      expect(sessionGroupKey('/home/x/projects/v0probe'), 'projects/v0probe');
    });

    test('单级路径与空路径', () {
      expect(sessionGroupKey('/single'), 'single');
      expect(sessionGroupKey(''), '—');
    });
  });

  group('groupByWorkspace', () {
    test('组内按 updatedAt 倒序，组间按最新会话倒序', () {
      final metas = [
        m('a1', r'D:\a\b\relay', '2026-08-01T00:00:00Z'),
        m('a2', r'D:\a\b\relay', '2026-08-03T00:00:00Z'),
        m('b1', '/x/y/probe', '2026-08-02T00:00:00Z'),
        m('b2', '/x/y/probe', '2026-08-04T00:00:00Z'),
      ];
      final g = groupByWorkspace(metas);
      // relay 最新 → probe 最新 → 按 updatedAt.first 排序
      expect(g.map((e) => e.key).toList(), ['y/probe', 'b/relay']);
      // relay 组内：a2 > a1
      expect(g[1].value.map((e) => e.sessionId).toList(), ['a2', 'a1']);
      // probe 组内：b2 > b1
      expect(g[0].value.map((e) => e.sessionId).toList(), ['b2', 'b1']);
    });
  });

  group('WorkspaceGroups.fold', () {
    test('每组默认只显示前 5 条', () {
      final metas = List.generate(
        8,
        (i) => m('s$i', r'D:\a\b\r', '2026-08-03T00:0$i:00Z'),
      );
      final wg = WorkspaceGroups.fold(metas, pageSize: 5);
      expect(wg.groups, hasLength(1));
      expect(wg.expanded[wg.groups.first.key], 5);
      expect(wg.remainingOf(wg.groups.first.key, 8), 3);
    });

    test('总数小于 pageSize 时全部展示，无加载更多', () {
      final metas = List.generate(
        3,
        (i) => m('s$i', r'D:\a\b\r', '2026-08-03T00:0$i:00Z'),
      );
      final wg = WorkspaceGroups.fold(metas, pageSize: 5);
      expect(wg.expanded[wg.groups.first.key], 3);
      expect(wg.remainingOf(wg.groups.first.key, 3), 0);
    });

    test('expandMore 累加展开数，受 pageSize 控制', () {
      final metas = List.generate(
        15,
        (i) => m('s$i', r'D:\a\b\r', '2026-08-03T00:0$i:00Z'),
      );
      final wg = WorkspaceGroups.fold(metas, pageSize: 5);
      final key = wg.groups.first.key;
      var cur = wg;
      cur = cur.expandMore(key, 5);
      expect(cur.expanded[key], 10);
      cur = cur.expandMore(key, 5);
      expect(cur.expanded[key], 15);
      expect(cur.remainingOf(key, 15), 0);
    });
  });

  group('ArchiveList.from', () {
    final metas = [
      m('a1', r'D:\a\b\relay', '2026-08-01T00:00:00Z', title: 'Bash'),
      m('a2', r'D:\a\b\relay', '2026-08-03T00:00:00Z', title: 'Apple'),
      m('p1', '/x/y/probe', '2026-08-02T00:00:00Z', title: 'Probe'),
    ];

    test('默认按"归档时间"（用 updatedAt 近似）倒序', () {
      final list = ArchiveList.from(metas);
      expect(list.metas.map((e) => e.sessionId).toList(), ['a2', 'p1', 'a1']);
    });

    test('按字母顺序', () {
      final list = ArchiveList.from(metas, sort: ArchiveSort.alphabetical);
      expect(list.metas.map((e) => e.title).toList(),
          ['Apple', 'Bash', 'Probe']);
    });

    test('按工作区筛选', () {
      final list =
          ArchiveList.from(metas, workspaceKey: 'b/relay');
      expect(list.metas.map((e) => e.sessionId).toList(), ['a2', 'a1']);
    });

    test('搜索：标题或 cwd 子串命中', () {
      final list = ArchiveList.from(metas, query: 'probe');
      expect(list.metas.map((e) => e.sessionId).toList(), ['p1']);
    });

    test('搜索 + 筛选 + 排序可组合', () {
      final list = ArchiveList.from(
        metas,
        query: 'a',
        workspaceKey: 'b/relay',
        sort: ArchiveSort.alphabetical,
      );
      expect(list.metas.map((e) => e.sessionId).toList(), ['a2', 'a1']);
    });
  });
}
