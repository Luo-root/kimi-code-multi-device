// SessionArchiveStore 的基本行为：归档 / 恢复 / 跨实例持久化通过 setter/load。
// 不真正落盘（SharedPreferences mock 比较重），只用内存里的方法路径覆盖核心
// 分支；持久化分支由 setMockInitialValues 校验。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentinel/relay/session_archive_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('首次加载：空集合', () async {
    final s = SessionArchiveStore();
    await s.load();
    expect(s.ids, isEmpty);
    expect(s.isArchived('anything'), isFalse);
  });

  test('archive / restore 触发监听', () async {
    final s = SessionArchiveStore();
    int n = 0;
    s.addListener(() => n++);
    expect(s.archive('sid-1'), isTrue);
    expect(s.archive('sid-1'), isFalse, reason: '重复归档应幂等返回 false');
    expect(s.isArchived('sid-1'), isTrue);
    expect(s.restore('sid-1'), isTrue);
    expect(s.restore('sid-1'), isFalse);
    expect(s.isArchived('sid-1'), isFalse);
    // 真实状态切换两次（archive + restore），幂等调用不通知。
    expect(n, 2);
  });

  test('load() 还原上次持久化结果', () async {
    SharedPreferences.setMockInitialValues({
      'sentinel.archivedSessionIds': <String>['sid-a', 'sid-b'],
    });
    final s = SessionArchiveStore();
    await s.load();
    expect(s.ids, containsAll(['sid-a', 'sid-b']));
  });

  test('archive 后 setStringList 持久化', () async {
    final prefs = await SharedPreferences.getInstance();
    final s = SessionArchiveStore();
    await s.load();
    s.archive('sid-x');
    // _persist 是异步 fire-and-forget；用一个微任务循环让其完成。
    await Future<void>.delayed(Duration.zero);
    final saved = prefs.getStringList('sentinel.archivedSessionIds');
    expect(saved, contains('sid-x'));
  });

  test('archiveAll：批量、幂等、监听一次性', () async {
    final s = SessionArchiveStore();
    await s.load();
    int n = 0;
    s.addListener(() => n++);
    // 1 个新 + 1 个重复 + 1 个新 → 返回 2，监听只触发一次。
    expect(s.archiveAll(['sid-1', 'sid-1', 'sid-2']), 2);
    expect(s.isArchived('sid-1'), isTrue);
    expect(s.isArchived('sid-2'), isTrue);
    // 全部已存在 → 返回 0，不通知。
    expect(s.archiveAll(['sid-1', 'sid-2']), 0);
    expect(n, 1);
  });
}
