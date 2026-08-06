import 'package:flutter/widgets.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../relay/models.dart' show looksLikeEditTitle;

/// SENTINEL 图标令牌。全部 Lucide 线性图标，绝不用 emoji。
abstract final class AppIcons {
  // 导航 / 全局
  static const IconData menu = LucideIcons.menu;
  static const IconData settings = LucideIcons.settings;
  static const IconData bell = LucideIcons.bell;
  static const IconData sun = LucideIcons.sun; // 切到浅色
  static const IconData moon = LucideIcons.moon; // 切到暗色
  static const IconData plus = LucideIcons.plus;
  static const IconData close = LucideIcons.x;
  static const IconData history = LucideIcons.history;
  static const IconData arrowLeft = LucideIcons.arrow_left;
  static const IconData chevronRight = LucideIcons.chevron_right;
  static const IconData chevronDown = LucideIcons.chevron_down;
  static const IconData chevronUp = LucideIcons.chevron_up;
  static const IconData folder = LucideIcons.folder; // 工作区分组
  static const IconData ellipsis = LucideIcons.ellipsis; // 行内更多菜单
  static const IconData archive = LucideIcons.archive; // 归档
  static const IconData modelChip = LucideIcons.cpu; // 模型选择触发器
  static const IconData thinking = LucideIcons.sparkles; // 思考强度
  static const IconData command = LucideIcons.command; // slash 命令菜单
  static const IconData search = LucideIcons.search; // 抽屉搜索
  static const IconData rename = LucideIcons.pencil; // 重命名工作区 / 会话
  static const IconData remove = LucideIcons.trash_2; // 移除工作区
  static const IconData fork = LucideIcons.git_fork; // 分叉会话
  static const IconData download = LucideIcons.download; // 导出会话
  
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
  static const IconData copy = LucideIcons.copy; // 复制消息 / 代码 / 命令
  static const IconData file = LucideIcons.file_text; // Read
  static const IconData pencil = LucideIcons.pencil; // Write / Edit（与 rename 同源）
  static const IconData globe = LucideIcons.globe; // WebFetch
  static const IconData listTodo = LucideIcons.list; // TodoWrite

  /// 工具名 → 列表行图标。
  /// AgentGroup 展开后按工具类型用不同图标展示（不只是 terminal）。
  static IconData iconForTool(String? name) {
    if (name == 'Read') return file;
    if (name == 'Write' || name == 'Edit') return pencil;
    final lower = name?.toLowerCase();
    if (lower == 'bash' ||
        lower == 'killbash' ||
        lower == 'terminal' ||
        lower == 'shell' ||
        lower == 'sh' ||
        lower == 'zsh') {
      return terminal;
    }
    if (lower == 'grep' || lower == 'glob' || lower == 'websearch') {
      return search;
    }
    if (lower == 'webfetch') return globe;
    if (lower == 'todowrite') return listTodo;
    if (looksLikeEditTitle(name)) return pencil;
    return terminal;
  }

  // 批准卡
  static const IconData clock = LucideIcons.clock; // 倒计时
  static const IconData alertTriangle = LucideIcons.triangle_alert; // 超时警示
  static const IconData info = LucideIcons.info; // 中性提示（toast）
}