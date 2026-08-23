import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sentinel/screens/home_shell.dart';
import 'package:sentinel/theme/app_dimens.dart';
import 'package:sentinel/theme/app_icons.dart';
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
              onAttachImage: () {},
              onAttachFile: () {},
              onEnhance: () {},
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
    // 180dp 无法容纳「+ / 优化药丸 / 停止」三控件，故用贴近真机的窄屏 320dp 做溢出回归。
    await tester.pumpWidget(host(width: 320, running: true));
    final stopBefore = tester.getRect(find.byKey(const ValueKey('composer-stop')));

    await enter(tester, '一段很长的中文内容用于测试窄屏换行\n第二行');

    final stopAfter = tester.getRect(find.byKey(const ValueKey('composer-stop')));
    expect(stopAfter.bottom, greaterThan(stopBefore.bottom));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('composer-stop')), findsOneWidget);
  });

  testWidgets('有文字输入时显示优化图标，enhanced 后变还原图标', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ComposerInputBar(
              enabled: true,
              running: false,
              controller: controller,
              onSend: (_) {},
              onStop: () {},
              onChanged: (_) {},
              onAttachImage: () {},
              onAttachFile: () {},
              hasText: true,
              enhancePhase: 'idle',
              onEnhance: () {},
            ),
          ),
        ),
      ),
    ));
    expect(find.byIcon(AppIcons.enhance), findsOneWidget);

    // 切换到 enhanced：图标变为「还原」。
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ComposerInputBar(
              enabled: true,
              running: false,
              controller: controller,
              onSend: (_) {},
              onStop: () {},
              onChanged: (_) {},
              onAttachImage: () {},
              onAttachFile: () {},
              hasText: true,
              enhancePhase: 'enhanced',
              onEnhance: () {},
            ),
          ),
        ),
      ),
    ));
    expect(find.byIcon(AppIcons.revert), findsOneWidget);
    expect(find.byIcon(AppIcons.enhance), findsNothing);
  });

  testWidgets('无文字输入时隐藏优化图标', (tester) async {
    await tester.pumpWidget(host()); // host 默认 hasText=false
    expect(find.byIcon(AppIcons.enhance), findsNothing);

    // 即便 phase 为 enhanced，无文字也应隐藏。
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ComposerInputBar(
              enabled: true,
              running: false,
              controller: controller,
              onSend: (_) {},
              onStop: () {},
              onChanged: (_) {},
              onAttachImage: () {},
              onAttachFile: () {},
              hasText: false,
              enhancePhase: 'enhanced',
              onEnhance: () {},
            ),
          ),
        ),
      ),
    ));
    expect(find.byIcon(AppIcons.revert), findsNothing);
  });

  testWidgets('真实输入经 onChanged 重建后图标出现/消失（回归 #hasText 不刷新）',
      (tester) async {
    // 复刻 _HomeShellState._onInputChanged：输入经 onChanged 更新 hasText 并重建。
    // 旧实现里 onChanged 不触发 hasText 重建，导致输入文字后优化图标仍被隐藏。
    bool hasText = false;
    final widget = MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Center(
            child: SizedBox(
              width: 420,
              child: ComposerInputBar(
                enabled: true,
                running: false,
                controller: controller,
                onSend: (_) {},
                onStop: () {},
                onChanged: (v) => setState(() => hasText = v.trim().isNotEmpty),
                onAttachImage: () {},
                onAttachFile: () {},
                hasText: hasText,
                enhancePhase: 'idle',
                onEnhance: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(widget);
    expect(find.byIcon(AppIcons.enhance), findsNothing);

    // 输入文字 → 经 onChanged 重建 → 图标出现。
    await tester.enterText(find.byKey(const ValueKey('composer-input')), 'foo');
    await tester.pump();
    expect(find.byIcon(AppIcons.enhance), findsOneWidget);

    // 清空 → 图标再次隐藏。
    await tester.enterText(find.byKey(const ValueKey('composer-input')), '');
    await tester.pump();
    expect(find.byIcon(AppIcons.enhance), findsNothing);
  });

  testWidgets('enhancing 阶段显示转圈（不论有无文字）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ComposerInputBar(
              enabled: true,
              running: false,
              controller: controller,
              onSend: (_) {},
              onStop: () {},
              onChanged: (_) {},
              onAttachImage: () {},
              onAttachFile: () {},
              hasText: false,
              enhancePhase: 'enhancing',
              onEnhance: () {},
            ),
          ),
        ),
      ),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(AppIcons.enhance), findsNothing);
  });

  testWidgets('点击优化图标触发 onEnhance', (tester) async {
    var called = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ComposerInputBar(
              enabled: true,
              running: false,
              controller: controller,
              onSend: (_) {},
              onStop: () {},
              onChanged: (_) {},
              onAttachImage: () {},
              onAttachFile: () {},
              hasText: true,
              enhancePhase: 'idle',
              onEnhance: () => called = true,
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byIcon(AppIcons.enhance));
    await tester.pump();

    expect(called, isTrue);
  });

  testWidgets('Enter 发送，Shift+Enter 插入真实换行并保留焦点', (tester) async {
    String? submitted;
    String? changed;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ComposerTextField(
          enabled: true,
          running: false,
          controller: controller,
          focusNode: focusNode,
          onSubmit: (value) => submitted = value,
          onChanged: (value) => changed = value,
        ),
      ),
    ));

    await tester.enterText(find.byKey(const ValueKey('composer-input')), '第一行');
    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();

    expect(controller.text, '第一行\n');
    expect(changed, '第一行\n');
    expect(submitted, isNull);
    expect(focusNode.hasFocus, isTrue);

    await tester.enterText(find.byKey(const ValueKey('composer-input')), '准备发送');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submitted, '准备发送');
  });

  testWidgets('IME composing 或运行中时 Enter 不发送', (tester) async {
    var submissions = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ComposerTextField(
          enabled: true,
          running: false,
          controller: controller,
          onSubmit: (_) => submissions++,
          onChanged: (_) {},
        ),
      ),
    ));
    controller.value = const TextEditingValue(
      text: '拼音',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-input')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submissions, 0);

    controller.value = const TextEditingValue(
      text: '已完成',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ComposerTextField(
          enabled: true,
          running: true,
          controller: controller,
          onSubmit: (_) => submissions++,
          onChanged: (_) {},
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('composer-input')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submissions, 0);
  });

  testWidgets('软键盘 onSubmitted 与 Enter 共用 IME 和运行态保护', (tester) async {
    String? submitted;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ComposerTextField(
          enabled: true,
          running: false,
          controller: controller,
          onSubmit: (value) => submitted = value,
          onChanged: (_) {},
        ),
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('composer-input')), '软键盘发送');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(submitted, '软键盘发送');
  });

  testWidgets('+ 按钮展开内联下拉菜单，显示图片和文件选项', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey('composer-plus')));
    await tester.pumpAndSettle();

    expect(find.text('图片'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
  });

  testWidgets('选择下拉菜单中的图片项触发 onAttachImage', (tester) async {
    var imageCalled = false;
    var fileCalled = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ComposerInputBar(
              enabled: true,
              running: false,
              controller: controller,
              onSend: (_) {},
              onStop: () {},
              onChanged: (_) {},
              onAttachImage: () => imageCalled = true,
              onAttachFile: () => fileCalled = true,
              onEnhance: () {},
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const ValueKey('composer-plus')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('图片'));
    await tester.pumpAndSettle();

    expect(imageCalled, isTrue);
    expect(fileCalled, isFalse);
  });

  testWidgets('选择下拉菜单中的文件项触发 onAttachFile', (tester) async {
    var imageCalled = false;
    var fileCalled = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ComposerInputBar(
              enabled: true,
              running: false,
              controller: controller,
              onSend: (_) {},
              onStop: () {},
              onChanged: (_) {},
              onAttachImage: () => imageCalled = true,
              onAttachFile: () => fileCalled = true,
              onEnhance: () {},
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const ValueKey('composer-plus')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();

    expect(imageCalled, isFalse);
    expect(fileCalled, isTrue);
  });
}
