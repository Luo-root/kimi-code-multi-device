import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';

/// 复制到剪贴板并给出轻量 toast 反馈。供消息 / 代码块 / 命令复制复用。
/// 入参用 ScaffoldMessengerState（而非 BuildContext），便于异步回调里安全使用。
void copyToClipboard(ScaffoldMessengerState messenger, String text) {
  if (text.isEmpty) return;
  Clipboard.setData(ClipboardData(text: text));
  HapticFeedback.selectionClick(); // §UX-8.2-2：复制 = .selection。
  messenger.showSnackBar(
    SnackBar(
      content: Text('已复制',
          style: AppText.callout.copyWith(color: AppColors.surface)),
      backgroundColor: AppColors.textPrimary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: const Duration(milliseconds: 1400),
    ),
  );
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
            : (_done ? AppColors.approveSoft : AppColors.keyCap));
    final fg = widget.dark
        ? (_done ? AppColors.approve : const Color(0xFFC7C7CC))
        : (_done ? AppColors.approve : AppColors.textSecondary);
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
              child: widget.child,
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
        color: AppColors.surface,
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
          color: _triggerDown ? const Color(0xFFDADAE0) : AppColors.keyCap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        // 触发器文字用 Flexible+ellipsis，窄屏被外层 Flexible 约束时截断。
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.triggerIcon != null) ...[
              Icon(widget.triggerIcon, size: 12, color: AppColors.textSecondary),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                widget.triggerLabel,
                style: AppText.callout.copyWith(color: AppColors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              _open ? AppIcons.chevronUp : AppIcons.chevronDown,
              size: 12,
              color: AppColors.textSecondary,
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
          color: _down ? AppColors.keyCap : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (widget.option.icon != null) ...[
              Icon(widget.option.icon, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.option.label,
                    style: AppText.body.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
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
              const Padding(
                padding: EdgeInsets.only(left: 10),
                child: Icon(AppIcons.check, size: 16, color: AppColors.accent),
              ),
          ],
        ),
      ),
    );
  }
}