// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../app_state.dart';
import '../models.dart';
import '../services/tts_service.dart';
import '../theme.dart';
import 'file_card.dart';
import 'tool_call_card.dart';

/// Одно сообщение: пользовательское или ответ модели.
class MessageView extends StatelessWidget {
  final ChatMessage message;
  final bool streaming;
  final VoidCallback? onRegenerate;

  const MessageView({
    super.key,
    required this.message,
    this.streaming = false,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, settings.fontSizeN]),
      builder: (context, _) {
        final p = settings.palette;
        final size = settings.fontSizeN.value;

        if (message.isToolCall) {
          return ToolCallCard(message: message);
        }

        if (message.role == 'user') {
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: p.userBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              message.content,
              style: fontStyle(
                settings.bodyFont,
                size: size,
                color: p.text,
                height: settings.lineHeight,
              ),
            ),
          );
        }

        final waiting =
            streaming && message.content.isEmpty && message.reasoning.isEmpty;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.reasoning.isNotEmpty)
                _Reasoning(
                  text: message.reasoning,
                  active: streaming && message.content.isEmpty,
                  p: p,
                  size: size,
                ),
              ..._contentWidgets(message.content),
              if (waiting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (!streaming && message.content.isNotEmpty)
                Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      color: p.muted,
                      tooltip: 'Копировать',
                      icon: const Icon(Icons.copy_rounded),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: message.content));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Скопировано'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                    _SpeakButton(message: message, p: p),
                    if (onRegenerate != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        color: p.muted,
                        tooltip: 'Повторить ответ',
                        icon: const Icon(Icons.refresh_rounded),
                        onPressed: onRegenerate,
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  /// Разбивает контент сообщения на обычный markdown и карточки файлов
  /// (блоки кода с именем файла: ```html name=index.html).
  List<Widget> _contentWidgets(String content) {
    if (content.trim().isEmpty) return const <Widget>[];
    final out = <Widget>[];
    for (final seg in splitFileBlocks(content)) {
      if (seg.isFile) {
        out.add(
          FileCard(fileName: seg.fileName, code: seg.code, lang: seg.lang),
        );
      } else if (seg.text.trim().isNotEmpty) {
        out.add(RichMarkdown(seg.text));
      }
    }
    return out.isEmpty ? <Widget>[RichMarkdown(content)] : out;
  }
}

/// Кнопка озвучки сообщения: запускает TTS, повторное нажатие — стоп.
class _SpeakButton extends StatelessWidget {
  final ChatMessage message;
  final Palette p;

  const _SpeakButton({required this.message, required this.p});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: ttsService.activeId,
      builder: (context, activeId, _) {
        final speaking = activeId == message.id;
        return IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          color: speaking ? p.accent : p.muted,
          tooltip: speaking ? 'Остановить озвучку' : 'Озвучить',
          icon: Icon(
            speaking
                ? Icons.volume_off_rounded
                : Icons.volume_up_rounded,
          ),
          onPressed: () =>
              ttsService.toggleSpeak(message.id, message.content),
        );
      },
    );
  }
}

class _Reasoning extends StatelessWidget {
  final String text;
  final bool active;
  final Palette p;
  final double size;

  const _Reasoning({
    required this.text,
    required this.active,
    required this.p,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        dense: true,
        iconColor: p.muted,
        collapsedIconColor: p.muted,
        expandedAlignment: Alignment.centerLeft,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(
          active ? 'Думает…' : 'Размышления',
          style: TextStyle(color: p.muted, fontSize: 13),
        ),
        children: [
          Text(
            text,
            style: fontStyle(
              settings.bodyFont,
              size: size * 0.9,
              color: p.muted,
              height: settings.lineHeight,
            ),
          ),
        ],
      ),
    );
  }
}

