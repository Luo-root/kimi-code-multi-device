// MarkdownView 渲染测试：验证块级与行内解析不崩、关键语义呈现。

import 'package:flutter/material.dart';
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
