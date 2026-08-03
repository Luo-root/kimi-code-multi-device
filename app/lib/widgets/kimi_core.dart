import 'dart:math' as math;
import 'package:flutter/material.dart';

/// KimiCore 生成动画：移植自 Initialize.svg（简约版）。
/// 双层八角菱形反向折叠旋转——外层顺时针、内层逆时针，
/// 周期中点收束至 12% 后回弹，传达“AI 正在凝聚、思考中”。
///
/// 周期 4.5s，缓动 cubic-bezier(.4,0,.2,1)，与 SVG 原作完全一致。
/// 纯 CustomPaint 矢量绘制，[size] 可为任意尺寸无损缩放。
/// 默认 2.5px 微指示器：作为流式输出尾部的“呼吸光点”存在，不干扰阅读。
class KimiCoreIndicator extends StatefulWidget {
  /// 渲染尺寸（正方形边长），默认 2.5（微光点），星形实际直径 ≈ size×0.76。
  final double size;

  /// 内容对齐方式。默认居中（独立图标场景）；
  /// 作为列表左缘的"呼吸光点"时传 [Alignment.centerLeft]。
  final AlignmentGeometry alignment;

  /// 是否播放动画。false 时静止在展开态（t=0）：
  /// AI 空闲时作为静止的身份标识，输出中才转动。
  final bool animated;

  const KimiCoreIndicator({
    super.key,
    this.size = 2.5,
    this.alignment = Alignment.center,
    this.animated = true,
  });

  @override
  State<KimiCoreIndicator> createState() => _KimiCoreIndicatorState();
}

class _KimiCoreIndicatorState extends State<KimiCoreIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4500),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animated) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant KimiCoreIndicator old) {
    super.didUpdateWidget(old);
    if (widget.animated && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.animated && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0; // 静止回展开态
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) => UnconstrainedBox(
        // UnconstrainedBox 解除父级约束：ListView item 的水平是 tight 约束
        // （宽度 = 屏宽），SizedBox / CustomPaint 的尺寸都会被 clamp 拉伸成
        // "屏宽 × 2.5"，星形按拉伸宽度绘制并被裁剪成横条（大小错）、
        // 圆心跑到画布中心（位置错）。解除约束后 child 严格是 size×size。
        alignment: widget.alignment,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: _KimiCorePainter(t: _ctrl.value),
          ),
        ),
      ),
    );
  }
}

/// CSS cubic-bezier 时序函数求解器（Newton-Raphson）。
/// 精确还原 SVG @keyframes 使用的 cubic-bezier(.4,0,.2,1) 缓动。
class _CubicBezier {
  final double ax, bx, cx, ay, by, cy;

  _CubicBezier(double x1, double y1, double x2, double y2)
      : cx = 3 * x1,
        bx = 3 * (x2 - 2 * x1),
        ax = 1 - 3 * x2 + 3 * x1,
        cy = 3 * y1,
        by = 3 * (y2 - 2 * y1),
        ay = 1 - 3 * y2 + 3 * y1;

  double _sampleX(double t) => ((ax * t + bx) * t + cx) * t;
  double _sampleY(double t) => ((ay * t + by) * t + cy) * t;
  double _sampleDX(double t) => (3 * ax * t + 2 * bx) * t + cx;

  /// 给定时间进度 x∈[0,1]，返回缓动后的值 y。
  double transform(double x) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    var t = x;
    for (var i = 0; i < 8; i++) {
      final err = _sampleX(t) - x;
      if (err.abs() < 1e-6) break;
      final d = _sampleDX(t);
      if (d.abs() < 1e-6) break;
      t -= err / d;
    }
    return _sampleY(t.clamp(0.0, 1.0));
  }
}

/// SVG 原作缓动：cubic-bezier(.4, 0, .2, 1)（Material standard easing）。
final _standardEase = _CubicBezier(0.4, 0.0, 0.2, 1.0);

class _KimiCorePainter extends CustomPainter {
  final double t; // 0..1 主周期进度

  _KimiCorePainter({required this.t});

  // ---- 色彩（对齐 SVG coreGrad：#C084FC → #A855F7 → #7C3AED）----
  static const _gradColors = [
    Color(0xFFC084FC),
    Color(0xFFA855F7),
    Color(0xFF7C3AED),
  ];
  static const _corePurple = Color(0xFF7C3AED);

  /// 八角星中间顶点半径比（SVG: 22.63/36 ≈ 0.629）。
  static const _midRatio = 0.629;

  /// 星形外接圆半径占组件半边长的比例。
  /// 0.38 → 星形直径约占组件宽 76%，留 24% 呼吸边距。
  static const _contentRatio = 0.38;

