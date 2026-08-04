import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sentinel/screens/home_shell.dart';
import 'package:sentinel/theme/app_dimens.dart';
import 'package:sentinel/theme/app_theme.dart';

void main() {
  late TextEditingController controller;

  setUp(() {
    controller = TextEditingController();
  });

  tearDown(() {
    controller.dispose();
  });

  Widget host({double width = 420, bool running = false}) {
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: ComposerInputBar(
              enabled: true,
              running: running,
              controller: controller,
              onSend: (_) {},
              onStop: () {},
              onChanged: (_) {},
              onOpenPlus: () {},
            ),
          ),
        ),
      ),
    );
  }

  Future<void> enter(WidgetTester tester, String value) async {
    await tester.enterText(find.byKey(const ValueKey('composer-input')), value);
    await tester.pump();
  }

  double barHeight(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey('composer-bar'))).height;

  testWidgets('空输入和单行输入保持默认紧凑高度', (tester) async {
    await tester.pumpWidget(host());
    final emptyHeight = barHeight(tester);

    await enter(tester, '检查当前状态');

    expect(barHeight(tester), emptyHeight);
    expect(find.byKey(const ValueKey('composer-plus')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-send')), findsOneWidget);
  });

  testWidgets('手动换行会按内容增高，按钮仍保持底部对齐', (tester) async {
    await tester.pumpWidget(host());
    final oneLineHeight = barHeight(tester);
    final decoration = tester
        .widget<Container>(find.byKey(const ValueKey('composer-bar')))
        .decoration!;
    expect(decoration, isA<BoxDecoration>());
    final oneLineRadius = (decoration as BoxDecoration).borderRadius!;
    expect(oneLineRadius, isA<BorderRadius>());
    expect((oneLineRadius as BorderRadius).topLeft.x, AppRadius.card);

    final plusBefore = tester.getRect(find.byKey(const ValueKey('composer-plus')));
    final sendBefore = tester.getRect(find.byKey(const ValueKey('composer-send')));

    await enter(tester, '第一行\n第二行');

    expect(barHeight(tester), greaterThan(oneLineHeight));
    final plusAfter = tester.getRect(find.byKey(const ValueKey('composer-plus')));
    final sendAfter = tester.getRect(find.byKey(const ValueKey('composer-send')));
    expect(plusAfter.bottom, closeTo(sendAfter.bottom, 0.01));
    expect(plusAfter.bottom, greaterThan(plusBefore.bottom));
    expect(sendAfter.bottom, greaterThan(sendBefore.bottom));
  });

  testWidgets('达到六行后继续输入不会撑高外层，输入区保留内部滚动', (tester) async {
    await tester.pumpWidget(host());
    await enter(tester, List<String>.generate(6, (i) => '第 ${i + 1} 行').join('\n'));
    final sixLineHeight = barHeight(tester);

    await enter(
      tester,
      List<String>.generate(12, (i) => '第 ${i + 1} 行，继续输入更长内容').join('\n'),
    );

    expect(barHeight(tester), closeTo(sixLineHeight, 1.0));
    expect(find.byType(Scrollable), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空内容后恢复默认高度', (tester) async {
    await tester.pumpWidget(host());
    await enter(tester, '第一行\n第二行\n第三行');
    final expandedHeight = barHeight(tester);

    await enter(tester, '');

    expect(barHeight(tester), lessThan(expandedHeight));
  });

  testWidgets('窄屏下输入框不产生布局溢出，停止按钮也不位移', (tester) async {
    await tester.pumpWidget(host(width: 180, running: true));
    final stopBefore = tester.getRect(find.byKey(const ValueKey('composer-stop')));

    await enter(tester, '一段很长的中文内容用于测试窄屏换行\n第二行');

    final stopAfter = tester.getRect(find.byKey(const ValueKey('composer-stop')));
    expect(stopAfter.bottom, greaterThan(stopBefore.bottom));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('composer-stop')), findsOneWidget);
  });
}
