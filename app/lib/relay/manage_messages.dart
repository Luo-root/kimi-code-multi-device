/// 会话管理消息契约（relay↔app WebSocket 通道②）。
///
/// 与 relay/internal/relay/protocol.go 的 [UpManageSession]/[DownSessionManaged]
/// 严格对齐：action 字符串、上下行 type、字段名一一对应。新增管理动作只加枚举值，
/// 不破坏旧端（旧端不会发出新 action，也不解析未知 action）。
library;

/// 上行 type：端侧发起会话管理操作。
const String kUpManageSession = 'session.manage';

/// 下行 type：管理操作结果回执（定向回给发起端）。
const String kDownSessionManaged = 'session.managed';

/// 会话管理动作。取值须与 relay 的 ManageAction* 常量一致。
enum ManageAction {
  archive('archive'),
  restore('restore'),
  rename('rename'),
  fork('fork'),
  delete('delete'),
  export('export');

  const ManageAction(this.value);
  final String value;

  static ManageAction fromValue(String v) =>
      values.firstWhere((e) => e.value == v, orElse: () => archive);
}

/// 当前 kimi web（0.32.0）在 REST 管理面**未提供磁盘直读接口**的动作集合。
///
/// 历史：早期 `delete` 无磁盘接口（`:delete` 回 40001、`DELETE` 是 404 路由未找到），
/// 唯一的调试 RPC 需会话已加载进 kimi web 运行时，对 relay 代启的实例不可用，故
/// 曾列入本集合、端侧禁用删除菜单。
///
/// 现状（2026-08-07）：`delete` 已由 relay 改为 **direct-storage 删除**——关闭 kimi web
/// 后直接删除会话存储目录并清理 `session_index.jsonl` 索引（kimi 自身 UI 也无删除入口，
/// 只能手工删目录）。故本集合现在为空。未来若 kimi 某动作又不支持，加入对应项即可让
/// 端侧自动禁用并提示，无需改协议。
const Set<ManageAction> kKimiUnsupportedActions = {
  // 当前所有动作均可用：archive/restore/rename/fork/delete/export。
};

/// 构造上行 session.manage 的 payload。
///
/// - [action] 管理动作。
/// - [sessionId] 目标会话。
/// - [title] rename 新标题。
/// - [newSessionId] fork 指定新会话 ID（省略则 kimi 自动生成）。
/// - [options] 预留（export 的 version/outputPath 等）。
Map<String, dynamic> buildManageRequest(
  ManageAction action,
  String sessionId, {
  String? title,
  String? newSessionId,
  Map<String, dynamic>? options,
}) {
  final p = <String, dynamic>{
    'action': action.value,
    'sessionId': sessionId,
  };
  if (title != null) p['title'] = title;
  if (newSessionId != null) p['newSessionId'] = newSessionId;
  if (options != null) p['options'] = options;
  return p;
}

/// 管理操作结果回执（下行 session.managed 解析）。
class ManagedResult {
  final ManageAction action;
  final String sessionId;
  final bool ok;
  final String? error;
  final Map<String, dynamic>? data;

  const ManagedResult({
    required this.action,
    required this.sessionId,
    required this.ok,
    this.error,
    this.data,
  });

  /// 从下行 payload 解析；type 不匹配或字段缺失时返回 null。
  static ManagedResult? fromPayload(Map<String, dynamic> payload) {
    final actionRaw = payload['action']?.toString();
    final sid = payload['sessionId']?.toString();
    final ok = payload['ok'] == true;
    if (actionRaw == null || sid == null) return null;
    return ManagedResult(
      action: ManageAction.fromValue(actionRaw),
      sessionId: sid,
      ok: ok,
      error: payload['error']?.toString(),
      data: (payload['data'] as Map?)?.cast<String, dynamic>(),
    );
  }
}
