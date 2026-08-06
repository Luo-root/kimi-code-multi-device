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
