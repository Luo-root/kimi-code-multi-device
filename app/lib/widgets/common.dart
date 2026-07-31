import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';

/// 按压反馈：轻量透明度变化，克制、无水波纹。
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
      child: AnimatedOpacity(
        opacity: _down ? 0.55 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: widget.child,
      ),
    );
  }
}

/// 在线指示点：轻量呼吸，表示"活着"（功能含义，非装饰）。
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

/// 下拉菜单的一个选项。
class DropdownOption {
  final String id;
  final String label;
  final IconData? icon;
  const DropdownOption({required this.id, required this.label, this.icon});
}

/// 通用下拉触发器：胶囊触发器 + Overlay 垂直菜单（单选枚举的标准形态）。
/// 受控组件：selectedId / onSelect 由外部持有。accent 仅在弹开做选择时出现。
class ChipDropdown extends StatefulWidget {
  final IconData triggerIcon;
  final String triggerLabel;
  final List<DropdownOption> options;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final double minWidth;

  const ChipDropdown({
    super.key,
    required this.triggerIcon,
    required this.triggerLabel,
    required this.options,
    required this.selectedId,
    required this.onSelect,
    this.minWidth = 140,
  });

  @override
  State<ChipDropdown> createState() => _ChipDropdownState();
}

class _ChipDropdownState extends State<ChipDropdown> {
  OverlayEntry? _entry;
  bool get _open => _entry != null;

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    final box = context.findRenderObject() as RenderBox;
    final off = box.localToGlobal(Offset.zero);
    final w = box.size.width;
    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.shrink(),
            ),
          ),
          Positioned(
            top: off.dy + box.size.height + 6,
            left: off.dx,
            width: w < widget.minWidth ? widget.minWidth : w,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.thumbnail),
                boxShadow: AppShadows.popup,
              ),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: widget.options.map((o) {
                  final sel = o.id == widget.selectedId;
                  return Pressable(
                    onTap: () {
                      widget.onSelect(o.id);
                      _close();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Row(
                        children: [
                          if (o.icon != null) ...[
                            Icon(o.icon,
                                size: 15,
                                color: sel
                                    ? AppColors.accent
                                    : AppColors.textSecondary),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: Text(
                              o.label,
                              style: AppText.callout.copyWith(
                                color: sel
                                    ? AppColors.accent
                                    : AppColors.textPrimary,
                                fontWeight:
                                    sel ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (sel)
                            const Icon(AppIcons.check,
                                size: 14, color: AppColors.accent),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: _toggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.keyCap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.triggerIcon, size: 12, color: AppColors.textSecondary),
            const SizedBox(width: 5),
            Text(widget.triggerLabel,
                style: AppText.caption.copyWith(color: AppColors.textPrimary)),
            const SizedBox(width: 3),
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