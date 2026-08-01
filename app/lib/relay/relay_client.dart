import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 中继下行消息的统一回调：type / sessionId / payload。
typedef RelayHandler = void Function(
    String type, String? sid, Map<String, dynamic> payload);

class RelayClient {
  WebSocketChannel? _ch;
  StreamSubscription? _sub;

  RelayHandler? onMessage;
  VoidCallback? onOpen;
  VoidCallback? onClose;

  bool get connected => _ch != null;

  Future<void> connect(String url) async {
    await disconnect();
    final ch = WebSocketChannel.connect(Uri.parse(url));
    await ch.ready; // 等待握手完成（web_socket_channel ^2.4）
    _ch = ch;
    onOpen?.call();
    _sub = ch.stream.listen(
      (data) {
        try {
          final m = (jsonDecode(data as String) as Map).cast<String, dynamic>();
          final type = m['type']?.toString() ?? '';
          final sid = m['sessionId']?.toString();
          final payload =
              (m['payload'] as Map?)?.cast<String, dynamic>() ?? {};
          onMessage?.call(type, sid, payload);
        } catch (_) {
          // 忽略无法解析的帧
        }
      },
      onDone: () {
        _ch = null;
        onClose?.call();
      },
      onError: (_) {
        _ch = null;
        onClose?.call();
      },
      cancelOnError: true,
    );
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
    await _sub?.cancel();
    _sub = null;
    await _ch?.sink.close();
    _ch = null;
  }
}