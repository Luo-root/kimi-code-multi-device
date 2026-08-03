import 'package:flutter/material.dart';
import 'package:hux/hux.dart';
import 'app_colors.dart';
import 'app_text_styles.dart';

/// SENTINEL 全局主题：以 hux 设计系统为底座（近中性黑/白主色），
/// 叠加规范画布色与无波纹交互。Kimi 紫已弃用，统一接 hux 颜色。
///
/// 文本色不在此覆盖（`AppText` 已摘掉写死颜色），交还 hux 主题文本色，
/// 使文字随明/暗自动翻转。
abstract final class AppTheme {
  /// 浅色主题：基于 HuxTheme.lightTheme，画布为规范浅灰。
  static ThemeData light() {
    final base = HuxTheme.lightTheme;
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamilyFallback: AppText.fontFamilyFallback),
      primaryTextTheme:
          base.primaryTextTheme.apply(fontFamilyFallback: AppText.fontFamilyFallback),
      scaffoldBackgroundColor: AppColors.background, // #F7F8FA
      splashFactory: NoSplash.splashFactory, // 克制：去水波纹
    );
  }

  /// 深色主题：基于 HuxTheme.darkTheme（hux 内置暗色，契合「月之暗面」）。
  static ThemeData dark() {
    final base = HuxTheme.darkTheme;
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamilyFallback: AppText.fontFamilyFallback),
      primaryTextTheme:
          base.primaryTextTheme.apply(fontFamilyFallback: AppText.fontFamilyFallback),
      scaffoldBackgroundColor: AppColors.backgroundDark, // #0E0E10
      splashFactory: NoSplash.splashFactory,
    );
  }
}
