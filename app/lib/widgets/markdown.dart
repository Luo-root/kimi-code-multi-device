import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../widgets/common.dart';

/// 列表项（marker 如 "1." 或 "•"，text 为内容）。
typedef _ListItem = ({String marker, String text});

/// 轻量 Markdown 渲染：AI 输出按 Markdown 语义渲染。
/// 支持：标题(#..)、加粗/斜体、行内码、代码块(```)、无序/有序列表、
/// 链接、引用(>)、分割线(---)。不引第三方包（自托管、零网络依赖），
/// 样式用 SENTINEL 令牌，代码块用等宽 + 浅底，贴合整体气质。
class MarkdownView extends StatelessWidget {
  final String data;
  const MarkdownView({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(data, context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == blocks.length - 1 ? 0 : 8),
            child: blocks[i],
          ),
      ],
    );
  }

  // ---------- 块级解析 ----------

  List<Widget> _parseBlocks(String src, BuildContext ctx) {
    final lines = src.split('\n');
    final out = <Widget>[];
    var i = 0;
    final paraBuf = StringBuffer();
    void flushPara() {
      final t = paraBuf.toString().trimRight();
      if (t.trim().isNotEmpty) out.add(_paragraph(t));
      paraBuf.clear();
    }

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trimRight();

      // 代码块 ```
      if (trimmed.trimLeft().startsWith('```')) {
        flushPara();
        final lang = trimmed.trimLeft().substring(3).trim();
        final codeBuf = StringBuffer();
        i++;
        while (i < lines.length && !lines[i].trimRight().trimLeft().startsWith('```')) {
          codeBuf.writeln(lines[i]);
          i++;
        }
        i++; // 跳过收尾 ```
        out.add(_codeBlock(codeBuf.toString().trimRight(), lang, ctx));
        continue;
      }

      // 空行 → 段落分隔
      if (trimmed.isEmpty) {
        flushPara();
        i++;
        continue;
      }

      // 分割线 ---
      if (RegExp(r'^\s*(-{3,}|\*{3,})\s*$').hasMatch(trimmed)) {
        flushPara();
        out.add(Container(height: 1, color: AppColors.hairline));
        i++;
        continue;
      }

      // 标题
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (h != null) {
        flushPara();
        out.add(_heading(h.group(1)!.length, h.group(2)!));
        i++;
        continue;
      }

      // 引用
      if (trimmed.trimLeft().startsWith('>')) {
        flushPara();
        final qBuf = StringBuffer();
        while (i < lines.length && lines[i].trimRight().trimLeft().startsWith('>')) {
          qBuf.writeln(lines[i].trimRight().trimLeft().substring(1).trimLeft());
          i++;
        }
        out.add(_quote(qBuf.toString().trimRight()));
        continue;
      }

      // 列表（无序 -/*/+ 或有序 1.）
      final lm = RegExp(r'^\s*(([-*+])|(\d+\.))\s+(.*)$').firstMatch(trimmed);
      if (lm != null) {
        flushPara();
        final items = <_ListItem>[];
        var ordered = false;
        while (i < lines.length) {
          // 组号：1=整个标记，2=无序(-/*/+)，3=有序(1.)，4=内容。
          final m2 = RegExp(r'^\s*(([-*+])|(\d+\.))\s+(.*)$')
              .firstMatch(lines[i].trimRight());
          if (m2 == null) break;
          final isNum = m2.group(3) != null;
          if (items.isEmpty) ordered = isNum;
          items.add((marker: m2.group(3) ?? '•', text: m2.group(4)!));
          i++;
        }
        out.add(_list(items, ordered));
        continue;
      }

      // 普通文本行 → 累积进段落
      paraBuf.writeln(line);
      i++;
    }
    flushPara();
    return out;
  }

  // ---------- 块级渲染 ----------

  Widget _paragraph(String text) {
    return _InlineText(text, style: AppText.body);
  }

  Widget _heading(int level, String text) {
    final size = switch (level) {
      1 => 19.0,
      2 => 17.5,
      3 => 16.0,
      _ => 15.0,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: _InlineText(
        text,
        style: AppText.body.copyWith(
            fontSize: size, fontWeight: FontWeight.w700, height: 1.35),
      ),
    );
  }

  Widget _quote(String text) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.placeholder, width: 3)),
      ),
      padding: const EdgeInsets.only(left: 10),
      child: _InlineText(
        text,
        style: AppText.callout.copyWith(
            color: AppColors.textSecondary, fontStyle: FontStyle.italic),
      ),
    );
  }

  Widget _list(List<_ListItem> items, bool ordered) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: ordered ? 22 : 14,
                  child: Text(
                    ordered ? '${i + 1}.' : '•',
                    style: AppText.body.copyWith(color: AppColors.textSecondary),
                  ),
                ),
                Expanded(child: _InlineText(items[i].text, style: AppText.body)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _codeBlock(String code, String lang, BuildContext ctx) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.textPrimary, // 深色代码块，命令/代码用合适的方式呈现
        borderRadius: BorderRadius.circular(AppRadius.thumbnail),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (lang.isNotEmpty)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                    child: Text(lang,
                        style: AppText.monoCaption.copyWith(
                            color: const Color(0xFF8E8E93))),
                  ),
                )
              else
                const Spacer(),
              // §UX-2.2：代码块保留复制按钮（高频操作），深色块内用幽灵样式。
              CopyButton(text: code, dark: true),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              code,
              style: AppText.mono.copyWith(
                  color: const Color(0xFFECECEF), height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

}

