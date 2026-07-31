import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_text_styles.dart';

/// SENTINEL 全局主题（浅色极简）。组件多自定义，此处设全局基调。
abstract final class AppTheme {
  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: const ColorScheme.light(
        primary: AppColors.accent,
        surface: AppColors.surface,
        error: AppColors.reject,
      ),
      textTheme: const TextTheme(
        titleLarge: AppText.title1,
        titleMedium: AppText.title2,
        bodyLarge: AppText.body,
        bodyMedium: AppText.callout,
        bodySmall: AppText.caption,
      ),
      splashFactory: NoSplash.splashFactory, // 克制：去水波纹
    );
  }
}