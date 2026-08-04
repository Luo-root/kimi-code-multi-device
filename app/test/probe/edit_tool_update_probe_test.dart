// 用途：固化 Kimi ACP Edit 工具参数的实时下行形态。
// 关键事实：tool_call_update.content.text 是累计 JSON 快照；rawOutput 只是执行回执，
// 不包含 old/new 文本，不能单独重建 diff。

import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/relay/session_store.dart';

void main() {
  group('Edit tool_call_update 协议探针', () {
    test('content.text 累计 JSON 必须在 rawOutput 前保存为 command', () {
      final store = SessionStore();
      const sid = 'probe-edit';
      store.handle('session.created', sid, const {});
      store.handle('session.update', sid, const {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'edit-1',
        'title': 'Edit',
        'status': 'pending',
      });
      store.handle('session.update', sid, const {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'edit-1',
        'status': 'in_progress',
        'content': {
          'type': 'text',
          'text':
              '{"file_path":"lib/a.dart","old_string":"old","new_string":"new"}',
        },
      });
      store.handle('session.update', sid, const {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'edit-1',
        'status': 'completed',
        'rawOutput': 'Replaced 1 occurrence in lib/a.dart',
      });

      final block = store.blocksOf(sid).single;
      expect(block.command, contains('"old_string":"old"'));
      expect(block.output, 'Replaced 1 occurrence in lib/a.dart');
      expect(block.status.name, 'done');
    });

    test('未闭合的中间 JSON 快照不会覆盖已保存的完整输入', () {
      final store = SessionStore();
      const sid = 'probe-edit-partial';
      store.handle('session.created', sid, const {});
      store.handle('session.update', sid, const {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'edit-2',
        'title': 'Edit',
      });
      store.handle('session.update', sid, const {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'edit-2',
        'status': 'in_progress',
        'content': {
          'type': 'text',
          'text':
              '{"file_path":"lib/a.dart","old_string":"old","new_string":"new"}',
        },
      });
      store.handle('session.update', sid, const {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'edit-2',
        'status': 'in_progress',
        'content': {'type': 'text', 'text': '{"file_path":"lib/a.dart"'},
      });

      expect(
        store.blocksOf(sid).single.command,
        contains('"new_string":"new"'),
      );
    });

    test('gap: 仅 rawOutput 无法恢复 old/new diff', () {
      // 如果客户端错过了 content.text 且 rawInput 也缺失，
      // "Replaced 1 occurrence..." 只知道成功与路径，无法还原删除/新增代码。
      // 历史 wire replay 目前 args 也只声明 command，需要中继后续保留通用 args。
      // ignore: avoid_print
      print('[probe] gap: rawOutput 不含 old/new；历史 replay 需保留 Edit args');
    });
  });
}
