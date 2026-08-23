import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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
    // 跨行/跨段落连续选中：用 SelectionArea 独占整段选区，MarkdownBody 必须
    // selectable:false（只渲染 RichText，交 SelectionArea 统一选区）。实测证明
    // selectable:true 反而会让每个 block 各自成 SelectableText，跨块选区聚合不上、
    // 只能选一小段；selectable:false 时 SelectionArea 把整段视为同一选区，
    // 可跨段落、跨代码块连续拖选（探针验证）。
    // softLineBreak:false → 单行 \n 视为硬换行，复制时保留换行；若设 true，
    // 换行会被塌成空格，复制出的文本丢失换行（用户实测反馈）。
    return SelectionArea(
      child: MarkdownBody(
        data: data,
        selectable: false,
        softLineBreak: false,
        styleSheet: _styleSheet(context),
        onTapLink: (text, href, title) {
          _openLink(context, href);
        },
        builders: <String, MarkdownElementBuilder>{
          'pre': _CodeBlockBuilder(),
          'p': _TextBlockBuilder(styleOf: (ss) => ss.p, onLink: (href) => _openLink(context, href)),
          'h1': _TextBlockBuilder(styleOf: (ss) => ss.h1, onLink: (href) => _openLink(context, href)),
          'h2': _TextBlockBuilder(styleOf: (ss) => ss.h2, onLink: (href) => _openLink(context, href)),
          'h3': _TextBlockBuilder(styleOf: (ss) => ss.h3, onLink: (href) => _openLink(context, href)),
          'h4': _TextBlockBuilder(styleOf: (ss) => ss.h4, onLink: (href) => _openLink(context, href)),
          'h5': _TextBlockBuilder(styleOf: (ss) => ss.h5, onLink: (href) => _openLink(context, href)),
          'h6': _TextBlockBuilder(styleOf: (ss) => ss.h6, onLink: (href) => _openLink(context, href)),
          'blockquote': _TextBlockBuilder(
              styleOf: (ss) => ss.blockquote, blockquote: true, onLink: (href) => _openLink(context, href)),
          'ul': _ListBuilder(false, (href) => _openLink(context, href)),
          'ol': _ListBuilder(true, (href) => _openLink(context, href)),
        },
      ),
    );
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    if (href == null) return;
    final uri = Uri.tryParse(href);
    if (uri == null) {
      copyToClipboard(context, href); // 同步路径：uri 非法直接复制
      return;
    }
    // 失败回退：await 前捕获 root overlay，避免跨 async 使用 context。
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      Clipboard.setData(ClipboardData(text: href));
      HapticFeedback.selectionClick();
      if (overlay != null) {
        showAppToastOn(overlay,
            message: '链接已复制', variant: AppToastVariant.success);
      }
    }
  }
}

/// 基于 SENTINEL 令牌的 Markdown 样式表（对齐原自研渲染器的视觉）。
MarkdownStyleSheet _styleSheet(BuildContext context) {
  final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
  return base.copyWith(
    p: AppText.body,
    h1: AppText.markdownH1,
    h2: AppText.markdownH2,
    h3: AppText.markdownH3,
    h4: AppText.markdownH4,
    h5: AppText.markdownH5,
    h6: AppText.markdownH6,
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
    code: AppText.mono.copyWith(backgroundColor: AppColors.keyCapOf(context)),
    a: AppText.link.copyWith(color: AppColors.accentOf(context)),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.hairlineOf(context))),
    ),
    blockSpacing: 8,
    listIndent: 22,
  );
}

/// 块间换行占位：极小字号，作为独立 Text 部件置于每个块之后。
/// 它不是块自身 span 的一部分，故不污染块文本（不影响 find.text 精确匹配），
/// 但会被 SelectionArea 选中，复制时补足块边界换行；视觉上只增加约 1px 间距。
const Widget _blockBreakWidget = Text('\n', style: TextStyle(fontSize: 1, height: 1));

/// 把 markdown AST 内联节点递归转成 TextSpan，保留 strong/em/code/a/del 样式。
/// 链接 `a` 挂 TapGestureRecognizer 以保留点击跳转（由 onLink 回调处理）。
TextSpan _inlineSpan(
  md.Node node,
  TextStyle base,
  MarkdownStyleSheet ss,
  void Function(String?)? onLink,
) {
  if (node is md.Text) return TextSpan(text: node.text, style: base);
  if (node is! md.Element) return const TextSpan(text: '');
  TextStyle s = base;
  switch (node.tag) {
    case 'strong':
      s = base.copyWith(fontWeight: FontWeight.w700);
    case 'em':
      s = base.copyWith(fontStyle: FontStyle.italic);
    case 'del':
      s = base.copyWith(decoration: TextDecoration.lineThrough);
    case 'code':
      s = ss.code ?? base;
    case 'a':
      s = ss.a ?? base;
    default:
      break;
  }
  if (node.tag == 'a') {
    final href = node.attributes['href'];
    final rec = TapGestureRecognizer()..onTap = () => onLink?.call(href);
    return TextSpan(
      style: s,
      recognizer: rec,
      children: node.children
          ?.map((c) => _inlineSpan(c, s, ss, onLink))
          .toList(),
    );
  }
  return TextSpan(
    style: s,
    children:
        node.children?.map((c) => _inlineSpan(c, s, ss, onLink)).toList(),
  );
}

