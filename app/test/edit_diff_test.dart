import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/models.dart';

void main() {
  group('parseEditDiff', () {
    test('从 Edit JSON 生成新增、删除与修改摘要', () {
      const input = r'''
{
  "file_path": "lib/service.dart",
  "old_string": "alpha\nbeta\ngamma",
  "new_string": "alpha\nbeta changed\ngamma\ndelta"
}
''';

      final diff = parseEditDiff(input, '');

      expect(diff.filePath, 'lib/service.dart');
      expect(diff.modifications, 1);
      expect(diff.additions, 1);
      expect(diff.removals, 0);
      expect(
        diff.lines
            .where((line) => line.kind == EditDiffKind.modified)
            .single
            .text,
        'beta',
      );
      expect(
        diff.lines
            .where((line) => line.kind == EditDiffKind.modified)
            .single
            .secondaryText,
        'beta changed',
      );
      expect(
        diff.lines.where((line) => line.kind == EditDiffKind.added).single.text,
        'delta',
      );
    });

    test('解析 unified diff 并保留文件路径与行号', () {
      const patch = '''diff --git a/lib/a.dart b/lib/a.dart
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -4,2 +4,3 @@
-old value
+new value
 context
+extra
''';

      final diff = parseEditDiff('', patch);

      expect(diff.filePath, 'lib/a.dart');
      expect(diff.modifications, 1);
      expect(diff.additions, 1);
      expect(diff.removals, 0);
      final modified = diff.lines
          .where((line) => line.kind == EditDiffKind.modified)
          .single;
      expect(modified.oldLine, 4);
      expect(modified.newLine, 4);
      expect(modified.secondaryText, 'new value');
    });

    test('无法识别的数据安全降级为空 diff', () {
      final diff = parseEditDiff('plain edit command', 'updated successfully');
      expect(diff.isEmpty, isTrue);
    });

    test('字段名变体（replace/substitute、filepath）也能解析', () {
      const input = r'''
{
  "filepath": "src/api.ts",
  "find": "const x = 1;",
  "replace": "const x = 2;"
}
''';
      final diff = parseEditDiff(input, '');
      expect(diff.filePath, 'src/api.ts');
      expect(diff.modifications, 1);
      expect(
        diff.lines
            .where((line) => line.kind == EditDiffKind.modified)
            .single
            .text,
        'const x = 1;',
      );
      expect(
        diff.lines
            .where((line) => line.kind == EditDiffKind.modified)
            .single
            .secondaryText,
        'const x = 2;',
      );
    });

    test('嵌套在 input 包装下也能定位到旧/新字符串', () {
      const input = r'''
{
  "input": {
    "path": "lib/x.dart",
    "before": "old",
    "after": "new"
  }
}
''';
      final diff = parseEditDiff(input, '');
      expect(diff.filePath, 'lib/x.dart');
      expect(diff.modifications, 1);
    });
  });

  group('extractToolText', () {
    test('Edit 风格 rawInput 序列化为 JSON,即使标题不是 Edit', () {
      final cmd = extractToolText({
        'title': 'edit',
        'rawInput': {
          'file_path': 'lib/a.dart',
          'old_string': 'a',
          'new_string': 'b',
        },
      });
      expect(cmd, contains('"file_path":"lib/a.dart"'));
      expect(cmd, contains('"old_string":"a"'));
    });

    test('rawInput 是字符串时直接采用', () {
      final cmd = extractToolText({
        'title': 'Edit',
        'rawInput': '{"file_path":"lib/a.dart","old_string":"a","new_string":"b"}',
      });
      expect(cmd, startsWith('{'));
      expect(cmd, contains('"old_string":"a"'));
    });

    test('Bash 风格 rawInput.command 优先于结构化判定', () {
      final cmd = extractToolText({
        'title': 'Bash',
        'rawInput': {
          'command': 'flutter test',
          'old_string': 'unrelated',
          'new_string': 'still unrelated',
        },
      });
      expect(cmd, 'flutter test');
    });
  });
}
