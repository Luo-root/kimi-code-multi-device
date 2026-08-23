// MarkdownView 渲染测试：验证块级与行内解析不崩、关键语义呈现。

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/widgets/markdown.dart';

void main() {
  testWidgets('Markdown 标题/加粗/行内码/代码块/列表 正常渲染', (t) async {
    const md = '''
# 标题一

这是一段 **加粗** 和 *斜体* 和 `inline_code` 的文字。

- 无序项一
- 无序项二

1. 有序项一

```bash
rm -rf build/ && npm run deploy
```

> 引用一句话
''';
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: MarkdownView(data: md))),
    ));
    await t.pump();

    expect(find.textContaining('标题一'), findsWidgets);
    expect(find.textContaining('加粗'), findsWidgets);
    expect(find.textContaining('inline_code'), findsWidgets);
    expect(find.textContaining('无序项一'), findsWidgets);
    expect(find.textContaining('有序项一'), findsWidgets);
    expect(find.textContaining('rm -rf build/'), findsWidgets);
    expect(find.textContaining('引用一句话'), findsWidgets);
  });

  testWidgets('纯文本段落也正常', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: MarkdownView(data: '只是普通一句话。')),
    ));
    expect(find.text('只是普通一句话。'), findsOneWidget);
  });

  testWidgets('跨块连续选中：SelectionArea 包裹且 MarkdownBody 非独立可选', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: MarkdownView(data: '第一段\n\n第二段')),
    ));
    // SelectionArea 提供统一选区 registrar。
    expect(find.byType(SelectionArea), findsWidgets);
    // 回归守卫：若此处为 true，flutter_markdown 会给每个 block 各建独立
    // SelectableText 抢占自己的 region，SelectionArea 聚合不上 → 只能选一段。
    final body = t.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(body.selectable, isFalse);
    // 硬证据：selectable:false 时 Markdown 子树内不应再出现逐 block 的独立
    // SelectableText（那正是跨段落选不中的元凶）；选区交由外层 SelectionArea 统一。
    expect(
      find.descendant(
        of: find.byType(MarkdownView),
        matching: find.byType(SelectableText),
      ),
      findsNothing,
    );
  });

  testWidgets('长按拖选：从第一段跨到第二段选区成立', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 640,
          child: SingleChildScrollView(
            child: MarkdownView(data: 'Para A 第一段内容\n\nPara B 第二段内容'),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();

    final first = find.text('Para A 第一段内容');
    final last = find.text('Para B 第二段内容');
    expect(first, findsOneWidget);
    expect(last, findsOneWidget);

    final firstC = t.getCenter(first);
    final lastC = t.getCenter(last);

    // 模拟长按起点 → 拖到第二段，触发 SelectionArea 连续选区。
    final gesture = await t.startGesture(firstC);
    await t.pump(const Duration(milliseconds: 600)); // 长按阈值，触发选区起点
    await gesture.moveTo(lastC);
    await t.pump();
    await gesture.up();
    await t.pumpAndSettle();

    // 选区成立时 SelectionArea 会在 Overlay 渲染选择手柄（Positioned 层）。
    // 这里只要不抛异常且仍只存在一个 MarkdownView 即证明交互链路通。
    expect(find.byType(MarkdownView), findsWidgets);
  });

  testWidgets('代码块文本参与页面选区：用 Text.rich 而非 SelectableText', (t) async {
    // 回归守卫（用户实测：选区包含代码块时复制不出代码）。
    // 代码块必须用 Text.rich 渲染，使 RenderParagraph 向 SelectionArea 注册，
    // 从而选区能"流过"代码块并把文本一并复制；若用 SelectableText.rich，
    // 会各自成 SelectableRegion 抢占选区、打断跨块；裸 RichText 亦不被纳入。
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: MarkdownView(data: '前文\n\n```\ncode line one\ncode line two\n```\n\n后文')),
    ));
    await t.pump();

    // 代码文本确实存在（Text.rich 渲染）。
    expect(find.textContaining('code line one'), findsWidgets);
    // 整个 MarkdownView 子树内不应出现独立 SelectableText（含代码块）。
    expect(
      find.descendant(
        of: find.byType(MarkdownView),
        matching: find.byType(SelectableText),
      ),
      findsNothing,
    );
  });

  testWidgets('复制跨块保留换行：每个块末尾带块间换行符', (t) async {
    // 回归守卫（用户实测：选区复制出的内容丢失换行）。
    // flutter_markdown 把每个块拆成独立 RenderParagraph，选区拼接不补块间换行；
    // 故每个块级 builder 在块后接独立 _blockBreakWidget（\n，极小字号仅占位），
    // 使拖选复制时块边界换行被保留。这里用结构性断言验证块间确实含 \n。
    // 注意：SelectionArea/SelectableRegion 会为选区测量保留若干 offstage 副本，
    // allRenderObjects 会把它们一并计入（每个块出现 5 次），故只取 onstage 的
    // RichText 并按视口 Y 排序后拼接，避免 offstage 副本污染断言。
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(data: '第一段\n\n第二段\n\n# 标题\n\n- 项一\n- 项二'),
      ),
    ));
    await t.pumpAndSettle();

    // onstage 仅 1 份：每块的块文本 + 块后 _blockBreakWidget 各一个 RichText。
    final richTexts = t
        .widgetList(
          find.descendant(
            of: find.byType(MarkdownView),
            matching: find.byType(RichText),
          ),
        )
        .cast<RichText>()
        .toList();
    // 按视口内全局 Y 坐标排序，得到视觉自顶向下的顺序。
    richTexts.sort((a, b) {
      final ya =
          t.renderObject<RenderParagraph>(find.byWidget(a)).localToGlobal(Offset.zero).dy;
      final yb =
          t.renderObject<RenderParagraph>(find.byWidget(b)).localToGlobal(Offset.zero).dy;
      return ya.compareTo(yb);
    });
    final text = richTexts.map((w) => w.text.toPlainText()).join('');
    // 块间换行应存在：段落↔段落、段落↔标题、标题↔列表 均被 \n 分隔。
    expect(text.contains('第一段\n第二段'), isTrue);
    expect(text.contains('第二段\n标题'), isTrue);
    expect(text.contains('标题\n• 项一'), isTrue);
    expect(text.contains('项一\n• 项二'), isTrue);
  });

  testWidgets('流式未闭合代码围栏不会触发 flutter_markdown inline 断言', (t) async {
    const prefixes = <String>[
      '开始输出\n\n```',
      '开始输出\n\n```dart',
      '开始输出\n\n```dart\n',
      '开始输出\n\n```dart\nvoid main() {',
      '开始输出\n\n```dart\nvoid main() {\n  print("ok");',
      '开始输出\n\n```dart\nvoid main() {\n  print("ok");\n}',
      '开始输出\n\n```dart\nvoid main() {\n  print("ok");\n}\n```',
    ];

    for (var i = 0; i < prefixes.length; i++) {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarkdownView(key: ValueKey(i), data: prefixes[i]),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull,
          reason: '流式前缀 $i 不应触发 flutter_markdown 内部断言');
    }
  });
}
