/// configOptions 解析（展示层，纯函数）+ mode / 思考强度展示常量。
///
/// 从 home_shell.dart 拆出（U1，Issue #35）：顶栏 / 级联菜单 / 设置页共用同一事实源。
library;

import '../../theme/app_icons.dart';
import '../../widgets/common.dart';

// 思考强度：会话级 ACP 切法待探针确认，此刀占位（受控本地态，不下发）。
const kEffortOpts = [
  DropdownOption(id: 'low', label: '低'),
  DropdownOption(id: 'medium', label: '中'),
  DropdownOption(id: 'high', label: '高'),
];
const kEffortLabel = {'low': '低', 'medium': '中', 'high': '高'};

const kModeIcon = {
  'default': AppIcons.modeManual,
  'plan': AppIcons.modePlan,
  'auto': AppIcons.modeAuto,
  'yolo': AppIcons.modeYolo,
};
const kModeFallbackDesc = {
  'default': '危险动作逐一问你',
  'plan': '只规划，不执行工具',
  'auto': 'agent 自主决策',
  'yolo': '自动批准，但可能问你',
};

String provOf(String v) {
  final i = v.indexOf('/');
  return i < 0 ? v : v.substring(0, i);
}

List<Map<String, dynamic>> cfgList(dynamic cfg, String id) {
  if (cfg is! List) return const [];
  for (final c in cfg) {
    if (c is Map && c['id'] == id) {
      final o = c['options'];
      if (o is List) {
        return o
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      }
    }
  }
  return const [];
}

String cfgCur(dynamic cfg, String id) {
  if (cfg is! List) return '';
  for (final c in cfg) {
    if (c is Map && c['id'] == id) return c['currentValue']?.toString() ?? '';
  }
  return '';
}
