import 'package:flutter/widgets.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// SENTINEL 图标令牌。全部 Lucide 线性图标，绝不用 emoji。
abstract final class AppIcons {
  // 导航 / 全局
  static const IconData menu = LucideIcons.menu;
  static const IconData settings = LucideIcons.settings;
  static const IconData bell = LucideIcons.bell;
  static const IconData plus = LucideIcons.plus;
  static const IconData close = LucideIcons.x;
  static const IconData history = LucideIcons.history;
  static const IconData arrowLeft = LucideIcons.arrow_left;
  static const IconData chevronRight = LucideIcons.chevron_right;
  static const IconData chevronDown = LucideIcons.chevron_down;
  static const IconData chevronUp = LucideIcons.chevron_up;
  static const IconData palette = LucideIcons.palette; // 开发期跳 showcase
  static const IconData folder = LucideIcons.folder; // 工作区分组
  static const IconData modelChip = LucideIcons.cpu; // 模型选择触发器
  static const IconData thinking = LucideIcons.sparkles; // 思考强度
  static const IconData command = LucideIcons.command; // slash 命令菜单
  static const IconData search = LucideIcons.search; // 抽屉搜索
  
  // 会话模式（哨兵在不在场）
  static const IconData modeManual = LucideIcons.shield;
  static const IconData modePlan = LucideIcons.eye;
  static const IconData modeAuto = LucideIcons.zap;
  static const IconData modeYolo = LucideIcons.rocket;

  // 输入区
  static const IconData send = LucideIcons.arrow_up;
  static const IconData mic = LucideIcons.mic;
  static const IconData stop = LucideIcons.square;

  // 流内容
  static const IconData terminal = LucideIcons.terminal;
  static const IconData check = LucideIcons.check;
}