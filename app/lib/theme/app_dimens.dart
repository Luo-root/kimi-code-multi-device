/// SENTINEL 间距与圆角令牌。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;

  static const double pageMargin = 16; // 页边距，严禁贴边
  static const double listItemGap = 16; // 列表项间距（不用分割线）
}

abstract final class AppRadius {
  static const double card = 20; // 卡片/批准卡/输入框
  static const double thumbnail = 12; // 缩略图/工具卡
  static const double pill = 999; // 胶囊按钮/状态点（全圆角）
  static const double popup = 12; // 浮层/弹层圆角
}