import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';

/// 复制到剪贴板并给出轻量 toast 反馈。供消息 / 代码块 / 命令复制复用。
void copyToClipboard(BuildContext context, String text) {
  if (text.isEmpty) return;
  Clipboard.setData(ClipboardData(text: text));
  HapticFeedback.selectionClick(); // §UX-8.2-2：复制 = .selection。
  showAppToast(context, message: '已复制', variant: AppToastVariant.success);
}

// ---------------------------------------------------------------------------
// 应用级 toast
// ---------------------------------------------------------------------------

/// toast 语义变体，只决定图标与强调色，不改变版式。
enum AppToastVariant { success, info, warning, error }

/// toast 卡片宽度。hux 内置 snackbar 把宽度硬编码成 400，短文案（如「已复制」）
/// 会拉出一条过长的横条；这里取其三分之二，短提示不再霸屏。
const double _kToastWidth = 268;

/// toast 卡片的 widget key，供回归测试断言宽度与生命周期。
const String kAppToastCardKey = 'appToastCard';

/// 变体默认停留时长。成功类最短（信息量小），错误类最长（需要读完）。
Duration _toastDuration(AppToastVariant v) => switch (v) {
      AppToastVariant.success => const Duration(milliseconds: 1000),
      AppToastVariant.info => const Duration(milliseconds: 1400),
      AppToastVariant.warning => const Duration(milliseconds: 1600),
      AppToastVariant.error => const Duration(milliseconds: 2000),
    };