/// Markdown на всю ширину, с учётом выбранных шрифтов, темы и размера.
class RichMarkdown extends StatelessWidget {
  final String data;
  const RichMarkdown(this.data, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, settings.fontSizeN]),
      builder: (context, _) {
        final p = settings.palette;
        final size = settings.fontSizeN.value;
        final body = fontStyle(
          settings.bodyFont,
          size: size,
          color: p.text,
          height: settings.lineHeight,
        );
        final mono = fontStyle(
          settings.codeFont,
          size: size * 0.86,
          color: p.text,
          height: 1.45,
        );
        return MarkdownBody(
          data: data,
          fitContent: false,
          softLineBreak: true,
          styleSheet: _sheet(p, body, mono, size),
          builders: <String, MarkdownElementBuilder>{
            'code': _CodeBuilder(p, mono),
          },
        );
      },
    );
  }

  MarkdownStyleSheet _sheet(Palette p, TextStyle body, TextStyle mono, double size) {
    return MarkdownStyleSheet(
      p: body,
      pPadding: EdgeInsets.zero,
      h1: body.copyWith(fontSize: size * 1.5, fontWeight: FontWeight.w700, height: 1.3),
      h2: body.copyWith(fontSize: size * 1.3, fontWeight: FontWeight.w700, height: 1.3),
      h3: body.copyWith(fontSize: size * 1.15, fontWeight: FontWeight.w600, height: 1.3),
      h4: body.copyWith(fontWeight: FontWeight.w600),
      h5: body.copyWith(fontWeight: FontWeight.w600),
      h6: body.copyWith(fontWeight: FontWeight.w600),
      strong: body.copyWith(fontWeight: FontWeight.w700),
      em: body.copyWith(fontStyle: FontStyle.italic),
      a: body.copyWith(color: p.accent, decoration: TextDecoration.underline),
      code: mono.copyWith(backgroundColor: p.codeBg, color: p.accent),
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),
      blockquote: body.copyWith(color: p.muted),
      blockquotePadding: const EdgeInsets.only(left: 12),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.accent, width: 3)),
      ),
      listBullet: body,
      tableHead: body.copyWith(fontWeight: FontWeight.w700),
      tableBody: body,
      tableBorder: TableBorder.all(color: p.border),
      tableCellsPadding: const EdgeInsets.all(8),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.border)),
      ),
      blockSpacing: size * 0.7,
    );
  }
}

class _CodeBuilder extends MarkdownElementBuilder {
  final Palette p;
  final TextStyle mono;
  _CodeBuilder(this.p, this.mono);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final cls = element.attributes['class'];
    final text = element.textContent;
    final isBlock = cls != null || text.trimRight().contains('\n');
    if (!isBlock) return null; // обычный инлайн-код

    final lang =
        (cls != null && cls.startsWith('language-')) ? cls.substring(9) : '';
    final code = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
    return _CodeBlock(code: code, lang: lang, p: p, mono: mono);
  }
}

String _normalizeLang(String l) {
  final x = l.toLowerCase().trim();
  const alias = {
    'py': 'python',
    'js': 'javascript',
    'ts': 'typescript',
    'sh': 'bash',
    'shell': 'bash',
    'zsh': 'bash',
    'yml': 'yaml',
    'html': 'xml',
    'c++': 'cpp',
    'kt': 'kotlin',
    'rs': 'rust',
    'md': 'markdown',
  };
  const known = {
    'python', 'dart', 'javascript', 'typescript', 'java', 'kotlin', 'bash',
    'json', 'yaml', 'xml', 'css', 'sql', 'cpp', 'c', 'go', 'rust',
    'markdown', 'swift', 'php', 'ruby', 'ini', 'diff',
  };
  final y = alias[x] ?? x;
  return known.contains(y) ? y : 'plaintext';
}

class _CodeBlock extends StatelessWidget {
  final String code;
  final String lang;
  final Palette p;
  final TextStyle mono;

  const _CodeBlock({
    required this.code,
    required this.lang,
    required this.p,
    required this.mono,
  });

  @override
  Widget build(BuildContext context) {
    final base = p.isDark ? atomOneDarkTheme : githubTheme;
    final theme = Map<String, TextStyle>.from(base);
    theme['root'] = (base['root'] ?? const TextStyle())
        .copyWith(backgroundColor: Colors.transparent);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: p.codeBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(
              children: [
                Text(
                  lang.isEmpty ? 'код' : lang,
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Код скопирован'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  icon: Icon(Icons.copy_rounded, size: 14, color: p.muted),
                  label: Text(
                    'Копировать',
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: HighlightView(
              code,
              language: _normalizeLang(lang),
              theme: theme,
              textStyle: mono,
            ),
          ),
        ],
      ),
    );
  }
}
