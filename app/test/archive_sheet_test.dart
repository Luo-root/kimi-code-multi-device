// 归档弹窗 smoke：能渲染、显示空态/有数据两种情况、按工作区筛选。
// 直接 pump ArchiveSheet 而不是 showHuxBottomSheet：弹窗壳子是 Hux 库的事，
// 弹出来时只要 context 正确即可（实际接入由 home_shell 调用 showArchiveSheet）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hux/hux.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentinel/relay/relay_client.dart';
import 'package:sentinel/relay/session_archive_store.dart';
import 'package:sentinel/relay/session_store.dart';
import 'package:sentinel/screens/archive_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('空集合：标题 + 空态', (t) async {
    final store = SessionStore();
    final archive = SessionArchiveStore();
    await archive.load();
    final client = RelayClient();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArchiveSheet(store: store, archive: archive, client: client),
      ),
    ));
    await t.pump();
    // 弹窗内部没有"已归档会话"标题（标题在 HuxBottomSheet 壳子），
    // 但应该有搜索框、空态文案与排序 tabs。
    expect(find.byType(HuxInput), findsOneWidget);
    expect(find.text('无已归档会话'), findsOneWidget);
    expect(find.text('归档时间'), findsOneWidget);
    expect(find.text('创建时间'), findsOneWidget);
    expect(find.text('按字母顺序'), findsOneWidget);
  });

  testWidgets('有归档会话：渲染卡片 + 未归档的会话不出现', (t) async {
    final store = SessionStore();
    store.handle('session.list', null, {
      'sessions': [
        {
          'sessionId': 'sid-a',
          'cwd': r'D:\a\b\relay',
          'title': '你好',
          'updatedAt': '2026-08-03T15:30:00+08:00',
        },
        {
          'sessionId': 'sid-b',
          'cwd': r'D:\a\b\relay',
          'title': '山东',
          'updatedAt': '2026-08-02T10:00:00+08:00',
        },
        {
          'sessionId': 'sid-c',
          'cwd': r'D:\a\b\relay',
          'title': '未归档的会话',
          'updatedAt': '2026-08-01T10:00:00+08:00',
        },
      ],
    });
    final archive = SessionArchiveStore();
    await archive.load();
    archive.archive('sid-a');
    archive.archive('sid-b');
    final client = RelayClient();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArchiveSheet(store: store, archive: archive, client: client),
      ),
    ));
    await t.pump();
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('山东'), findsOneWidget);
    expect(find.text('未归档的会话'), findsNothing,
        reason: '未归档的会话不应出现在归档弹窗');
    expect(find.text('无已归档会话'), findsNothing);
  });

  testWidgets('工作区筛选：下拉菜单 + 选中过滤', (t) async {
    final store = SessionStore();
    store.handle('session.list', null, {
      'sessions': [
        {
          'sessionId': 'sid-a',
          'cwd': r'D:\code\relay',
          'title': 'relay-a',
          'updatedAt': '2026-08-03T15:30:00+08:00',
        },
        {
          'sessionId': 'sid-b',
          'cwd': r'D:\code\guard',
          'title': 'guard-b',
          'updatedAt': '2026-08-02T10:00:00+08:00',
        },
      ],
    });
    final archive = SessionArchiveStore();
    await archive.load();
    archive.archive('sid-a');
    archive.archive('sid-b');
    final client = RelayClient();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArchiveSheet(store: store, archive: archive, client: client),
      ),
    ));
    await t.pump();

    // 默认显示所有。
    expect(find.text('relay-a'), findsOneWidget);
    expect(find.text('guard-b'), findsOneWidget);

    // 默认下拉框应该展示「所有工作区」。
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('archive-ws-dropdown')),
            matching: find.text('所有工作区')),
        findsOneWidget);

    // HuxDropdown 用 showDialog 弹层，没有 tooltip。直接 tap 触发器展开。
    await t.tap(find.byKey(const ValueKey('archive-ws-dropdown')));
    await t.pumpAndSettle();
    // 弹层里 "code/relay" 是 HuxDropdown 渲染的 item row。
    final item = find.text('code/relay');
    expect(item, findsWidgets);
    await t.tap(item.last);
    await t.pumpAndSettle();

    // 下拉框现在展示 "code/relay"。
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('archive-ws-dropdown')),
            matching: find.text('code/relay')),
        findsOneWidget);
    expect(find.text('relay-a'), findsOneWidget);
    expect(find.text('guard-b'), findsNothing);
  });
}
