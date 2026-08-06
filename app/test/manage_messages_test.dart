import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/manage_messages.dart';
import 'package:sentinel/relay/session_store.dart';

/// 通道② 会话管理消息契约测试。
///
/// 这些断言等价于「relay/internal/relay/protocol.go 的字段名不能改」——
/// 一旦 Go 侧改了 action 取值或 payload 键名，这里必须同步失败，避免两端悄悄漂移。
void main() {
  group('buildManageRequest', () {
    test('只带必填字段时不产生多余键', () {
      final p = buildManageRequest(ManageAction.archive, 'sess-1');
      expect(p, {'action': 'archive', 'sessionId': 'sess-1'});
    });

    test('rename 带 title', () {
      final p = buildManageRequest(ManageAction.rename, 'sess-1', title: '新标题');
      expect(p['action'], 'rename');
      expect(p['title'], '新标题');
      expect(p.containsKey('newSessionId'), isFalse);
    });

    test('fork 可指定 newSessionId 与 options', () {
      final p = buildManageRequest(
        ManageAction.fork,
        'sess-1',
        newSessionId: 'sess-2',
        options: {'version': '0.32.0'},
      );
      expect(p['newSessionId'], 'sess-2');
      expect(p['options'], {'version': '0.32.0'});
    });
  });

  group('ManageAction', () {
    test('枚举取值与 relay ManageAction* 常量一致', () {
      expect(ManageAction.values.map((e) => e.value).toList(),
          ['archive', 'restore', 'rename', 'fork', 'delete', 'export']);
    });

    test('fromValue 往返', () {
      for (final a in ManageAction.values) {
        expect(ManageAction.fromValue(a.value), a);
      }
    });

    test('未知 action 兜底为 archive，不抛异常（前向兼容旧端）', () {
      expect(ManageAction.fromValue('brand-new-action'), ManageAction.archive);
    });
  });

  group('ManagedResult.fromPayload', () {
    test('成功回执', () {
      final r = ManagedResult.fromPayload(
          {'action': 'rename', 'sessionId': 'sess-1', 'ok': true});
      expect(r, isNotNull);
      expect(r!.action, ManageAction.rename);
      expect(r.sessionId, 'sess-1');
      expect(r.ok, isTrue);
      expect(r.error, isNull);
    });

    test('失败回执带 error', () {
      final r = ManagedResult.fromPayload({
        'action': 'delete',
        'sessionId': 'sess-1',
        'ok': false,
        'error': '管理通道未启用',
      });
      expect(r!.ok, isFalse);
      expect(r.error, '管理通道未启用');
    });

    test('fork 回执解析 data.newSessionId（键名与 relay 对齐）', () {
      final r = ManagedResult.fromPayload({
        'action': 'fork',
        'sessionId': 'sess-1',
        'ok': true,
        'data': {'newSessionId': 'sess-2'},
      });
      expect(r!.data?['newSessionId'], 'sess-2');
    });

    test('export 回执解析 data.zipPath（键名与 relay 对齐）', () {
      final r = ManagedResult.fromPayload({
        'action': 'export',
        'sessionId': 'sess-1',
        'ok': true,
        'data': {'zipPath': '/tmp/a.zip', 'entries': <String>[]},
      });
      expect(r!.data?['zipPath'], '/tmp/a.zip');
    });

    test('缺 action 或 sessionId 时返回 null', () {
      expect(ManagedResult.fromPayload({'sessionId': 'sess-1'}), isNull);
      expect(ManagedResult.fromPayload({'action': 'archive'}), isNull);
    });

    test('ok 缺省视为失败（不把未知当成功）', () {
      final r = ManagedResult
          .fromPayload({'action': 'archive', 'sessionId': 'sess-1'});
      expect(r!.ok, isFalse);
    });
  });

  group('SessionStore 接收 session.managed', () {
    test('写入 lastManaged 并通知监听', () {
      final store = SessionStore();
      var notified = 0;
      store.addListener(() => notified++);

      store.handle(kDownSessionManaged, 'sess-1',
          {'action': 'archive', 'sessionId': 'sess-1', 'ok': true});

      expect(notified, 1);
      expect(store.lastManaged, isNotNull);
      expect(store.lastManaged!.action, ManageAction.archive);
      expect(store.lastManaged!.ok, isTrue);
    });

    test('每次回执都是新实例，便于 UI 用 identical 去重', () {
      final store = SessionStore();
      const payload = {'action': 'archive', 'sessionId': 'sess-1', 'ok': true};

      store.handle(kDownSessionManaged, 'sess-1', payload);
      final first = store.lastManaged;
      store.handle(kDownSessionManaged, 'sess-1', payload);
      final second = store.lastManaged;

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(identical(first, second), isFalse);
    });

    test('畸形回执置 null，不残留上一条（避免重复弹 toast）', () {
      final store = SessionStore();
      store.handle(kDownSessionManaged, 'sess-1',
          {'action': 'archive', 'sessionId': 'sess-1', 'ok': true});
      expect(store.lastManaged, isNotNull);

      store.handle(kDownSessionManaged, 'sess-1', {'ok': true});
      expect(store.lastManaged, isNull);
    });
  });
}
