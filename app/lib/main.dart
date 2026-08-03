import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'theme/theme_mode_store.dart';
import 'widgets/code_highlighter.dart';
import 'screens/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 预热语法高亮器（加载语言文法 + 深/浅主题）；失败仅降级为无高亮，不阻塞启动。
  await ensureCodeHighlighterReady();
  // 读回上次的主题偏好（浅色/暗色），实现持久化。
  await loadThemeMode();
  runApp(const SentinelApp());
}

class SentinelApp extends StatelessWidget {
  const SentinelApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 主题模式随 themeModeNotifier 实时变化，切换无需重启 App。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: 'SENTINEL',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        home: const HomeShell(),
      ),
    );
  }
}
