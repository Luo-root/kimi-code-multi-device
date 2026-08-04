import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/models.dart';
import 'package:sentinel/screens/home_shell.dart';

void main() {
  group('latestUserHeadBeforeOffset', () {
    final groups = buildAgentGroups([
      StreamBlock.user('first'),
      StreamBlock.text('reply 1'),
      StreamBlock.user('second'),
      StreamBlock.think('plan'),
      StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
      StreamBlock.text('reply 2'),
      StreamBlock.user('third'),
    ]);
    final offsets = <int, double>{0: 20, 2: 260, 6: 720};

    test('返回当前位置之前最近一条用户消息', () {
      expect(
        latestUserHeadBeforeOffset(groups, 500, (head) => offsets[head]),
        2,
      );
    });

    test('当前位置在首条消息之前时回退到首条用户消息', () {
      expect(latestUserHeadBeforeOffset(groups, 0, (head) => offsets[head]), 0);
    });

    test('忽略尚未测量位置的用户消息', () {
      expect(
        latestUserHeadBeforeOffset(
          groups,
          900,
          (head) => offsets[head == 6 ? -1 : head],
        ),
        2,
      );
    });

    test('没有用户消息时返回 null', () {
      final noUsers = buildAgentGroups([StreamBlock.text('reply')]);
      expect(latestUserHeadBeforeOffset(noUsers, 100, (_) => 0), isNull);
    });
  });
}
