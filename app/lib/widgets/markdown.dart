import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hux/hux.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../widgets/common.dart';
import 'code_highlighter.dart';

/// 活的流 Markdown 渲染：用 flutter_markdown（GFM 标准解析）替代自研渲染器，
/// 代码块通过 `builders['pre']` 接管为深色语法高亮 + 保留复制按钮。
/// 链接点击跳外链（失败回退复制），样式统一接 SENTINEL 令牌。
class MarkdownView extends StatelessWidget {
  final String data;
  const MarkdownView({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: true,
      softLineBreak: true,
      styleSheet: _styleSheet(context),
      onTapLink: (text, href, title) {
        _openLink(context, href);
      },
      builders: <String, MarkdownElementBuilder>{
        'pre': _CodeBlockBuilder(),
      },
    );
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    if (href == null) return;
    final uri = Uri.tryParse(href);
    if (uri == null) {
      copyToClipboard(context, href); // 同步路径：uri 非法直接复制
      return;
    }
    // 失败回退：await 前捕获 messenger 并构建 snackbar，避免跨 async 使用 context。
    final messenger = ScaffoldMessenger.of(context);
    final fallback = HuxSnackbar(
      message: '链接已复制',
      variant: HuxSnackbarVariant.success,
      duration: const Duration(milliseconds: 1400),
    ).build(context);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      Clipboard.setData(ClipboardData(text: href));
      HapticFeedback.selectionClick();
      messenger.showSnackBar(fallback);
    }
  }
}

/// 基于 SENTINEL 令牌的 Markdown 样式表（对齐原自研渲染器的视觉）。
MarkdownStyleSheet _styleSheet(BuildContext context) {
  final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
  return base.copyWith(
    p: AppText.body.copyWith(height: 1.6),
    h1: AppText.body.copyWith(
        fontSize: 19, fontWeight: FontWeight.w700, height: 1.35),
    h2: AppText.body.copyWith(
        fontSize: 17.5, fontWeight: FontWeight.w700, height: 1.35),
    h3: AppText.body.copyWith(
        fontSize: 16, fontWeight: FontWeight.w700, height: 1.35),
    h4: AppText.body.copyWith(
        fontSize: 15, fontWeight: FontWeight.w700, height: 1.35),
    h5: AppText.body.copyWith(
        fontSize: 15, fontWeight: FontWeight.w700, height: 1.35),
    h6: AppText.body.copyWith(
        fontSize: 15, fontWeight: FontWeight.w700, height: 1.35),
    em: AppText.body.copyWith(fontStyle: FontStyle.italic),
    strong: AppText.body.copyWith(fontWeight: FontWeight.w700),
    blockquote: AppText.callout.copyWith(
        color: AppColors.textSecondaryOf(context), fontStyle: FontStyle.italic),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: AppColors.placeholderOf(context), width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 10),
    listBullet: AppText.body.copyWith(color: AppColors.textSecondaryOf(context)),
    // 行内码：等宽 + 浅灰底（无圆角，受 TextStyle 限制）。
    code: AppText.mono.copyWith(fontSize: 12, backgroundColor: AppColors.keyCapOf(context)),
    a: TextStyle(
        color: AppColors.accentOf(context), decoration: TextDecoration.underline),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.hairlineOf(context))),
    ),
    blockSpacing: 8,
    listIndent: 22,
  );
}

/// 接管 `pre` 块：渲染为深色代码块 + 语法高亮 + 复制按钮。
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder();

  @override
  bool isBlockElement() => true;

  /// flutter_markdown 在遍历 `pre > code > Text` 时仍会为 `code` 压入 inline。
  /// 自定义 `pre` builder 若沿用默认的 visitText（返回 null），该 inline 没有
  /// child，内部无法 flush，构建结束便触发 `_inlines.isEmpty` 断言。
  /// 返回不可见占位只用于让包内部正确清栈；最终代码块仍完全由下方
  /// visitElementAfterWithContext 返回的 _CodeBlockView 接管，不会重复渲染。
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final raw =
        element.textContent.replaceAll(RegExp(r'^\n+|\n+\s*$'), '');
    var lang = '';
    for (final child in element.children ?? const <md.Element>[]) {
      if (child is md.Element && child.tag == 'code') {
        final cls = child.attributes['class'] ?? '';
        final m = RegExp(r'language-([\w+-]+)').firstMatch(cls);
        if (m != null) lang = m.group(1)!;
        break;
      }
    }
    final span = highlightCode(raw, lang, Theme.of(context).brightness);
    return _CodeBlockView(code: raw, lang: lang, span: span);
  }
}

/// 深色代码块视图：语言标签 + 复制按钮（保留）+ 横向可滚的高亮代码。
class _CodeBlockView extends StatelessWidget {
  final String code;
  final String lang;
  final TextSpan span;
  const _CodeBlockView(
      {required this.code, required this.lang, required this.span});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1F), // 深底（同原自研，明暗均固定深色）
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
                        style: AppText.monoCaption
                            .copyWith(color: const Color(0xFF8E8E93))),
                  ),
                )
              else
                const Spacer(),
              CopyButton(text: code, dark: true),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText.rich(
              span,
              style: AppText.mono.copyWith(
                  color: const Color(0xFFECECEF), height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
