/// 级联配置菜单：home → provider / model / thinking（§09 级联结构）。
///
/// 从 home_shell.dart 拆出（U1-1，Issue #35）。行为零变化，仅文件归位与去私有化。
library;

import 'package:flutter/material.dart';
import 'package:hux/hux.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/common.dart';
import 'config_options.dart';

// ---------- 级联配置菜单：home → provider / model / thinking（§09 级联结构）----------

/// 顶栏单一触发器，弹出后先显示 provider / model / thinking 三个入口，
/// 点击入口进入对应选择列表。选中即下发并关闭（§UX-1.2 层级过渡）。
class CascadeConfigMenu extends StatefulWidget {
  final dynamic cfg;
  final String effortId;
  final List<DropdownOption> effortOpts;
  final Map<String, String> effortLabel;
  final ValueChanged<String> onModel;
  final ValueChanged<String> onEffort;

  const CascadeConfigMenu({
    super.key,
    required this.cfg,
    required this.effortId,
    required this.effortOpts,
    required this.effortLabel,
    required this.onModel,
    required this.onEffort,
  });

  @override
  State<CascadeConfigMenu> createState() => _CascadeConfigMenuState();
}

class _CascadeConfigMenuState extends State<CascadeConfigMenu> {
  OverlayEntry? _entry;
  /// 退场动画中尚未移除的 entry；重开时先强制移除，避免 GlobalKey 冲突。
  OverlayEntry? _exiting;
  final _popupKey = GlobalKey<PopupAnimatorState>();
  double _menuMaxH = 300;
  /// 面板切换方向：true = 下钻（新层从右入），false = 返回（§UX-1.2 层级过渡）。
  bool _navForward = true;
  /// 当前面板：home / provider / model / effort。
  String _panel = 'home';
  bool _expandProvider = false;
  bool _expandModel = false;
  bool _expandThinking = false;
  bool get _open => _entry != null;

  List<Map<String, dynamic>> get _models => cfgList(widget.cfg, 'model');
  String get _curModel => cfgCur(widget.cfg, 'model');
  String get _curProvider => provOf(_curModel);

  List<String> get _providers {
    final seen = <String>[];
    for (final o in _models) {
      final p = provOf(o['value']?.toString() ?? '');
      if (!seen.contains(p)) seen.add(p);
    }
    return seen;
  }

  List<Map<String, dynamic>> _modelsOf(String prov) => _models
      .where((o) => provOf(o['value']?.toString() ?? '') == prov)
      .toList();

  String get _curModelLabel {
    final cur = _curModel;
    for (final o in _models) {
      if (o['value'] == cur) return o['name']?.toString() ?? cur;
    }
    return cur.isEmpty ? '选择模型' : cur;
  }

  String get _curEffortLabel {
    return widget.effortLabel[widget.effortId] ??
        widget.effortOpts
            .firstWhere((e) => e.id == widget.effortId,
                orElse: () => widget.effortOpts.first)
            .label;
  }

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    _killExiting();
    _panel = 'home';
    _expandProvider = false;
    _expandModel = false;
    _expandThinking = false;
    _navForward = true;
    final box = context.findRenderObject() as RenderBox;
    final off = box.localToGlobal(Offset.zero);

    // 防溢出：下方空间不足且上方更宽时，菜单翻到触发点上方弹出；maxH 取可用高度。
    final vh = MediaQuery.of(context).size.height;
    final screenW = MediaQuery.of(context).size.width;
    final topY = off.dy + box.size.height + 6;
    final availBelow = vh - topY;
    final availAbove = off.dy - 6;
    final above = availBelow < 340 && availAbove > availBelow;
    _menuMaxH = (above ? availAbove : availBelow).clamp(160.0, 360.0);
    const width = 216.0;
    final left = (AppSpacing.pageMargin + width > screenW - 8)
        ? screenW - 8 - width
        : AppSpacing.pageMargin;