/// 弹出一条轻量 toast。
///
/// 为什么不用 hux 的 `showHuxSnackbar` / `HuxSnackbarStackController`：
/// 1) `showHuxSnackbar` 走 ScaffoldMessenger，画在 Scaffold 内部，抽屉打开时会被遮住；
/// 2) hux 的卡片宽度硬编码 400，且无法从外部约束（宽度写死在其私有 body 里）。
/// 这里自建 root overlay toast：既浮在最上层（抽屉 / 弹层之上），又能控制宽度与时长。
///
/// 同一时刻只保留一条：新 toast 直接顶掉旧的，避免连点堆成一摞。
void showAppToast(
  BuildContext context, {
  required String message,
  AppToastVariant variant = AppToastVariant.info,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return; // 测试或未挂载场景下静默降级。
  showAppToastOn(
    overlay,
    message: message,
    variant: variant,
    duration: duration,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

/// 与 [showAppToast] 等价，但直接接收 [OverlayState]。
/// 用于 `await` 之后不便再持有 BuildContext 的异步回退路径
/// （先在 await 前捕获 overlay，await 后再弹）。
void showAppToastOn(
  OverlayState overlay, {
  required String message,
  AppToastVariant variant = AppToastVariant.info,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  _AppToastHost.dismissCurrent();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _AppToastView(
      message: message,
      variant: variant,
      duration: duration ?? _toastDuration(variant),
      actionLabel: actionLabel,
      onAction: onAction,
      onFinished: () => _AppToastHost.remove(entry),
    ),
  );
  _AppToastHost.current = entry;
  overlay.insert(entry);
}

/// 单槽 toast 宿主：只记录当前那条 OverlayEntry，便于「新的顶掉旧的」。
abstract final class _AppToastHost {
  static OverlayEntry? current;

  static void dismissCurrent() => remove(current);

  static void remove(OverlayEntry? entry) {
    if (entry == null) return;
    if (identical(current, entry)) current = null;
    if (entry.mounted) entry.remove();
  }
}

class _AppToastView extends StatefulWidget {
  final String message;
  final AppToastVariant variant;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onFinished;

  const _AppToastView({
    required this.message,
    required this.variant,
    required this.duration,
    required this.actionLabel,
    required this.onAction,
    required this.onFinished,
  });

  @override
  State<_AppToastView> createState() => _AppToastViewState();
}

class _AppToastViewState extends State<_AppToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _timer = Timer(widget.duration, _dismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    if (!mounted) return;
    try {
      await _c.reverse();
    } catch (_) {
      // 退出动画期间宿主被顶掉 → controller 已 dispose，忽略。
      return;
    }
    if (mounted) widget.onFinished();
  }

  Color _accent(BuildContext c) => switch (widget.variant) {
        AppToastVariant.success => AppColors.approve,
        AppToastVariant.info => AppColors.accentOf(c),
        AppToastVariant.warning => AppColors.warning,
        AppToastVariant.error => AppColors.reject,
      };

  IconData get _icon => switch (widget.variant) {
        AppToastVariant.success => AppIcons.check,
        AppToastVariant.info => AppIcons.info,
        AppToastVariant.warning => AppIcons.alertTriangle,
        AppToastVariant.error => AppIcons.alertTriangle,
      };

  @override
  Widget build(BuildContext context) {
    final accent = _accent(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.pageMargin),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: FadeTransition(
              opacity: _c,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.3),
                  end: Offset.zero,
                ).animate(
                    CurvedAnimation(parent: _c, curve: Curves.easeOutCubic)),
                child: _card(context, accent),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Color accent) {
    // Overlay 里没有 Material 祖先时，DefaultTextStyle 会回落到 Flutter 的调试样式
    // （红字 + 黄色双下划线）。Text.style 是 merge 语义，未显式声明的 decoration
    // 仍会继承那份 fallback，于是文案下方出现黄色下划线。
    // 透明 Material 提供正常的 DefaultTextStyle，且不绘制任何背景/阴影，
    // 卡片自身的 surface/hairline/popup 阴影完全不受影响。
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: const ValueKey(kAppToastCardKey),
        width: _kToastWidth,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: BorderRadius.circular(AppRadius.popup),
          border: Border.all(color: AppColors.hairlineOf(context)),
          boxShadow: AppShadows.popup,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(_icon, size: 16, color: accent),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                widget.message,
                // decoration 显式置空：即便未来 toast 被挂到缺少 Theme 的宿主下，
                // 也不会再继承调试用的黄色双下划线（与上方 Material 互为双保险）。
                style: AppText.callout.copyWith(
                  color: AppColors.textPrimaryOf(context),
                  decoration: TextDecoration.none,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.actionLabel != null) ...[
              const SizedBox(width: AppSpacing.sm),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  widget.onAction?.call();
                  _dismiss();
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    widget.actionLabel!,
                    style: AppText.calloutStrong.copyWith(
                      color: AppColors.accentOf(context),
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// §UX-2.2 复制按钮：复制成功后图标就地变勾 1.5s（不再用 SnackBar）。
/// 视觉 30px，命中区域扩展至 44×44pt（§UX-2.1-6 触控标准）。
/// [dark] 用于深色代码块内（幽灵按钮，白字）。
class CopyButton extends StatefulWidget {
  final String text;
  final bool dark;
  final bool plain;
  const CopyButton(
      {super.key, required this.text, this.dark = false, this.plain = false});

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool _done = false;
  Timer? _reset;

  void _copy() {
    if (widget.text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: widget.text));
    HapticFeedback.selectionClick();
    setState(() => _done = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _done = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.plain
        ? Colors.transparent
        : (widget.dark
            ? const Color(0x33FFFFFF)
            : (_done ? AppColors.approveSoft : AppColors.keyCapOf(context)));
    final fg = widget.dark
        ? (_done ? AppColors.approve : const Color(0xFFC7C7CC))
        : (_done ? AppColors.approve : AppColors.textSecondaryOf(context));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _copy,
      // 命中区域 44×44，视觉居中 30px。
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: Icon(
                _done ? AppIcons.check : AppIcons.copy,
                key: ValueKey(_done),
                size: 14,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 按压反馈：opacity 0.7 + scale 0.96，松开带轻微回弹（§UX-8.2-1）。
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const Pressable({super.key, required this.child, required this.onTap});

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1.0,
        // 按下快速响应，松开用 easeOutBack 带一点回弹。
        duration: Duration(milliseconds: _down ? 90 : 180),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: _down ? 0.7 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: widget.child,
        ),
      ),
    );
  }
}

// ---------- 弹出动画基建（§UX-1 弹出菜单体系）----------

/// 全局弹层关闭栈：Android 返回手势优先关闭最上层弹层，而非直接退出页面（§UX-1.5）。
/// 各 Overlay 弹层打开时注册自己的 closer，关闭时反注册。
class PopupRegistry extends ChangeNotifier {
  PopupRegistry._();
  static final PopupRegistry instance = PopupRegistry._();

  final List<VoidCallback> _closers = [];

  bool get hasOpen => _closers.isNotEmpty;

  void register(VoidCallback closer) {
    _closers.add(closer);
    notifyListeners();
  }

  void unregister(VoidCallback closer) {
    _closers.remove(closer);
    notifyListeners();
  }

  /// 关闭最上层弹层。返回是否有关闭发生。
  bool closeTopmost() {
    if (_closers.isEmpty) return false;
    _closers.removeLast()();
    return true;
  }
}

/// 弹层入场/退场动画容器（§UX-1.1 / §UX-1.4）：
/// - 入场：scale 0.95→1.0 + fade 0→1，180ms easeOut，锚点 [origin]；
/// - 退场：调用 [dismiss] 播放反向动画（120ms easeIn），结束后调用方再移除 OverlayEntry；
/// - 自带轻量 scrim（黑 ~8% 渐入），点击 scrim 触发 [onScrimTap]。
///
/// 定位参数（top/bottom/left/right/width）透传给内部 Positioned。
class PopupAnimator extends StatefulWidget {
  final Widget child;
  final Alignment origin;
  final double? top;
  final double? bottom;
  final double? left;
  final double? right;
  final double? width;
  final VoidCallback onScrimTap;

  const PopupAnimator({
    super.key,
    required this.child,
    required this.onScrimTap,
    this.origin = Alignment.topLeft,
    this.top,
    this.bottom,
    this.left,
    this.right,
    this.width,
  });

  @override
  State<PopupAnimator> createState() => PopupAnimatorState();
}

class PopupAnimatorState extends State<PopupAnimator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 120),
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  late final Animation<double> _scale =
      Tween(begin: 0.95, end: 1.0).animate(_curved);

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  /// 退场动画。结束后 resolve（调用方随后 entry.remove()）。
  Future<void> dismiss() => _c.reverse();

  @override
  void dispose() {
    _curved.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: _curved,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onScrimTap,
              child: Container(color: const Color(0x14000000)),
            ),
          ),
        ),
        Positioned(
          top: widget.top,
          bottom: widget.bottom,
          left: widget.left,
          right: widget.right,
          width: widget.width,
          child: FadeTransition(
            opacity: _curved,
            child: ScaleTransition(
              scale: _scale,
              alignment: widget.origin,
              // 弹层挂在 Overlay 上，不在 Scaffold 的 Material 子树内，
              // DefaultTextStyle 会回落到 Flutter 的调试样式（红字 + 黄色双下划线）。
              // 在此统一兜住，所有走 PopupAnimator 的弹层都无需各自包 Material。
              child: Material(
                type: MaterialType.transparency,
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 在线指示点：轻量呼吸。
class BreathingDot extends StatefulWidget {
  final Color color;
  const BreathingDot({super.key, required this.color});

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.45).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 下拉选项。subtitle 为可选副标题。
class DropdownOption {
  final String id;
  final String label;
  final String? subtitle;
  final IconData? icon;
  const DropdownOption({
    required this.id,
    required this.label,
    this.subtitle,
    this.icon,
  });
}

/// 通用下拉：胶囊触发器（文字+箭头，窄屏自动截断）+ Overlay 垂直菜单。受控。
/// 选中态遵循规范 1.3：文字黑、功能图标灰、仅勾为 accent。
class ChipDropdown extends StatefulWidget {
  final IconData? triggerIcon;
  final String triggerLabel;
  final List<DropdownOption> options;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final double minWidth;
  final bool wide;

  const ChipDropdown({
    super.key,
    this.triggerIcon,
    required this.triggerLabel,
    required this.options,
    required this.selectedId,
    required this.onSelect,
    this.minWidth = 80,
    this.wide = false,
  });

  @override
  State<ChipDropdown> createState() => _ChipDropdownState();
}

class _ChipDropdownState extends State<ChipDropdown> {
  OverlayEntry? _entry;
  /// 退场动画中尚未移除的 entry；重开时先强制移除，避免 GlobalKey 冲突。
  OverlayEntry? _exiting;
  final _popupKey = GlobalKey<PopupAnimatorState>();
  bool _triggerDown = false;
  bool get _open => _entry != null;

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    _killExiting();
    final box = context.findRenderObject() as RenderBox;
    final off = box.localToGlobal(Offset.zero);
    final w = box.size.width;
    _entry = OverlayEntry(
      builder: (ctx) => PopupAnimator(
        key: _popupKey,
        onScrimTap: _close,
        origin: Alignment.topLeft,
        top: off.dy + box.size.height + 6,
        left: widget.wide ? AppSpacing.pageMargin : off.dx,
        right: widget.wide ? AppSpacing.pageMargin : null,
        width: widget.wide ? null : (w < widget.minWidth ? widget.minWidth : w),
        child: _menu(),
      ),
    );
    Overlay.of(context).insert(_entry!);
    PopupRegistry.instance.register(_close);
    setState(() {});
  }

  void _killExiting() {
    final e = _exiting;
    if (e != null) {
      _exiting = null;
      e.remove();
    }
  }

  Widget _menu() {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.popup,
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: widget.options
            .map((o) => _DropdownItem(
                  option: o,
                  selected: o.id == widget.selectedId,
                  onTap: () {
                    widget.onSelect(o.id);
                    _close();
                  },
                ))
            .toList(),
      ),
    );
  }

  void _close() {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    PopupRegistry.instance.unregister(_close);
    if (mounted) setState(() {});
    // 先播退场动画再移除 entry（§UX-1.1：反向 120ms easeIn）。
    final st = _popupKey.currentState;
    if (st == null) {
      entry.remove();
      return;
    }
    _exiting = entry;
    st.dismiss().then((_) {
      if (_exiting != entry) return; // 已被重开逻辑强制移除。
      _exiting = null;
      entry.remove();
    });
  }

  @override
  void dispose() {
    if (_entry != null) PopupRegistry.instance.unregister(_close);
    _entry?.remove();
    _killExiting();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _triggerDown = true),
      onTapUp: (_) => setState(() => _triggerDown = false),
      onTapCancel: () => setState(() => _triggerDown = false),
      onTap: _toggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _triggerDown ? const Color(0xFFDADAE0) : AppColors.keyCapOf(context),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        // 触发器文字用 Flexible+ellipsis，窄屏被外层 Flexible 约束时截断。
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.triggerIcon != null) ...[
              Icon(widget.triggerIcon, size: 12, color: AppColors.textSecondaryOf(context)),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                widget.triggerLabel,
                style: AppText.callout.copyWith(color: AppColors.textPrimaryOf(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              _open ? AppIcons.chevronUp : AppIcons.chevronDown,
              size: 12,
              color: AppColors.textSecondaryOf(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// 下拉选项行：选中 = 黑字 + 灰图标 + 蓝勾（规范 1.3）。
class _DropdownItem extends StatefulWidget {
  final DropdownOption option;
  final bool selected;
  final VoidCallback onTap;
  const _DropdownItem({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_DropdownItem> createState() => _DropdownItemState();
}

class _DropdownItemState extends State<_DropdownItem> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    final hasSub = widget.option.subtitle != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _down ? AppColors.keyCapOf(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (widget.option.icon != null) ...[
              Icon(widget.option.icon, size: 16, color: AppColors.textSecondaryOf(context)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.option.label,
                    style: AppText.bodyStrong.copyWith(
                      color: AppColors.textPrimaryOf(context),
                    ),
                  ),
                  if (hasSub) ...[
                    const SizedBox(height: 2),
                    Text(widget.option.subtitle!, style: AppText.caption),
                  ],
                ],
              ),
            ),
            if (widget.selected)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Icon(AppIcons.check, size: 16, color: AppColors.accentOf(context)),
              ),
          ],
        ),
      ),
    );
  }
}