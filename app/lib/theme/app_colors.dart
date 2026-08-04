import 'package:flutter/material.dart';
import 'package:hux/hux.dart';

/// SENTINEL 色彩令牌。85/5/10：中性主导，语义色仅决策点，装饰色点缀。
///
/// 中性色阶提供「浅色常量」（用于浅色主题与少数固定深色底色）与
/// 「上下文感知方法 `XOf(BuildContext)`」（随主题在明/暗间翻转）。
/// 语义色（绿/红/橙/灰）在明暗下保持一致，保留为常量。
abstract final class AppColors {
  // ---- 中性色阶（85%，浅色常量）----
  static const Color background = Color(0xFFF7F8FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color keyCap = Color(0xFFE5E5EA);
  static const Color textPrimary = Color(0xFF1D1D1F);
  static const Color textSecondary = Color(0xFF86868B);
  static const Color placeholder = Color(0xFFC0C0C0);
  static const Color hairline = Color(0xFFEEF0F2);

  /// 暗色画布（scaffold / 大块底色）。
  static const Color backgroundDark = Color(0xFF0E0E10);

  // ---- 语义色（5%，克制，仅决策点，明暗一致）----
  // accent 采用 hux 设计语言（近中性黑/白主色，非 Kimi 紫），用于选中/C位/链接。
  static const Color accent = Color(0xFF1D1D1F); // hux 中性主色：选中/C位/链接
  static const Color approve = Color(0xFF34C759); // 批准/在线/完成
  static const Color reject = Color(0xFFFF3B30); // 拒绝/关键命令/失败
  static const Color warning = Color(0xFFFF9500); // 降级/将睡/待批准
  static const Color think = Color(0xFF8E8E93); // 思考（中性，冷静）

  // ---- 语义色淡底（ARGB 直定义，避免废弃 API）----
  static const Color accentSoft = Color(0x1A1D1D1F); // ~10% 中性主色淡底
  static const Color approveSoft = Color(0x1F34C759); // ~12%
  static const Color rejectSoft = Color(0x1AFF3B30); // ~10%
  static const Color warningSoft = Color(0x1FFF9500); // ~12%
  static const Color thinkSoft = Color(0x148E8E93); // ~8%

  // ---- 装饰色板（10%，点阵/悬浮球，低饱和）----
  static const List<Color> dots = [
    Color(0xFF8E8E93), // 灰
    Color(0xFFA7C7E7), // 淡蓝
    Color(0xFFA8D5A2), // 草绿
    Color(0xFFC3B1E1), // 淡紫
    Color(0xFFE8A0A0), // 暗红
    Color(0xFFF4C2C2), // 粉红
  ];

  // ---- 上下文感知（暗色适配）：随主题在明/暗间翻转 ----
  static bool _isDark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;

  /// 主文本色：浅色近黑 / 暗色近白。
  static Color textPrimaryOf(BuildContext c) => HuxTokens.textPrimary(c);

  /// 次级文本色。
  static Color textSecondaryOf(BuildContext c) => HuxTokens.textSecondary(c);

  /// 卡片/浮层表面色：浅色白 / 暗色近黑。
  static Color surfaceOf(BuildContext c) => HuxTokens.surfacePrimary(c);

  /// 画布（scaffold / 大块底色）。侧边栏等辅助区域继续使用浅灰层级。
  static Color backgroundOf(BuildContext c) =>
      _isDark(c) ? backgroundDark : background;

  /// 主内容画布：浅色用纯白，和浅灰侧边栏拉开层级；暗色保持深色画布，
  /// 避免把 Hux 的浮层 surface 误当成整页背景而显得发亮。
  static Color contentCanvasOf(BuildContext c) =>
      _isDark(c) ? backgroundDark : surface;

  /// 主内容中的轻量控件底色。比 keyCap 更克制，专供 composer / 用户气泡；
  /// 不影响用户已经满意的侧边栏与通用 Hux secondary 按钮。
  static Color quietSurfaceOf(BuildContext c) => _isDark(c)
      ? HuxTokens.buttonSecondaryBackground(c)
      : const Color(0xFFF3F4F6);

  /// 按键/弱底色（如 + 按钮、未选中态）。
  static Color keyCapOf(BuildContext c) =>
      HuxTokens.buttonSecondaryBackground(c);

  /// 占位/禁用文字。
  static Color placeholderOf(BuildContext c) => HuxTokens.textDisabled(c);

  /// 发丝分隔线。
  static Color hairlineOf(BuildContext c) => HuxTokens.borderSecondary(c);

  /// 选中/C位/链接主色：浅色近黑 / 暗色近白（与 hux primary 对齐）。
  static Color accentOf(BuildContext c) => HuxTokens.primary(c);

  /// 选中态淡底：浅色 ~10% 黑 / 暗色 ~12% 白。
  static Color accentSoftOf(BuildContext c) => _isDark(c)
      ? HuxColors.white.withValues(alpha: 0.12)
      : const Color(0x1A1D1D1F);

  /// 思考/工具详情使用的「雾面」底色，比普通 surface 再退一级。
  /// 只承载结构，不与主要回复争夺视觉焦点。
  static Color detailSurfaceOf(BuildContext c) => _isDark(c)
      ? HuxColors.white.withValues(alpha: 0.035)
      : const Color(0xFFF8F9FA);

  /// 思考/工具详情的轻边框与分隔线。
  static Color detailHairlineOf(BuildContext c) => _isDark(c)
      ? HuxColors.white.withValues(alpha: 0.09)
      : const Color(0xFFE7E9EC);

  /// 辅助标签文字：比正文更弱，但仍保持可读。
  static Color detailLabelOf(BuildContext c) => _isDark(c)
      ? HuxColors.white.withValues(alpha: 0.48)
      : const Color(0xFF8B8F96);

  /// Edit diff 的低对比度语义底色。正文色保持正常对比度，避免只靠颜色传达含义。
  static Color diffAddedBgOf(BuildContext c) => _isDark(c)
      ? approve.withValues(alpha: 0.12)
      : approve.withValues(alpha: 0.08);

  static Color diffRemovedBgOf(BuildContext c) => _isDark(c)
      ? reject.withValues(alpha: 0.12)
      : reject.withValues(alpha: 0.08);

  static Color diffModifiedBgOf(BuildContext c) => _isDark(c)
      ? warning.withValues(alpha: 0.12)
      : warning.withValues(alpha: 0.08);

  static Color diffAddedMarkOf(BuildContext c) =>
      _isDark(c) ? const Color(0xFF8AD89A) : const Color(0xFF2F8F46);

  static Color diffRemovedMarkOf(BuildContext c) =>
      _isDark(c) ? const Color(0xFFFFA39D) : const Color(0xFFC03932);

  static Color diffModifiedMarkOf(BuildContext c) =>
      _isDark(c) ? const Color(0xFFFFC66D) : const Color(0xFF9A6500);
}
