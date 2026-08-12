import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// 当前步骤的连续文字流光。
///
/// 它只表达「这一行正在执行」：思考中与执行中的工具调用复用同一动效，
/// 完成、失败或取消后由调用方切回普通 [Text]。渐变纹理首尾同色并按周期平铺，
/// 每轮位移恰好一个纹理周期，因此循环边界不会出现整体熄灭或亮度跳变。
class ActivityShimmerText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final Duration duration;
  final Color? baseColor;
  final Color? highlightColor;

  const ActivityShimmerText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.duration = const Duration(milliseconds: 2600),
    this.baseColor,
    this.highlightColor,
  });

  @override
  State<ActivityShimmerText> createState() => _ActivityShimmerTextState();
}

class _ActivityShimmerTextState extends State<ActivityShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool _animate = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ActivityShimmerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    _syncAnimation();
  }

  void _syncAnimation() {
    final media = MediaQuery.maybeOf(context);
    final shouldAnimate =
        !(media?.disableAnimations ?? false) &&
        !(media?.accessibleNavigation ?? false) &&
        TickerMode.valuesOf(context).enabled;
    if (shouldAnimate == _animate) return;
    _animate = shouldAnimate;
    if (_animate) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _text(Color color) => Text(
    widget.text,
    maxLines: widget.maxLines,
    overflow: widget.overflow,
    textAlign: widget.textAlign,
    style: widget.style.copyWith(color: color),
  );

  @override
  Widget build(BuildContext context) {
    final base =
        widget.baseColor ??
        widget.style.color ??
        AppColors.placeholderOf(context);
    final highlight = widget.highlightColor ?? AppColors.textPrimaryOf(context);
    if (!_animate) return _text(base);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        child: _text(Colors.white),
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            // 一个纹理周期约为文字宽度的 72%；移动恰好一个周期后无缝复位。
            final period = (bounds.width * 0.72).clamp(1.0, double.infinity);
            final left = bounds.left - period + period * _controller.value;
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              tileMode: TileMode.repeated,
              colors: [base, base, highlight, base, base],
              stops: const [0, 0.32, 0.5, 0.68, 1],
            ).createShader(
              Rect.fromLTWH(left, bounds.top, period, bounds.height),
            );
          },
          child: child,
        ),
      ),
    );
  }
}

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
              decoration: BoxDecoration(
                color: AppColors.accentOf(context),
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
        color: AppColors.accentOf(context),
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
  Widget build(BuildContext context) => widget.active
      ? ScaleTransition(scale: _sc, child: widget.child)
      : widget.child;
}
