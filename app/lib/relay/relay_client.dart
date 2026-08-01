import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 中继下行消息的统一回调：type / sessionId / payload。
typedef RelayHandler = void Function(
    String type, String? sid, Map<String, dynamic> payload);

/// 中继 WebSocket 客户端：带断线指数退避重连。
///
/// 连接态分四类（与 store.relayState 对齐）：
/// - 已连上 → onOpen（store 标 ok，取决于 relay 报告的 kimi 健康）
/// - 意外断开 → onClose + onReconnecting，后台按 1/2/4/8/…/30s 退避重连
/// - 主动 disconnect() → 不重连
class RelayClient {
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  int _attempts = 0;
  bool _intentionalClose = false;
  String? _url;

  RelayHandler? onMessage;
  VoidCallback? onOpen;
  VoidCallback? onClose;
  VoidCallback? onReconnecting;

  bool get connected => _ch != null;

  Future<void> connect(String url) async {
    _url = url;
    _intentionalClose = false;
    _attempts = 0;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    await _sub?.cancel();
    _sub = null;
    await _ch?.sink.close();
    _ch = null;
    if (_url == null) return;
    try {
      final ch = WebSocketChannel.connect(Uri.parse(_url!));
      await ch.ready; // 握手完成（web_socket_channel ^2.4）
      _ch = ch;
      _attempts = 0;
      onOpen?.call();
      _sub = ch.stream.listen(
        (data) {
          try {
            final m =
                (jsonDecode(data as String) as Map).cast<String, dynamic>();
            final type = m['type']?.toString() ?? '';
            final sid = m['sessionId']?.toString();
            final payload =
                (m['payload'] as Map?)?.cast<String, dynamic>() ?? {};
            onMessage?.call(type, sid, payload);
          } catch (_) {
            // 忽略无法解析的帧
          }
        },
        onDone: _onDone,
        onError: (_) => _onDone(),
        cancelOnError: true,
      );
    } catch (_) {
      // 握手失败：若非主动关闭，进入退避重连。
      if (!_intentionalClose) _scheduleReconnect();
    }
  }

  void _onDone() {
    final wasConnected = _ch != null;
    _ch = null;
    onClose?.call();
    if (!_intentionalClose) {
      // 仅在"用过分又断"或"重连中再断"时报告重连；首次连不上也走 scheduleReconnect。
      if (wasConnected) _attempts = 0;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_intentionalClose || _url == null) return;
    _attempts++;
    onReconnecting?.call();
    final exp = (_attempts - 1).clamp(0, 4); // 1,2,4,8,16s 后封顶 16s
    final delay = 1 << exp; // 1..16
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), _doConnect);
  }

  void send(String type, {String? sid, Map<String, dynamic>? payload}) {
    final ch = _ch;
    if (ch == null) return;
    final m = <String, dynamic>{'type': type};
    if (sid != null) m['sessionId'] = sid;
    if (payload != null) m['payload'] = payload;
    ch.sink.add(jsonEncode(m));
  }

  Future<void> disconnect() async {
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _sub?.cancel();
    _sub = null;
    await _ch?.sink.close();
    _ch = null;
  }
}
