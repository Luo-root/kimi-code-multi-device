import 'package:flutter/widgets.dart';

/// SENTINEL 色彩令牌。85/5/10：中性主导，语义色仅决策点，装饰色点缀。
abstract final class AppColors {
  // ---- 中性色阶（85%）----
  static const Color background = Color(0xFFF7F8FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color keyCap = Color(0xFFE5E5EA);
  static const Color textPrimary = Color(0xFF1D1D1F);
  static const Color textSecondary = Color(0xFF86868B);
  static const Color placeholder = Color(0xFFC0C0C0);
  static const Color hairline = Color(0xFFEEF0F2);

  // ---- 语义色（5%，克制，仅决策点）----
  static const Color accent = Color(0xFF007AFF); // 选中/C位/链接
  static const Color approve = Color(0xFF34C759); // 批准/在线/完成
  static const Color reject = Color(0xFFFF3B30); // 拒绝/关键命令/失败
  static const Color warning = Color(0xFFFF9500); // 降级/将睡/待批准
  static const Color think = Color(0xFF8E8E93); // 思考（中性，冷静）

  // ---- 语义色淡底（ARGB 直定义，避免废弃 API）----
  static const Color accentSoft = Color(0x1A007AFF); // ~10%
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
}