/// 承载一个块级文本 span 的可选文本部件：负责收集并释放链接 recognizer。
class _MarkdownBlock extends StatefulWidget {
  final TextSpan span;
  const _MarkdownBlock({required this.span});
  @override
  State<_MarkdownBlock> createState() => _MarkdownBlockState();
}

class _MarkdownBlockState extends State<_MarkdownBlock> {
  final List<TapGestureRecognizer> _recogs = [];

  void _collect() {
    for (final r in _recogs) {
      r.dispose();
    }
    _recogs.clear();
    void visit(InlineSpan s) {
      if (s is TextSpan && s.recognizer is TapGestureRecognizer) {
        _recogs.add(s.recognizer as TapGestureRecognizer);
      }
      if (s is TextSpan && s.children != null) {
        for (final c in s.children!) {
          visit(c);
        }
      }
    }

    visit(widget.span);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _collect();
  }

  @override
  void didUpdateWidget(covariant _MarkdownBlock old) {
    super.didUpdateWidget(old);
    _collect();
  }

  @override
  void dispose() {
    for (final r in _recogs) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(widget.span, textDirection: TextDirection.ltr);
  }
}

/// 段落 / 标题 / 引用：复用 styleSheet 的同标签样式重建内联 span，
/// 块后接独立 _blockBreakWidget 使选区拼接时保留块间换行（不污染块文本）。
class _TextBlockBuilder extends MarkdownElementBuilder {
  final TextStyle? Function(MarkdownStyleSheet) styleOf;
  final bool blockquote;
  final void Function(String?)? onLink;
  _TextBlockBuilder(
      {required this.styleOf, this.blockquote = false, this.onLink});

  @override
  bool isBlockElement() => true;

  // 返回占位，避免 flutter_markdown 内部 _inlines 栈未 flush 触发断言；
  // 真实内容由 visitElementAfterWithContext 重建并替换。
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
    final ss = _styleSheet(context);
    final base = styleOf(ss) ?? AppText.body;
    final inline = element.children
            ?.map((c) => _inlineSpan(c, base, ss, onLink))
            .toList() ??
        const <TextSpan>[];
    final block = _MarkdownBlock(span: TextSpan(children: inline));
    final col = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [block, _blockBreakWidget],
    );
    if (blockquote) {
      return Container(
        decoration: ss.blockquoteDecoration,
        padding: ss.blockquotePadding,
        child: col,
      );
    }
    return col;
  }
}

/// 有序/无序列表：整体递归渲染，直接遍历 ol/ul 的 children 生成标记与嵌套缩进，
/// 末尾追加 _blockBreak 保留列表项边界换行。不在 li 上挂 builder（避免与递归重复）。
class _ListBuilder extends MarkdownElementBuilder {
  final bool ordered;
  final void Function(String?)? onLink;
  _ListBuilder(this.ordered, this.onLink);

  @override
  bool isBlockElement() => true;

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
    final ss = _styleSheet(context);
    final base = ss.p ?? AppText.body;
    return _renderList(element, ordered, ss, base, onLink, 0);
  }
}

Widget _renderList(
  md.Element list,
  bool ordered,
  MarkdownStyleSheet ss,
  TextStyle base,
  void Function(String?)? onLink,
  int depth,
) {
  var idx = 0;
  final items = <Widget>[];
  for (final child in list.children ?? const <md.Element>[]) {
    if (child is! md.Element || child.tag != 'li') continue;
    idx++;
    final marker = ordered ? '$idx. ' : '• ';
    final spans = <InlineSpan>[];
    Widget? nested;
    for (final c in child.children ?? const <md.Node>[]) {
      if (c is md.Element && (c.tag == 'ul' || c.tag == 'ol')) {
        nested = _renderList(c, c.tag == 'ol', ss, base, onLink, depth + 1);
      } else {
        spans.add(_inlineSpan(c, base, ss, onLink));
      }
    }
    final itemSpan = TextSpan(children: [
      TextSpan(text: marker, style: ss.listBullet ?? base),
      ...spans,
    ]);
    items.add(Padding(
      padding: EdgeInsets.only(left: (ss.listIndent ?? 0) * (depth + 1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MarkdownBlock(span: itemSpan),
          _blockBreakWidget,
          nested ?? const SizedBox.shrink(),
        ],
      ),
    ));
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: items,
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
              CopyButton(text: code, dark: true, translucent: true),
            ],
          ),
          // 代码文本用 Text.rich 渲染（与 flutter_markdown 默认 selectable:false
          // 的渲染一致）：Text.rich 内部的 RenderParagraph 会向 SelectionArea 注册，
          // 因此拖动选区能"流过"代码块并把高亮文本一并复制。注意不能用
          // SelectableText.rich（会各自成 SelectableRegion 抢占选区、打断跨块），
          // 也不要用裸 RichText（实测不被 SelectionArea 纳入选区）。
          // 代码块后接独立 _blockBreakWidget，使代码块与后续块的边界换行进入选区复制。
          // 需要原样精确代码时仍用右上角复制按钮（不换行、不丢缩进）。
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text.rich(span, textDirection: TextDirection.ltr),
          ),
          _blockBreakWidget,
        ],
      ),
    );
  }
}
