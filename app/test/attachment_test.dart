import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/models.dart';
import 'package:sentinel/widgets/stream_block.dart';

void main() {
  group('Attachment 模型', () {
    test('JSON 往返保留字段', () {
      const a = Attachment(
        name: 'shot.png',
        mimeType: 'image/png',
        path: r'C:\Users\me\shot.png',
        isImage: true,
        size: 2048,
      );
      final back = Attachment.fromJson(a.toJson());
      expect(back.name, 'shot.png');
      expect(back.mimeType, 'image/png');
      expect(back.path, r'C:\Users\me\shot.png');
      expect(back.isImage, isTrue);
      expect(back.size, 2048);
    });

    test('StreamBlock.user 携带附件并可被历史回放重建', () {
      final block = StreamBlock.user(
        '看看这张图',
        [const Attachment(name: 'a.png', path: '/tmp/a.png', isImage: true)],
      );
      expect(block.attachments, hasLength(1));
      final rebuilt = StreamBlock.user(
        block.text,
        [Attachment.fromJson(block.attachments.first.toJson())],
      );
      expect(rebuilt.attachments.first.name, 'a.png');
    });
  });

  group('用户消息渲染', () {
    testWidgets('文件附件渲染文件名（点击用系统程序打开）', (tester) async {
      final block = StreamBlock.user(
        '看这个文档',
        [
          Attachment(
            name: 'notes.txt',
            path: r'C:\x\notes.txt',
            isImage: false,
            size: 1234,
          )
        ],
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StreamBlockView(block: block))),
      );
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('看这个文档'), findsOneWidget);
    });

    testWidgets('图片附件缺失文件时走 errorBuilder 兜底，不抛异常', (tester) async {
      final block = StreamBlock.user(
        '图片',
        [
          Attachment(
            name: 'missing.png',
            path: r'C:\no\such.png',
            isImage: true,
            mimeType: 'image/png',
          )
        ],
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: StreamBlockView(block: block))),
      );
      expect(find.text('图片'), findsOneWidget);
    });
  });
}
