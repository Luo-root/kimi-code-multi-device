import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// 发送后等待首 token 的呼吸动画（三点交错）。§3.2-1 / §3.1-2。
class BreathingDots extends StatefulWidget {
  const BreathingDots({super.key});
  @override
  State<BreathingDots> createState() => _BreathingDotsState();
}

class _BreathingDotsState extends State<BreathingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  late final List<Animation<double>> _ops = List.generate(3, (i) {
    final start = i * 0.18;
    return Tween(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
        parent: _c,
        curve: Interval(start, start + 0.5, curve: Curves.easeInOut),
      ),
    );
  });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: FadeTransition(
                opacity: _ops[i],
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      );
}

/// 流式文本尾部闪烁光标（accent 竖线）。§3.2-3。
class BlinkingCursor extends StatefulWidget {
  const BlinkingCursor({super.key});
  @override
  State<BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  late final Animation<double> _op = Tween(begin: 0.15, end: 1.0).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _op,
        child: Container(
          width: 2,
          height: (AppText.body.fontSize ?? 15) * 1.2,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      );
}

/// 激活时轻微脉冲缩放，提升「停止」按钮存在感。§3.2-6。
class PulseWrapper extends StatefulWidget {
  final bool active;
  final Widget child;
  const PulseWrapper({super.key, required this.active, required this.child});

  @override
  State<PulseWrapper> createState() => _PulseWrapperState();
}

class _PulseWrapperState extends State<PulseWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat(reverse: true);
  late final Animation<double> _sc = Tween(begin: 1.0, end: 1.06).animate(_c);

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant PulseWrapper old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) _c.repeat(reverse: true);
    if (!widget.active) {
      _c.stop();
      _c.value = 0; // 复位到 scale 1.0，避免残留放大
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.active ? ScaleTransition(scale: _sc, child: widget.child) : widget.child;
}