/// 行内 Markdown：解析 **bold**、*italic*、`code`、[text](url)。
class _InlineText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const _InlineText(this.text, {required this.style});

  static final _re = RegExp(
      r'(\*\*\*.+?\*\*\*|\*\*.+?\*\*|___.+?___|__.+?__|(?<!\*)\*[^*\n]+?\*(?!\*)|(?<!_)_[^_\n]+?_(?!_)|`[^`\n]+`|\[[^\]\n]+\]\([^)\n]+\))');

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(_span(m.group(0)!, context));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    if (spans.isEmpty) spans.add(const TextSpan(text: ''));
    return Text.rich(TextSpan(children: spans), style: style);
  }

  InlineSpan _span(String tok, BuildContext ctx) {
    // 链接：可点击打开（失败则复制链接 + toast）。
    final lm = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)$').firstMatch(tok);
    if (lm != null) {
      final label = lm.group(1)!;
      final url = lm.group(2)!;
      // 捕获 messenger，避免异步间隙使用 BuildContext（链接可能跨 await）。
      final messenger = ScaffoldMessenger.of(ctx);
      return TextSpan(
        text: label,
        style: const TextStyle(
            color: AppColors.accent, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () async {
            final uri = Uri.tryParse(url);
            if (uri != null) {
              try {
                if (!await launchUrl(uri,
                    mode: LaunchMode.externalApplication)) {
                  copyToClipboard(messenger, url);
                }
                return;
              } catch (_) {
                // 无可用浏览器等：退回复制链接。
              }
            }
            copyToClipboard(messenger, url);
          },
      );
    }
    // 行内码
    if (tok.startsWith('`') && tok.endsWith('`') && tok.length > 1) {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: AppColors.keyCap,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(tok.substring(1, tok.length - 1),
              style: AppText.mono.copyWith(fontSize: 12)),
        ),
      );
    }
    // 加粗斜体
    if (tok.startsWith('***') || tok.startsWith('___')) {
      return TextSpan(
        text: tok.substring(3, tok.length - 3),
        style:
            const TextStyle(fontWeight: FontWeight.w700, fontStyle: FontStyle.italic),
      );
    }
    // 加粗
    if (tok.startsWith('**') || tok.startsWith('__')) {
      return TextSpan(
        text: tok.substring(2, tok.length - 2),
        style: const TextStyle(fontWeight: FontWeight.w700),
      );
    }
    // 斜体
    if ((tok.startsWith('*') && tok.endsWith('*')) ||
        (tok.startsWith('_') && tok.endsWith('_'))) {
      return TextSpan(
        text: tok.substring(1, tok.length - 1),
        style: const TextStyle(fontStyle: FontStyle.italic),
      );
    }
    return TextSpan(text: tok);
  }
}
