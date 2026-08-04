import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/models.dart';

void main() {
  group('buildAgentGroups', () {
    test('空列表 → 空', () {
      expect(buildAgentGroups([]), isEmpty);
    });

    test('单 user 块独立成 SingleBlockGroup', () {
      final groups = buildAgentGroups([StreamBlock.user('hi')]);
      expect(groups, hasLength(1));
      expect(groups.first, isA<SingleBlockGroup>());
      expect((groups.first as SingleBlockGroup).block.kind, BlockKind.user);
    });

    test('单 text 块独立成 SingleBlockGroup', () {
      final groups = buildAgentGroups([StreamBlock.text('hello')]);
      expect(groups, hasLength(1));
      expect(groups.first, isA<SingleBlockGroup>());
      expect((groups.first as SingleBlockGroup).block.kind, BlockKind.text);
    });

    test('单 think 块降级为 SingleBlockGroup（避免双层折叠）', () {
      // 单 think 没有合并价值，退化成 SingleBlockGroup，渲染时直接走 StreamBlockView，
      // 不会出现「思考 › 思考 ›」的双层触发行。
      final groups = buildAgentGroups([StreamBlock.think('reasoning')]);
      expect(groups, hasLength(1));
      expect(groups.first, isA<SingleBlockGroup>());
      expect((groups.first as SingleBlockGroup).block.kind, BlockKind.think);
      expect((groups.first as SingleBlockGroup).block.text, 'reasoning');
    });

    test('单 tool 块降级为 SingleBlockGroup', () {
      // 同样的原则：单 tool 也降级，避免「1 个工具 › Bash 完成 ›」这种冗余嵌套。
      final groups = buildAgentGroups([
        StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
      ]);
      expect(groups, hasLength(1));
      expect(groups.first, isA<SingleBlockGroup>());
      expect((groups.first as SingleBlockGroup).block.kind, BlockKind.tool);
    });

    test('think + 连续 tool 合并成一组', () {
      final groups = buildAgentGroups([
        StreamBlock.think('plan'),
        StreamBlock.tool(name: 'Bash'),
        StreamBlock.tool(name: 'Read'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.first, isA<AgentGroup>());
      final g = groups.first as AgentGroup;
      expect(g.toolCount, 2);
      expect(g.thinkCount, 1);
      expect(g.tools[0].toolName, 'Bash');
      expect(g.tools[1].toolName, 'Read');
    });

    test('think + tool + text 切分成 2 组', () {
      final groups = buildAgentGroups([
        StreamBlock.think('plan'),
        StreamBlock.tool(name: 'Bash'),
        StreamBlock.text('answer'),
      ]);
      expect(groups, hasLength(2));
      expect(groups[0], isA<AgentGroup>());
      expect((groups[0] as AgentGroup).toolCount, 1);
      expect(groups[1], isA<SingleBlockGroup>());
      expect((groups[1] as SingleBlockGroup).block.kind, BlockKind.text);
    });

    test('user 后的孤立 tool 块降级为 SingleBlockGroup', () {
      final groups = buildAgentGroups([
        StreamBlock.user('hi'),
        StreamBlock.tool(name: 'Bash'),
        StreamBlock.text('response'),
      ]);
      expect(groups, hasLength(3));
      expect(groups[0], isA<SingleBlockGroup>());
      expect((groups[0] as SingleBlockGroup).block.kind, BlockKind.user);
      expect(groups[1], isA<SingleBlockGroup>());
      expect((groups[1] as SingleBlockGroup).block.kind, BlockKind.tool);
      expect(groups[2], isA<SingleBlockGroup>());
      expect((groups[2] as SingleBlockGroup).block.kind, BlockKind.text);
    });

    test('think+tool+think+tool 任意顺序都合并成 1 组', () {
      // 关键场景：用户反馈「工具接思考也要合并」——以前会被切成 2 组。
      final groups = buildAgentGroups([
        StreamBlock.think('plan1'),
        StreamBlock.tool(name: 'Bash'),
        StreamBlock.think('plan2'),
        StreamBlock.tool(name: 'Read'),
        StreamBlock.tool(name: 'Grep'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.first, isA<AgentGroup>());
      final g = groups.first as AgentGroup;
      expect(g.thinkCount, 2);
      expect(g.toolCount, 3);
      // parts 顺序保持原 blocks 顺序，思考和工具可交错。
      expect(g.parts[0].kind, BlockKind.think);
      expect(g.parts[1].kind, BlockKind.tool);
      expect(g.parts[2].kind, BlockKind.think);
      expect(g.parts[3].kind, BlockKind.tool);
      expect(g.parts[4].kind, BlockKind.tool);
    });

    test('tool 后遇 user 立即切组，孤立 tool 也降级', () {
      final groups = buildAgentGroups([
        StreamBlock.think('plan'),
        StreamBlock.tool(name: 'Bash'),
        StreamBlock.user('new question'),
        StreamBlock.tool(name: 'Read'),
      ]);
      expect(groups, hasLength(3));
      expect(groups[0], isA<AgentGroup>());
      expect((groups[0] as AgentGroup).toolCount, 1);
      expect(groups[1], isA<SingleBlockGroup>());
      // 末尾孤立 tool 也降级
      expect(groups[2], isA<SingleBlockGroup>());
      expect((groups[2] as SingleBlockGroup).block.kind, BlockKind.tool);
    });

    test('AgentGroup.isRunning 反映思考/工具状态', () {
      // think + tool 是一组合法的多 part group，保留 AgentGroup。
      final groups = buildAgentGroups([
        StreamBlock.think(''), // 思考为空 → 仍在运行
        StreamBlock.tool(name: 'Bash'),
      ]);
      expect((groups.first as AgentGroup).isRunning, isTrue);

      final groups2 = buildAgentGroups([
        StreamBlock.think('plan'),
        StreamBlock.tool(name: 'Bash'),
      ]);
      // 工具默认 pending → 仍在运行
      expect((groups2.first as AgentGroup).isRunning, isTrue);
    });

    test('AgentGroup.isRunning 在工具全部 done 时为 false', () {
      final groups = buildAgentGroups([
        StreamBlock.think('plan'),
        StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
        StreamBlock.toolResult(name: 'Read', status: ToolStatus.done),
      ]);
      expect((groups.first as AgentGroup).isRunning, isFalse);
    });

    test('多 think 时任一为空即视为进行中', () {
      final groups = buildAgentGroups([
        StreamBlock.think('plan1'),
        StreamBlock.toolResult(name: 'Bash', status: ToolStatus.done),
        StreamBlock.think(''), // 还在写第二个思考
        StreamBlock.tool(name: 'Read'),
      ]);
      expect((groups.first as AgentGroup).isRunning, isTrue);
    });
  });
}
