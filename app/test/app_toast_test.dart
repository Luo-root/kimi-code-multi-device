// showAppToast 的回归护栏。
//
// 背景：hux 的 snackbar 有两个硬伤——① 走 ScaffoldMessenger，画在 Scaffold 内部，
// 抽屉打开时会被遮住；② 卡片宽度在其私有 body 里硬编码成 400，短文案会拉出一条
// 过长的横条，且无法从外部约束。故自建 root overlay toast。
// 这两点是用户明确提过的体验要求，这里锁住，避免回退。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/widgets/common.dart';

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox.expand());
      }),
    ));
    return ctx;
  }

  testWidgets('toast 宽度取 hux 默认（400）的三分之二', (tester) async {
    final ctx = await pumpHost(tester);
    showAppToast(ctx, message: '已复制', variant: AppToastVariant.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 入场动画结束

    final card = find.byKey(const ValueKey(kAppToastCardKey));
    expect(card, findsOneWidget);
    expect(tester.getSize(card).width, 268);
  });

  testWidgets('toast 到时自动收起，不残留 OverlayEntry', (tester) async {
    final ctx = await pumpHost(tester);
    showAppToast(ctx, message: '已复制', variant: AppToastVariant.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('已复制'), findsOneWidget);

    // success 默认 1000ms 停留 + 140ms 退场。
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(kAppToastCardKey)), findsNothing);
  });

  testWidgets('新 toast 顶掉旧的，同时只存在一条', (tester) async {
    final ctx = await pumpHost(tester);
    showAppToast(ctx, message: '第一条');
    await tester.pump();
    showAppToast(ctx, message: '第二条');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey(kAppToastCardKey)), findsOneWidget);
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('toast 文案不带下划线（Overlay 内缺 Material 会回落到黄色双下划线）',
      (tester) async {
    final ctx = await pumpHost(tester);
    showAppToast(ctx,
        message: '已复制',
        variant: AppToastVariant.error,
        actionLabel: '详情',
        onAction: () {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 卡片内每一个 Text 的实际生效样式都不得带 decoration。
    // 裸 Overlay 下 DefaultTextStyle 会回落成 红字 + TextDecoration.underline
    // + 黄色 double 下划线，正是用户看到的那条黄线。
    final texts = find.descendant(
      of: find.byKey(const ValueKey(kAppToastCardKey)),
      matching: find.byType(Text),
    );
    expect(texts, findsWidgets);
    for (final t in tester.widgetList<Text>(texts)) {
      final effective = DefaultTextStyle.of(
        tester.element(find.byWidget(t)),
      ).style.merge(t.style);
      expect(effective.decoration ?? TextDecoration.none, TextDecoration.none,
          reason: '「${t.data}」不应带下划线');
    }
    await tester.pumpAndSettle();
  });

  testWidgets('toast 落在 root overlay：抽屉打开时依然可见', (tester) async {
    final key = GlobalKey<ScaffoldState>();
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        key: key,
        drawer: const Drawer(child: SizedBox.expand()),
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        }),
      ),
    ));
    key.currentState!.openDrawer();
    await tester.pumpAndSettle();

    showAppToast(ctx, message: '已归档');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('已归档'), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
