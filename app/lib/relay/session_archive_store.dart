// 会话归档状态：kimi acp 暂不提供 archived 字段（见 test/probe/session_list_probe_test
// 的 gap #1），先在客户端用 shared_preferences 维护"已归档 sid 集合"，跨重启保留。
//
// 后续若 kimi acp 或 relay 补出原生 archive API，把这里切到下行字段即可，UI/调用
// 点保持不变。

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionArchiveStore extends ChangeNotifier {
  static const String _kPrefKey = 'sentinel.archivedSessionIds';

  final Set<String> _ids = <String>{};
  Set<String> get ids => Set.unmodifiable(_ids);

  bool isArchived(String sessionId) => _ids.contains(sessionId);

  /// 返回 [sessionId] 的新归档状态。
  bool archive(String sessionId) {
    if (_ids.add(sessionId)) {
      _persist();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 返回 [sessionId] 的新归档状态（false = 恢复）。
  bool restore(String sessionId) {
    if (_ids.remove(sessionId)) {
      _persist();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 批量归档：把 [sids] 中尚未归档的全部加入集合，返回新加入的数量。
  /// 一次通知 + 一次落盘，避免「每个 sid 一次 IO」的成本。
  int archiveAll(Iterable<String> sids) {
    var added = 0;
    for (final id in sids) {
      if (_ids.add(id)) added++;
    }
    if (added > 0) {
      _persist();
      notifyListeners();
    }
    return added;
  }

  /// 启动时一次性读取本地归档集合。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kPrefKey) ?? const <String>[];
      _ids
        ..clear()
        ..addAll(list);
      notifyListeners();
    } catch (_) {
      // 读取失败保留空集合，不阻塞启动。
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kPrefKey, _ids.toList(growable: false));
    } catch (_) {
      // 持久化失败仅丢失记忆，不影响本次操作。
    }
  }
}