    _entry = OverlayEntry(builder: (ctx) {
      return StatefulBuilder(builder: (ctx2, setOverlay) {
        return PopupAnimator(
          key: _popupKey,
          onScrimTap: _close,
          origin: above ? Alignment.bottomLeft : Alignment.topLeft,
          top: above ? null : topY,
          bottom: above ? (vh - off.dy + 6) : null,
          left: left,
          width: width,
          child: HuxCard(
            margin: EdgeInsets.zero,
            padding: EdgeInsets.zero,
            borderRadius: AppRadius.card,
            backgroundColor: AppColors.surfaceOf(context),
            borderColor: AppColors.hairlineOf(context),
            elevation: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(setOverlay),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: _menuMaxH),
                  child: SingleChildScrollView(
                    // 层级切换：水平位移 + 淡入淡出，高度变化用 AnimatedSize 平滑（§UX-1.2）。
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previous,
                            ?current,
                          ],
                        ),
                        transitionBuilder: (child, anim) {
                          // 下钻：新层右侧入、旧层左侧出；返回时相反。
                          final incoming = child.key == ValueKey(_panel);
                          final begin = (_navForward == incoming)
                              ? const Offset(0.12, 0)
                              : const Offset(-0.12, 0);
                          return SlideTransition(
                            position: Tween(begin: begin, end: Offset.zero)
                                .animate(anim),
                            child: FadeTransition(opacity: anim, child: child),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(_panel),
                          child: _panelList(setOverlay),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ),
        );
      });
    });
    Overlay.of(context).insert(_entry!);
    PopupRegistry.instance.register(_close);
    setState(() {});
  }


  void _back(StateSetter setOverlay) {
    _navForward = false;
    setOverlay(() {
      _panel = 'home';
    });
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

  Widget _header(StateSetter setOverlay) {
    final titles = {
      'home': '配置',
      'provider': 'Provider',
      'model': 'Model',
      'effort': '思考深度',
    };
    final title = titles[_panel] ?? '配置';
    final showBack = _panel != 'home';
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairlineOf(context))),
      ),
      child: Row(
        children: [
          if (showBack)
            Pressable(
              onTap: () => _back(setOverlay),
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(AppIcons.arrowLeft,
                    size: 15, color: AppColors.textSecondaryOf(context)),
              ),
            )
          else
            const SizedBox(width: 28, height: 28),
          Expanded(
            // 标题随层级淡入淡出切换（§UX-1.2）。
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Text(
                title,
                key: ValueKey(title),
                textAlign: TextAlign.center,
                style: AppText.calloutStrong,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 28, height: 28),
        ],
      ),
    );
  }

  Widget _panelList(StateSetter setOverlay) => _homePanel(setOverlay);

  Widget _homePanel(StateSetter setOverlay) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _expandableGroup(
          title: 'Provider',
          value: _curProvider.isEmpty ? '—' : _curProvider,
          expanded: _expandProvider,
          onToggle: () => setOverlay(() => _expandProvider = !_expandProvider),
          options: _providers.map((p) => _row(
                p,
                selected: p == _curProvider,
                onTap: () {
                  final first = _modelsOf(p).firstOrNull;
                  if (first != null) {
                    widget.onModel(first['value']?.toString() ?? '');
                  }
                },
              )).toList(),
        ),
        _expandableGroup(
          title: 'Model',
          value: _curModelLabel,
          expanded: _expandModel,
          onToggle: () => setOverlay(() => _expandModel = !_expandModel),
          options: _modelsOf(_curProvider).map((o) => _row(
                o['name']?.toString() ?? o['value']?.toString() ?? '',
                selected: o['value'] == _curModel,
                onTap: () => widget.onModel(o['value']?.toString() ?? ''),
              )).toList(),
        ),
        _expandableGroup(
          title: 'Thinking',
          value: _curEffortLabel,
          expanded: _expandThinking,
          onToggle: () => setOverlay(() => _expandThinking = !_expandThinking),
          options: widget.effortOpts.map((e) => _row(
                widget.effortLabel[e.id] ?? e.label,
                selected: e.id == widget.effortId,
                onTap: () => widget.onEffort(e.id),
              )).toList(),
        ),
      ],
    );
  }

  Widget _expandableGroup({
    required String title,
    required String value,
    required bool expanded,
    required VoidCallback onToggle,
    required List<Widget> options,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: double.infinity,
          child: Pressable(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text(title,
                            style: AppText.calloutStrong.copyWith(
                              color: AppColors.textPrimaryOf(context),
                            )),
                        if (value.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(value,
                                textAlign: TextAlign.left,
                                style: AppText.caption.copyWith(
                                    color: AppColors.textSecondaryOf(context)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(AppIcons.chevronDown,
                        size: 14, color: AppColors.placeholderOf(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: options,
          ),
          crossFadeState:
              expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }


  Widget _row(String label,
      {bool selected = false, required VoidCallback onTap}) {
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: (selected ? AppText.calloutStrong : AppText.callout).copyWith(
                    color: AppColors.textPrimaryOf(context),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (selected)
              Icon(AppIcons.check, size: 15, color: AppColors.accentOf(context)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return HuxButton(
      onPressed: _toggle,
      variant: HuxButtonVariant.secondary,
      size: HuxButtonSize.small,
      icon: AppIcons.modelChip,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 128),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _curModelLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              _open ? AppIcons.chevronUp : AppIcons.chevronDown,
              size: 12,
            ),
          ],
        ),
      ),
    );
  }
}
