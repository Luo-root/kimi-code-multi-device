import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式持久化与实时切换。
///
/// - `themeModeNotifier`：全局 [ValueNotifier]，顶栏切换按钮改它即可让
///   [MaterialApp] 经 [ValueListenableBuilder] 实时重渲染，无需重启。
/// - `loadThemeMode()`：启动时从本地存储读回上次的偏好（持久化）。
/// - `setThemeMode()`：写入偏好并广播，下次启动自动恢复。
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.light);

const String _kPrefKey = 'sentinel.themeMode';

Future<void> loadThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kPrefKey);
    themeModeNotifier.value = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.light,
    };
  } catch (_) {
    // 读取失败则回退浅色，不阻塞启动。
    themeModeNotifier.value = ThemeMode.light;
  }
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPrefKey,
      switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      },
    );
  } catch (_) {
    // 持久化失败仅丢失记忆，不影响本次切换。
  }
}
