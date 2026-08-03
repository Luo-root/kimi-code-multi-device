import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel/widgets/kimi_core.dart';

void main() {
  // 回归：KimiCoreIndicator 放在 ListView item 里时，水平方向是 tight 约束
  // （宽度 = 屏宽 − 页边距）。CustomPaint.size / SizedBox 都只是"建议尺寸"，
  // 会被 tight 约束 clamp 成整行宽 → 画布变"屏宽 × 2.5"、星形按拉伸宽度绘制
  // 并被 clipRect 裁成横条（大小错）、圆心跑到画布中心（位置错）。
  // 修复：UnconstrainedBox 解除父级约束，child 严格是 size×size。
  testWidgets('ListView 内画布保持 2.5×2.5，不被 tight 约束拉伸', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: const [KimiCoreIndicator()],
          ),
        ),
      ),
    );

    final paint = tester.renderObject<RenderCustomPaint>(
      find.descendant(
        of: find.byType(KimiCoreIndicator),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(paint.size, const Size(2.5, 2.5));
  });

  testWidgets('列表左缘呼吸光点：内容贴左上角（位置）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: const [
              KimiCoreIndicator(alignment: Alignment.centerLeft),
            ],
          ),
        ),
      ),
    );

    final paint = find.descendant(
      of: find.byType(KimiCoreIndicator),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getRect(paint), const Rect.fromLTWH(0, 0, 2.5, 2.5));
  });

  testWidgets('指定 size 生效（任意尺寸无损缩放）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: KimiCoreIndicator(size: 16),
          ),
        ),
      ),
    );

    final paint = tester.renderObject<RenderCustomPaint>(
      find.descendant(
        of: find.byType(KimiCoreIndicator),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(paint.size, const Size(16, 16));
  });

  testWidgets('animated=false 静止渲染，动画/静止切换不崩溃', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: KimiCoreIndicator(animated: false),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);

    // 切到动画模式再切回静止（didUpdateWidget 路径）。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: KimiCoreIndicator(animated: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: KimiCoreIndicator(animated: false),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
