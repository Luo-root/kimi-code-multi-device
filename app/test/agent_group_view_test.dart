import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/models.dart';
import 'package:sentinel/theme/app_icons.dart';
import 'package:sentinel/widgets/markdown.dart';
import 'package:sentinel/widgets/stream_block.dart';

void main() {
  group('AgentGroupView', () {
    testWidgets('渲染触发区，并按工具类型汇总标签', (tester) async {
      final group = AgentGroup([
        StreamBlock.think('plan'),
        StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
        StreamBlock.toolResult(name: 'Read', status: ToolStatus.done),
      ], headIndex: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentGroupView(group: group)),
        ),
      );
      // 思考 + 工具按首次出现顺序、按类型分组的可读总结。
      expect(find.text('思考，执行 1 条命令，查看 1 个文件'), findsOneWidget);
      expect(find.byIcon(AppIcons.thinking), findsOneWidget);
      // 不再出现旧版「思考 + N 个工具」的拼接。
      expect(find.text('思考 + 2 个工具'), findsNothing);
    });

    testWidgets('没有工具时只显示「思考」', (tester) async {
      // 注意：单 part 的 group 会在 buildAgentGroups 里降级为 SingleBlockGroup，
      // 这里直接构造 AgentGroup 是为了验证 _groupLabel 的格式化逻辑。
      final group = AgentGroup([StreamBlock.think('reasoning')], headIndex: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentGroupView(group: group)),
        ),
      );
      // 单数思考不带「1 次」，直接写「思考」。
      expect(find.text('思考'), findsOneWidget);
    });

    testWidgets('点击触发区展开为列表：思考行 + 工具行可见，思考内容默认折叠', (tester) async {
      final group = AgentGroup([
        StreamBlock.think('reasoning body'),
        StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
      ], headIndex: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 400, child: AgentGroupView(group: group)),
          ),
        ),
      );
      // 默认折叠：思考文本与工具动词都不可见
      expect(find.text('reasoning body'), findsNothing);
      expect(find.text('终端'), findsNothing);
      // 点击触发区
      await tester.tap(find.text('思考，执行 1 条命令'));
      await tester.pumpAndSettle();
      // 展开后显示列表行：inline 思考行与工具行均可见
      expect(find.text('思考'), findsOneWidget); // inline 思考行标签
      expect(find.text('终端'), findsOneWidget); // 工具行（Bash → 终端）
      // 思考内容本身默认折叠，不显示
      expect(find.text('reasoning body'), findsNothing);
      // 点击 inline 思考行才展开思考内容
      await tester.tap(find.text('思考'));
      await tester.pumpAndSettle();
      expect(find.text('reasoning body'), findsOneWidget);
      expect(find.byType(MarkdownView), findsOneWidget);
    });

    testWidgets('组内 Bash 工具复用结构化详情卡', (tester) async {
      final group = AgentGroup([
        StreamBlock.think('plan'),
        StreamBlock.toolResult(
          name: 'Bash',
          command: 'flutter analyze',
          output: 'No issues found!',
          status: ToolStatus.done,
        ),
      ], headIndex: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 520, child: AgentGroupView(group: group)),
          ),
        ),
      );

      await tester.tap(find.text('思考，执行 1 条命令'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('终端 flutter analyze'));
      await tester.pumpAndSettle();

      expect(find.text('执行输出'), findsOneWidget);
      expect(find.text('No issues found!'), findsOneWidget);
    });

    testWidgets('isRunning=true 时显示「思考中…」和一个 spinner', (tester) async {
      final group = AgentGroup([
        StreamBlock.think(''), // 空思考 → isRunning
      ], headIndex: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentGroupView(group: group)),
        ),
      );
      expect(find.text('思考中…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('多 think + 多 tool 时按工具类型分别计数', (tester) async {
      final group = AgentGroup([
        StreamBlock.think('plan1'),
        StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
        StreamBlock.think('plan2'),
        StreamBlock.toolResult(name: 'Read', status: ToolStatus.done),
      ], headIndex: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentGroupView(group: group)),
        ),
      );
      // 思考 2 次 + 按出现顺序（Bash→Read）分别计数
      expect(find.text('思考 2 次，执行 1 条命令，查看 1 个文件'), findsOneWidget);
      // 不再用旧版「N 个思考 + M 个工具」格式
      expect(find.text('2 个思考 + 2 个工具'), findsNothing);
    });

    testWidgets('无思考、只有多种工具时按类型分别计数', (tester) async {
      final group = AgentGroup([
        StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
        StreamBlock.toolResult(name: 'Read', status: ToolStatus.done),
        StreamBlock.toolResult(name: 'Grep', status: ToolStatus.done),
      ], headIndex: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentGroupView(group: group)),
        ),
      );
      // 工具按首次出现顺序
      expect(find.text('执行 1 条命令，查看 1 个文件，搜索 1 处'), findsOneWidget);
      expect(find.text('3 个工具'), findsNothing);
    });

    testWidgets('无外层灰底卡片——顶层 widget 没有装饰背景', (tester) async {
      final group = AgentGroup([
        StreamBlock.think('plan'),
        StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
      ], headIndex: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentGroupView(group: group)),
        ),
      );
      // 主聊天区是 contentCanvasOf（纯白），AgentGroupView 根节点用 Collapsible
      // （Column + SizeTransition），没有带 quietSurfaceOf 的 Container 背景，
      // 这样主页面上 3 种灰就不会重复叠加。
      final root = tester.widget<Collapsible>(find.byType(Collapsible).first);
      expect(root, isNotNull);
      // trigger 文字颜色默认就是 placeholder（浅银灰）。
      final triggerText = tester.widget<Text>(find.text('思考，执行 1 条命令'));
      expect(triggerText.style?.color, isNotNull);
    });
  });

  group('StreamBlockView', () {
    testWidgets('独立 tool 块显示「动词 + 目标」与状态图标', (tester) async {
      // Bash 工具无 command 时退化为只显示动词「终端」。
      final block = StreamBlock.toolResult(
        name: 'Bash',
        status: ToolStatus.done,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 400, child: StreamBlockView(block: block)),
          ),
        ),
      );
      expect(find.text('终端'), findsOneWidget);
      // 折叠态用 AppIcons.check（绿）表示完成，不再用「完成」文字。
      expect(find.byIcon(AppIcons.check), findsOneWidget);
      expect(find.text('Bash'), findsNothing); // 工具名不再直接展示
      expect(find.text('完成'), findsNothing);
    });

    testWidgets('独立 Read 工具：展开后显示文件读取卡、路径与读取结果', (tester) async {
      final block = StreamBlock.toolResult(
        name: 'Read',
        status: ToolStatus.done,
        command: 'D:\\Github-Project\\foo\\service.go',
        output: 'package service\n\nfunc Start() {}',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 520, child: StreamBlockView(block: block)),
          ),
        ),
      );
      expect(find.text('读取文件 service.go'), findsOneWidget);
      // Read 用 file 图标，不是 terminal。
      expect(find.byIcon(AppIcons.file), findsOneWidget);
      expect(find.byIcon(AppIcons.terminal), findsNothing);
      expect(find.text('文件读取'), findsNothing);

      await tester.tap(find.text('读取文件 service.go'));
      await tester.pumpAndSettle();

      expect(find.text('路径'), findsOneWidget);
      expect(find.text('D:\\Github-Project\\foo\\service.go'), findsOneWidget);
      expect(find.text('读取结果'), findsOneWidget);
      expect(find.textContaining('func Start'), findsOneWidget);
    });

    testWidgets('独立 Bash 工具：展开后按命令与执行输出分区', (tester) async {
      final block = StreamBlock.toolResult(
        name: 'Bash',
        status: ToolStatus.done,
        command: 'flutter test',
        output: 'All tests passed!',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 520, child: StreamBlockView(block: block)),
          ),
        ),
      );

      await tester.tap(find.text('终端 flutter test'));
      await tester.pumpAndSettle();

      expect(find.text('命令'), findsOneWidget);
      expect(find.text('flutter test'), findsWidgets);
      expect(find.text('执行输出'), findsOneWidget);
      expect(find.text('All tests passed!'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
    });

    testWidgets('独立 Edit 工具：完成后保留行级 diff 与变更摘要', (tester) async {
      final block = StreamBlock.toolResult(
        name: 'Edit',
        status: ToolStatus.done,
        command:
            r'''{"file_path":"lib/service.dart","old_string":"final a = 1;\nkeep","new_string":"final a = 2;\nkeep\nadded"}''',
        output: 'Edit completed',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 720, child: StreamBlockView(block: block)),
          ),
        ),
      );

      expect(find.text('编辑文件 service.dart'), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-diff-details')), findsNothing);

      await tester.tap(find.text('编辑文件 service.dart'));
      await tester.pumpAndSettle();

      expect(find.text('变更摘要'), findsOneWidget);
      expect(find.text('lib/service.dart'), findsOneWidget);
      expect(find.text('final a = 1;'), findsOneWidget);
      expect(find.text('final a = 2;'), findsOneWidget);
      expect(find.text('added'), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-diff-details')), findsOneWidget);
    });

    testWidgets('深色主题 Edit diff 保持完整结构', (tester) async {
      final block = StreamBlock.toolResult(
        name: 'Edit',
        status: ToolStatus.done,
        command:
            r'''{"path":"lib/a.dart","old_string":"old","new_string":"new"}''',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: ThemeMode.dark,
          home: Scaffold(
            body: SizedBox(width: 640, child: StreamBlockView(block: block)),
          ),
        ),
      );

      await tester.tap(find.text('编辑文件 a.dart'));
      await tester.pumpAndSettle();

      expect(find.text('变更摘要'), findsOneWidget);
      expect(find.text('old'), findsOneWidget);
      expect(find.text('new'), findsOneWidget);
    });

    testWidgets('小写 edit 工具名仍走 Edit diff 路径', (tester) async {
      final block = StreamBlock.toolResult(
        name: 'edit',
        status: ToolStatus.done,
        command: r'{"path":"lib/a.dart","find":"a","replace":"b"}',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 720, child: StreamBlockView(block: block)),
          ),
        ),
      );
      await tester.tap(find.text('编辑文件 a.dart'));
      await tester.pumpAndSettle();
      expect(find.text('变更摘要'), findsOneWidget);
    });

    testWidgets('Terminal 类工具名也走 Shell 分区(命令/执行输出)', (tester) async {
      final block = StreamBlock.toolResult(
        name: 'Terminal',
        status: ToolStatus.done,
        command: 'echo hi',
        output: 'hi',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 720, child: StreamBlockView(block: block)),
          ),
        ),
      );
      await tester.tap(find.text('终端 echo hi'));
      await tester.pumpAndSettle();
      expect(find.text('命令'), findsOneWidget);
      expect(find.text('执行输出'), findsOneWidget);
    });

    testWidgets('独立思考展开后使用 MarkdownView 渲染', (tester) async {
      final block = StreamBlock.think(
        '## 检查步骤\n\n- **读取**配置\n- 执行 `flutter test`',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 520, child: StreamBlockView(block: block)),
          ),
        ),
      );

      expect(find.byType(MarkdownView), findsNothing);
      expect(find.byIcon(AppIcons.thinking), findsOneWidget);
      await tester.tap(find.text('思考'));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownView), findsOneWidget);
      expect(find.textContaining('检查步骤'), findsWidgets);
      expect(find.textContaining('读取'), findsWidgets);
      expect(find.textContaining('flutter test'), findsWidgets);
    });
  });
}
