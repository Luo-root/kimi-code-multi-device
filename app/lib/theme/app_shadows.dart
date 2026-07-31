import 'package:flutter/widgets.dart';

/// SENTINEL 阴影令牌。柔和弥散，非硬边，低透明大扩散。
abstract final class AppShadows {
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0F000000), blurRadius: 24, offset: Offset(0, 8)),
  ];
  static const List<BoxShadow> input = [
    BoxShadow(color: Color(0x0D000000), blurRadius: 12, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> popup = [
    BoxShadow(color: Color(0x1A000000), blurRadius: 32, offset: Offset(0, 12)),
  ];
}