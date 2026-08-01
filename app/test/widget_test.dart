// SENTINEL 冒烟测试：验证 App 能构建并显示初始空状态。
//
// HomeShell 启动即尝试连中继（测试环境必失败，被 try/catch 吞掉），
// 故初始 online=false，空状态文案应为「连接中继后开始」。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sentinel/main.dart';

void main() {
  testWidgets('App 构建并显示连接前空状态', (WidgetTester tester) async {
    await tester.pumpWidget(const SentinelApp());
    // 触发一帧 + 让异步连接尝试落地（失败被吞，不抛异常）。
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('连接中继后开始'), findsOneWidget);
  });
}
