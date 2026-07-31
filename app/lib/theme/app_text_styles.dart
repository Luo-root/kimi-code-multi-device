import 'package:flutter/widgets.dart';
import 'app_colors.dart';

/// SENTINEL 排版令牌。正文用系统默认无衬线（iOS: SF / 中文: PingFang SC），
/// 等宽用 Menlo（命令/输出），回退 Courier / monospace。
abstract final class AppText {
  static const List<String> _monoFallback = ['Courier', 'monospace'];

  static const TextStyle title1 = TextStyle(
    fontSize: 17, fontWeight: FontWeight.w500,
    color: AppColors.textPrimary, height: 1.3,
  );
  static const TextStyle title2 = TextStyle(
    fontSize: 16, fontWeight: FontWeight.w500,
    color: AppColors.textPrimary, height: 1.3,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15, fontWeight: FontWeight.w400,
    color: AppColors.textPrimary, height: 1.6,
  );
  static const TextStyle callout = TextStyle(
    fontSize: 13, fontWeight: FontWeight.w400,
    color: AppColors.textPrimary, height: 1.5,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12, fontWeight: FontWeight.w400,
    color: AppColors.textSecondary, height: 1.4,
  );
  static const TextStyle placeholder = TextStyle(
    fontSize: 15, fontWeight: FontWeight.w400,
    color: AppColors.placeholder, height: 1.6,
  );
  static const TextStyle mono = TextStyle(
    fontFamily: 'Menlo', fontFamilyFallback: _monoFallback,
    fontSize: 12, fontWeight: FontWeight.w400,
    color: AppColors.textPrimary, height: 1.5,
  );
  static const TextStyle monoCaption = TextStyle(
    fontFamily: 'Menlo', fontFamilyFallback: _monoFallback,
    fontSize: 11, fontWeight: FontWeight.w400,
    color: AppColors.textSecondary, height: 1.4,
  );
}