import 'package:flutter/widgets.dart';

/// SENTINEL 排版令牌。正文用系统默认无衬线（iOS: SF / 中文: PingFang SC），
/// 等宽用 Menlo（命令/输出），回退 Courier / monospace。
///
/// 颜色不在此处写死：文本色继承主题（`DefaultTextStyle`，随明/暗翻转）。
/// 需要强调时由调用方 `AppText.xxx.copyWith(color: AppColors.xxxOf(context))`。
abstract final class AppText {
  /// Hux 默认主字体 Manrope 主要覆盖拉丁字符，中文需要显式指定系统/平台回退。
  /// 顺序优先保证 Windows 使用简体中文 UI 字形，同时兼容 macOS、Android 和 Linux。
  static const List<String> fontFamilyFallback = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'Source Han Sans CN',
    'sans-serif',
  ];

  static const List<String> _monoFallback = [
    'Courier',
    'monospace',
    ...fontFamilyFallback,
  ];

  static const TextStyle title1 = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.3,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle title2 = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    height: 1.3,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.6,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle callout = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.5,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle calloutStrong = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.5,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle captionStrong = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.4,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle badge = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    height: 1.5,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle placeholder = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.6,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle bodyStrong = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.6,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle link = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.6,
    decoration: TextDecoration.underline,
    fontFamilyFallback: fontFamilyFallback,
  );
  static const TextStyle markdownH1 = TextStyle(
    fontSize: 19, fontWeight: FontWeight.w700, height: 1.35,
  );
  static const TextStyle markdownH2 = TextStyle(
    fontSize: 17.5, fontWeight: FontWeight.w700, height: 1.35,
  );
  static const TextStyle markdownH3 = TextStyle(
    fontSize: 16, fontWeight: FontWeight.w700, height: 1.35,
  );
  static const TextStyle markdownH4 = TextStyle(
    fontSize: 15, fontWeight: FontWeight.w700, height: 1.35,
  );
  static const TextStyle markdownH5 = markdownH4;
  static const TextStyle markdownH6 = markdownH4;
  static const TextStyle mono = TextStyle(
    fontFamily: 'Menlo', fontFamilyFallback: _monoFallback,
    fontSize: 12, fontWeight: FontWeight.w400, height: 1.5,
  );
  static const TextStyle monoCaption = TextStyle(
    fontFamily: 'Menlo', fontFamilyFallback: _monoFallback,
    fontSize: 11, fontWeight: FontWeight.w400, height: 1.4,
  );
}
