/// 顶栏三件套：TopBar / ModeIconMenu / MenuRow。
///
/// 从 home_shell.dart 拆出（U1-3，Issue #35）。行为零变化，仅文件归位与去私有化。
library;

import 'package:flutter/material.dart';
import 'package:hux/hux.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_text_styles.dart';
import '../../theme/theme_mode_store.dart';
import '../../widgets/common.dart';
import 'cascade_config_menu.dart';
import 'config_options.dart';

class TopBar extends StatelessWidget {
  final dynamic cfg;
  final String effortId;
  final String relayState;
  final ValueChanged<String> onModel;
  final ValueChanged<String> onEffort;
  final ValueChanged<String> onMode;

  const TopBar({
    super.key,
    required this.cfg,
    required this.effortId,
    required this.relayState,
    required this.onModel,
    required this.onEffort,
    required this.onMode,
  });

  @override
  Widget build(BuildContext context) {
    final dot = switch (relayState) {
      'ok' => AppColors.approve,
      'degraded' => AppColors.warning,
      _ => AppColors.placeholderOf(context),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      child: Row(
        children: [
          _iconBtn(AppIcons.menu,
              onTap: () => Scaffold.of(context).openDrawer()),
          const SizedBox(width: 2),
          // 主题切换（浅色/暗色），偏好持久化。
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (_, mode, _) => _iconBtn(
              mode == ThemeMode.dark ? AppIcons.sun : AppIcons.moon,
              onTap: () => setThemeMode(
                mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // provider·model·思考深度 → 一个级联主菜单（§09 级联结构）。
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: CascadeConfigMenu(
                cfg: cfg,
                effortId: effortId,
                effortOpts: kEffortOpts,
                effortLabel: kEffortLabel,
                onModel: onModel,
                onEffort: onEffort,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          ModeIconMenu(cfg: cfg, onMode: onMode),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, {VoidCallback? onTap}) {
    return HuxButton(
      onPressed: onTap ?? () {},
      variant: HuxButtonVariant.ghost,
      size: HuxButtonSize.small,
      icon: icon,
      child: const SizedBox(width: 0),
    );
  }
}
// ---------- mode 图标菜单（真实 mode options）----------

class ModeIconMenu extends StatefulWidget {
  final dynamic cfg;
  final ValueChanged<String> onMode;
  const ModeIconMenu({super.key, required this.cfg, required this.onMode});

  @override
  State<ModeIconMenu> createState() => _ModeIconMenuState();
}

class _ModeIconMenuState extends State<ModeIconMenu> {
  OverlayEntry? _entry;
  /// 退场动画中尚未移除的 entry；重开时先强制移除，避免 GlobalKey 冲突。
  OverlayEntry? _exiting;
  final _popupKey = GlobalKey<PopupAnimatorState>();
  double _menuMaxH = 320;
  bool get _open => _entry != null;

  void _toggle() => _open ? _close() : _openMenu();

  List<Map<String, dynamic>> get _modes {
    final real = cfgList(widget.cfg, 'mode');
    if (real.isNotEmpty) return real;
    return kModeIcon.keys
        .map((k) => <String, dynamic>{
              'value': k,
              'name': k,
              'description': kModeFallbackDesc[k],
            })
        .toList();
  }

  void _openMenu() {
    _killExiting();
    final box = context.findRenderObject() as RenderBox;
    final off = box.localToGlobal(Offset.zero);
    final cur = cfgCur(widget.cfg, 'mode');
    // 防溢出：下方不足且上方更宽时翻到上方弹出；maxH 取可用高度。
    final vh = MediaQuery.of(context).size.height;
    final topY = off.dy + box.size.height + 6;
    final availBelow = vh - topY;
    final availAbove = off.dy - 6;
    final above = availBelow < 320 && availAbove > availBelow;
    _menuMaxH = (above ? availAbove : availBelow).clamp(160.0, 360.0);
    _entry = OverlayEntry(
      builder: (ctx) => PopupAnimator(
        key: _popupKey,
        onScrimTap: _close,
        origin: above ? Alignment.bottomRight : Alignment.topRight,
        top: above ? null : topY,
        bottom: above ? (vh - off.dy + 6) : null,
        right: 8,
        width: 168,
        child: HuxCard(
          margin: EdgeInsets.zero,
          padding: const EdgeInsets.symmetric(vertical: 8),
          borderRadius: AppRadius.card,
          backgroundColor: AppColors.surfaceOf(context),
          borderColor: AppColors.hairlineOf(context),
          elevation: 0,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _menuMaxH),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _modes
                    .map((m) => MenuRow(
                          icon: kModeIcon[m['value']] ?? AppIcons.modeManual,
                          label: m['name']?.toString() ??
                              m['value']?.toString() ??
                              '',
                          selected: m['value'] == cur,
                          onTap: () {
                            widget.onMode(m['value']?.toString() ?? '');
                            _close();
                          },
                        ))
                    .toList(),
              ),
            ),
          ),
        ),
        ),
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
    final cur = cfgCur(widget.cfg, 'mode');
    final icon = kModeIcon[cur] ?? AppIcons.modeManual;
    return Semantics(
      label: '切换模式',
      button: true,
      child: HuxButton(
        onPressed: _toggle,
        variant: HuxButtonVariant.secondary,
        size: HuxButtonSize.small,
        icon: icon,
        child: const SizedBox(width: 0),
      ),
    );
  }
}

class MenuRow extends StatefulWidget {
  final IconData? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const MenuRow({
    super.key,
    required this.label,
    this.icon,
    this.selected = false,
    required this.onTap,
  });

  @override
  State<MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<MenuRow> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
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
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 16, color: AppColors.textSecondaryOf(context)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(widget.label,
                  style: AppText.calloutStrong.copyWith(
                    color: AppColors.textPrimaryOf(context),
                  )),
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
