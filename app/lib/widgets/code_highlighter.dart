import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:syntax_highlight/syntax_highlight.dart';
import '../theme/app_text_styles.dart';

/// 代码块语法高亮：基于 `syntax_highlight`（VSCode 风格解析器）。
///
/// 由于 Highlighter 需要先异步加载语言文法 + 主题，需在首屏前调用
/// [ensureCodeHighlighterReady] 完成预热；预热未完成时 [highlightCode]
/// 降级为纯文本（无高亮），预热完成后自然切换为高亮，不影响流式渲染。
const List<String> _kLanguages = <String>[
  'dart',
  'python',
  'javascript',
  'typescript',
  'json',
  'bash',
  'shell',
  'yaml',
  'html',
  'xml',
  'css',
  'go',
  'rust',
  'java',
  'sql',
  'markdown',
  'cpp',
  'c',
  'kotlin',
  'swift',
  'objectivec',
  'ruby',
  'php',
  'toml',
  'protobuf',
  'dockerfile',
  'makefile',
  'lua',
  'scala',
  'r',
  'perl',
  'powershell',
  'gradle',
  'vue',
  'svelte',
  'jsx',
  'tsx',
  'less',
  'scss',
  'graphql',
];

HighlighterTheme? _darkTheme;
HighlighterTheme? _lightTheme;
Completer<void>? _initCompleter;
final Map<String, Highlighter> _hlCache = <String, Highlighter>{};

/// 预热语法高亮器：加载语言文法 + 深/浅色主题。幂等，多次调用复用同一 Future。
/// 即使失败也不抛，降级为纯文本，避免阻塞启动。
Future<void> ensureCodeHighlighterReady() {
  if (_initCompleter != null) return _initCompleter!.future;
  final c = Completer<void>();
  _initCompleter = c;
  _init().then(c.complete).catchError((_) => c.complete());
  return c.future;
}

Future<void> _init() async {
  await Highlighter.initialize(_kLanguages);
  _darkTheme = await HighlighterTheme.loadDarkTheme();
  _lightTheme = await HighlighterTheme.loadLightTheme();
}

/// 同步取高亮 TextSpan。未预热完成或语言不支持时降级为浅色等宽纯文本。
TextSpan highlightCode(String code, String language, Brightness brightness) {
  final theme = brightness == Brightness.dark ? _darkTheme : _lightTheme;
  if (theme == null) {
    return TextSpan(
      text: code,
      style: AppText.mono.copyWith(color: const Color(0xFFECECEF)),
    );
  }
  final lang = _kLanguages.contains(language) ? language : 'dart';
  final key = '$lang-${brightness == Brightness.dark ? 'd' : 'l'}';
  final hl = _hlCache.putIfAbsent(key, () => Highlighter(language: lang, theme: theme));
  try {
    return hl.highlight(code);
  } catch (_) {
    return TextSpan(
      text: code,
      style: AppText.mono.copyWith(color: const Color(0xFFECECEF)),
    );
  }
}