  @override
  void paint(Canvas canvas, Size size) {
    // 硬裁剪：CustomPaint 默认不裁剪溢出绘制，
    // 此处保证任何情况下动画都不会画出组件边界。
    canvas.clipRect(Offset.zero & size);
    final c = Offset(size.width / 2, size.height / 2);
    final unit = size.width * _contentRatio / 36; // SVG 1 单位长度（36 单位 = 星形半径）

    // CSS @keyframes：0%{rot 0, s 1} → 50%{rot ±180°, s 0.12} → 100%{rot ±360°, s 1}
    // 缓动应用于整个周期（rotate 与 scale 共享同一时间映射）。
    final eased = _standardEase.transform(t);
    final fold = eased <= 0.5 ? eased * 2 : (1 - eased) * 2; // 0→1→0
    final scale = 1.0 - 0.88 * fold; // 1 → 0.12 → 1
    final outerRot = eased * 2 * math.pi; // 顺时针 360°
    final innerRot = -eased * 2 * math.pi; // 逆时针 360°

    canvas.save();
    canvas.translate(c.dx, c.dy);

    // ═══ 外层菱形（渐变填充，顺时针折叠）═══
    canvas.save();
    canvas.rotate(outerRot);
    canvas.scale(scale);
    _drawStar8(canvas, unit * 36, _gradientPaint(unit * 36)); // 主体
    _drawStar8(
      canvas,
      unit * 36,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * 1
        ..color = Colors.white.withValues(alpha: 0.2),
    ); // 外描边
    _drawStar8(
      canvas,
      unit * 24.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * 2.2
        ..color = Colors.white.withValues(alpha: 0.35),
    ); // 内描边
    // 十字线
    final cross = Paint()
      ..strokeWidth = unit * 1.6
      ..color = Colors.white.withValues(alpha: 0.18);
    canvas.drawLine(Offset(-unit * 24.5, 0), Offset(unit * 24.5, 0), cross);
    canvas.drawLine(Offset(0, -unit * 24.5), Offset(0, unit * 24.5), cross);
    // 对角线
    final diag = Paint()
      ..strokeWidth = unit * 1
      ..color = Colors.white.withValues(alpha: 0.1);
    canvas.drawLine(Offset(-unit * 16, -unit * 16), Offset(unit * 16, unit * 16), diag);
    canvas.drawLine(Offset(unit * 16, -unit * 16), Offset(-unit * 16, unit * 16), diag);
    canvas.restore();

    // ═══ 内层菱形（白色，逆时针折叠）═══
    canvas.save();
    canvas.rotate(innerRot);
    canvas.scale(scale);
    _drawStar8(
      canvas,
      unit * 16.5,
      Paint()..color = Colors.white.withValues(alpha: 0.95),
    ); // 主体
    _drawStar8(
      canvas,
      unit * 16.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * 1
        ..color = _corePurple.withValues(alpha: 0.3),
    ); // 外描边
    _drawStar8(
      canvas,
      unit * 10.8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * 2
        ..color = _corePurple.withValues(alpha: 0.6),
    ); // 内描边
    final innerCross = Paint()
      ..strokeWidth = unit * 1.4
      ..color = _corePurple.withValues(alpha: 0.4);
    canvas.drawLine(Offset(-unit * 10.8, 0), Offset(unit * 10.8, 0), innerCross);
    canvas.drawLine(Offset(0, -unit * 10.8), Offset(0, unit * 10.8), innerCross);
    // 中心圆点
    canvas.drawCircle(
      Offset.zero,
      unit * 3,
      Paint()..color = _corePurple.withValues(alpha: 0.8),
    );
    canvas.restore();

    canvas.restore();
  }

  /// 八角星：8 顶点交替排列（SVG polygon points 的精确还原）。
  /// 顶点位于 0°/90°/180°/270°，中间顶点位于 45° 方向、半径 r×[_midRatio]。
  void _drawStar8(Canvas canvas, double r, Paint paint) {
    final mid = r * _midRatio;
    final m = mid * math.sqrt1_2; // 45° 分量
    final path = Path()
      ..moveTo(0, -r)
      ..lineTo(m, -m)
      ..lineTo(r, 0)
      ..lineTo(m, m)
      ..lineTo(0, r)
      ..lineTo(-m, m)
      ..lineTo(-r, 0)
      ..lineTo(-m, -m)
      ..close();
    canvas.drawPath(path, paint);
  }

  Paint _gradientPaint(double r) {
    return Paint()
      ..shader = const LinearGradient(
        colors: _gradColors,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Rect.fromCircle(center: Offset.zero, radius: r));
  }

  @override
  bool shouldRepaint(covariant _KimiCorePainter old) => old.t != t;
}
