import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../theme/app_shadows.dart';
import '../theme/app_icons.dart';

/// 按压反馈：轻量透明度变化。
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
  bool _triggerDown = false;
  bool get _open => _entry != null;

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    final box = context.findRenderObject() as RenderBox;
    final off = box.localToGlobal(Offset.zero);
    final w = box.size.width;
    _entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.shrink(),
            ),
          ),
          widget.wide
              ? Positioned(
                  top: off.dy + box.size.height + 6,
                  left: AppSpacing.pageMargin,
                  right: AppSpacing.pageMargin,
                  child: _menu(),
                )
              : Positioned(
                  top: off.dy + box.size.height + 6,
                  left: off.dx,
                  width: w < widget.minWidth ? widget.minWidth : w,
                  child: _menu(),
                ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
    setState(() {});
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