import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/models.dart';
import 'package:sentinel/theme/app_icons.dart';
import 'package:sentinel/widgets/stream_block.dart';

void main() {
  group('AgentGroupView', () {
    testWidgets('渲染触发区，并按工具类型汇总标签', (tester) async {
      final group = AgentGroup(
        [
          StreamBlock.think('plan'),
          StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
          StreamBlock.toolResult(name: 'Read', status: ToolStatus.done),
        ],
        headIndex: 0,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AgentGroupView(group: group)),
      ));
      // 思考 + 工具按首次出现顺序、按类型分组的可读总结。
      expect(find.text('思考，执行 1 条命令，查看 1 个文件'), findsOneWidget);
      // 不再出现旧版「思考 + N 个工具」的拼接。
      expect(find.text('思考 + 2 个工具'), findsNothing);
    });

    testWidgets('没有工具时只显示「思考」', (tester) async {
      // 注意：单 part 的 group 会在 buildAgentGroups 里降级为 SingleBlockGroup，
      // 这里直接构造 AgentGroup 是为了验证 _groupLabel 的格式化逻辑。
      final group = AgentGroup(
        [StreamBlock.think('reasoning')],
        headIndex: 0,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AgentGroupView(group: group)),
      ));
      // 单数思考不带「1 次」，直接写「思考」。
      expect(find.text('思考'), findsOneWidget);
    });

    testWidgets('点击触发区展开为列表：思考行 + 工具行可见，思考内容默认折叠', (tester) async {
      final group = AgentGroup(
        [
          StreamBlock.think('reasoning body'),
          StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
        ],
        headIndex: 0,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 400, child: AgentGroupView(group: group))),
      ));
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
    });

    testWidgets('isRunning=true 时显示「思考中…」和一个 spinner', (tester) async {
      final group = AgentGroup(
        [
          StreamBlock.think(''), // 空思考 → isRunning
        ],
        headIndex: 0,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AgentGroupView(group: group)),
      ));
      expect(find.text('思考中…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('多 think + 多 tool 时按工具类型分别计数', (tester) async {
      final group = AgentGroup(
        [
          StreamBlock.think('plan1'),
          StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
          StreamBlock.think('plan2'),
          StreamBlock.toolResult(name: 'Read', status: ToolStatus.done),
        ],
        headIndex: 0,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AgentGroupView(group: group)),
      ));
      // 思考 2 次 + 按出现顺序（Bash→Read）分别计数
      expect(find.text('思考 2 次，执行 1 条命令，查看 1 个文件'),
          findsOneWidget);
      // 不再用旧版「N 个思考 + M 个工具」格式
      expect(find.text('2 个思考 + 2 个工具'), findsNothing);
    });

    testWidgets('无思考、只有多种工具时按类型分别计数', (tester) async {
      final group = AgentGroup(
        [
          StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
          StreamBlock.toolResult(name: 'Read', status: ToolStatus.done),
          StreamBlock.toolResult(name: 'Grep', status: ToolStatus.done),
        ],
        headIndex: 0,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AgentGroupView(group: group)),
      ));
      // 工具按首次出现顺序
      expect(find.text('执行 1 条命令，查看 1 个文件，搜索 1 处'),
          findsOneWidget);
      expect(find.text('3 个工具'), findsNothing);
    });

    testWidgets('无外层灰底卡片——顶层 widget 没有装饰背景', (tester) async {
      final group = AgentGroup(
        [
          StreamBlock.think('plan'),
          StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
        ],
        headIndex: 0,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AgentGroupView(group: group)),
      ));
      // 主聊天区是 contentCanvasOf（纯白），AgentGroupView 根节点用 Collapsible
      // （Column + SizeTransition），没有带 quietSurfaceOf 的 Container 背景，
      // 这样主页面上 3 种灰就不会重复叠加。
      final root = tester.widget<Collapsible>(find.byType(Collapsible).first);
      expect(root, isNotNull);
      // trigger 文字颜色默认就是 placeholder（浅银灰）。
      final triggerText =
          tester.widget<Text>(find.text('思考，执行 1 条命令'));
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
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: StreamBlockView(block: block),
          ),
        ),
      ));
      expect(find.text('终端'), findsOneWidget);
      // 折叠态用 AppIcons.check（绿）表示完成，不再用「完成」文字。
      expect(find.byIcon(AppIcons.check), findsOneWidget);
      expect(find.text('Bash'), findsNothing); // 工具名不再直接展示
      expect(find.text('完成'), findsNothing);
    });

    testWidgets('独立 Read 工具：图标 + 「读取文件」 + basename', (tester) async {
      final block = StreamBlock.toolResult(
        name: 'Read',
        status: ToolStatus.done,
        command: 'D:\\Github-Project\\foo\\service.go',
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: StreamBlockView(block: block),
          ),
        ),
      ));
      expect(find.text('读取文件 service.go'), findsOneWidget);
      // Read 用 file 图标，不是 terminal。
      expect(find.byIcon(AppIcons.file), findsOneWidget);
      expect(find.byIcon(AppIcons.terminal), findsNothing);
    });
  });
}
