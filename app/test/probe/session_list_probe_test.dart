// Kimi Code 会话响应探针：把当前 relay 实际下行的 session.list 形状固化下来，
// 并把"我们想要的字段"和"我们实际能拿到的字段"对照记下来，给后续 UI/模型改造打
// 底。运行方式：`flutter test test/probe/session_list_probe_test.dart`。
//
// 已知事实（截至 2026-08-03）：
// - relay 的 `session.list` 下行 payload 形如：
//     { "type": "session.list", "payload": { "sessions": [SessionMeta, ...] } }
// - SessionMeta 来自 relay/internal/session/store.go：
//     { sessionId, cwd, title, updatedAt }
// - 没有 archived / createdAt / archivedAt 字段：归档是中继或端侧的概念。
// - kimi acp 暂无 archive / restore / rename / fork 的官方方法。
//
// 这些探针测试不会触发任何网络，仅用 fixture 校验解析与派生逻辑，作为后续模型
// 演进（archive 字段、工作区分组、时间排序、加载更多）的对照基线。

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Kimi session.list 响应探针', () {
    test('已知字段：sessionId / cwd / title / updatedAt 全部能解析', () {
      final raw = {
        'sessions': [
          {
            'sessionId': 'sid-relay-1',
            'cwd': r'D:\Github-Project\kimi-code-multi-device\relay',
            'title': '你好你是谁',
            'updatedAt': '2026-08-03T15:30:00+08:00',
          },
        ],
      };
      final list = (raw['sessions'] as List)
          .cast<Map>()
          .map((j) => SessionMetaProbe.fromKnown(
                (j).cast<String, dynamic>(),
              ))
          .toList();
      expect(list, hasLength(1));
      final s = list.single;
      expect(s.sessionId, 'sid-relay-1');
      expect(s.title, '你好你是谁');
      expect(s.cwd, contains('relay'));
      expect(s.updatedAt, isNotEmpty);
    });

    test('未知字段被保留但不影响现有 UI（探针目的：未来兼容）', () {
      final raw = {
        'sessionId': 'sid-x',
        'cwd': '/tmp',
        'title': '',
        'updatedAt': '2026-08-03T00:00:00Z',
        // kimi 未来可能新增的字段，先试着读，缺则视为 null。
        'archived': true,
        'archivedAt': '2026-08-03T15:34:00+08:00',
        'createdAt': '2026-08-01T00:00:00Z',
      };
      final s = SessionMetaProbe.fromTolerant(
        raw.cast<String, dynamic>(),
      );
      expect(s.sessionId, 'sid-x');
      expect(s.archived, isTrue,
          reason: '若 kimi 后续返回 archived 字段，模型应能直接解析');
      expect(s.archivedAt, isNotNull);
      expect(s.createdAt, isNotNull);
    });

    test('工作区分组：取 cwd 路径最后两级', () {
      // 约定：始终取路径末两级作为工作区名，深度不影响。
      // 与 home_shell._SessionDrawerState._groupKey 行为一致。
      const cases = <String, String>{
        r'D:\a\b\relay': 'b/relay',
        r'D:\a\b\relay\': 'b/relay',
        r'D:\Github-Project\kimi-code-multi-device\code\kimi-code-multi-device':
            'code/kimi-code-multi-device',
        '/home/x/projects/v0probe': 'projects/v0probe',
        '/single': 'single',
        '': '—',
      };
      cases.forEach((cwd, expectKey) {
        expect(_groupKey(cwd), expectKey,
            reason: 'cwd="$cwd" 应被分成 "$expectKey"');
      });
    });

    test('时间排序：按 updatedAt 倒序，新的在前', () {
      final s = [
        SessionMetaProbe('a', '/x', 'a', '2026-08-01T00:00:00Z'),
        SessionMetaProbe('b', '/x', 'b', '2026-08-03T00:00:00Z'),
        SessionMetaProbe('c', '/x', 'c', '2026-08-02T00:00:00Z'),
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      expect(s.map((e) => e.sessionId).toList(), ['b', 'c', 'a']);
    });

    test('加载更多：每个工作区只取前 N 条，剩余数准确', () {
      const pageSize = 5;
      final all = List.generate(
        12,
        (i) => SessionMetaProbe('sid-$i', '/p/r', 't-$i',
            '2026-08-03T00:${i.toString().padLeft(2, '0')}:00Z'),
      );
      final shown = all.take(pageSize).toList();
      final hidden = all.length - shown.length;
      expect(shown, hasLength(5));
      expect(hidden, 7);
    });
  });

  group('归档能力探针', () {
    test('当前模型无 archived 字段，需要中继补充（gap #1）', () {
      // gap #1: kimi acp session/list 当前不返回 archived；
      // 中继需要在 session.SessionMeta 上扩展，或者端侧维护"归档集合"覆盖层。
      // 这一条探针在文档化已知 gap，不做断言，仅打印。
      // ignore: avoid_print
      print('[probe] gap: kimi acp 未提供 archived/archivedAt 字段');
    });

    test('rename / fork / export / archive 的方法名约定（gap #2）', () {
      // gap #2: 上行消息未定义 session.rename / session.fork / session.export
      // / session.archive / session.restore。这里按端侧需要给出建议名，
      // 等中继在 protocol.go 中补全。
      const wanted = <String>[
        'session.rename',   // { sessionId, title }
        'session.fork',     // { sessionId }  -> 下行 session.created
        'session.export',   // { sessionId, format }  -> 下行 session.export
        'session.archive',  // { sessionId }
        'session.restore',  // { sessionId }
      ];
      expect(wanted, isNotEmpty);
    });
  });
}

// ---------- 探针用纯模型 ----------

class SessionMetaProbe {
  final String sessionId;
  final String cwd;
  final String title;
  final String updatedAt;
  final bool? archived;
  final String? archivedAt;
  final String? createdAt;

  SessionMetaProbe(this.sessionId, this.cwd, this.title, this.updatedAt,
      {this.archived, this.archivedAt, this.createdAt});

  /// 严格模式：只读已知四字段，缺失即空串。
  factory SessionMetaProbe.fromKnown(Map<String, dynamic> j) =>
      SessionMetaProbe(
        j['sessionId']?.toString() ?? '',
        j['cwd']?.toString() ?? '',
        j['title']?.toString() ?? '',
        j['updatedAt']?.toString() ?? '',
      );

  /// 宽容模式：已知字段必读，新字段尽力读；用来评估"若中继补字段，端侧怎么演进"。
  factory SessionMetaProbe.fromTolerant(Map<String, dynamic> j) =>
      SessionMetaProbe(
        j['sessionId']?.toString() ?? '',
        j['cwd']?.toString() ?? '',
        j['title']?.toString() ?? '',
        j['updatedAt']?.toString() ?? '',
        archived: j['archived'] as bool?,
        archivedAt: j['archivedAt']?.toString(),
        createdAt: j['createdAt']?.toString(),
      );
}

String _groupKey(String cwd) {
  final parts = cwd
      .split(RegExp(r'[/\\]'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length >= 2) {
    return '${parts[parts.length - 2]}/${parts.last}';
  }
  return parts.isNotEmpty ? parts.last : '—';
}
