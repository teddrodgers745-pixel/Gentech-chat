// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../app_state.dart';
import '../theme.dart';

/// Markdown ответа модели на всю ширину: тело — Literata (выбранный
/// шрифт текста) с межстрочным интервалом из настроек, код — JetBrains Mono
/// (выбранный шрифт кода). Цитаты — акцентная рамка слева, разделитель —
/// divider, таблицы — рамки border, изображения — радиус 14 и высота до 420.
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
          size: size * 0.88,
          color: p.text,
          height: 1.45,
        );
        return MarkdownBody(
          data: data,
          softLineBreak: true,
          styleSheet: MarkdownStyleSheet(
            p: body,
            pPadding: const EdgeInsets.symmetric(vertical: 3),
            h1: body.copyWith(
              fontSize: size * 1.45,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
            h2: body.copyWith(
              fontSize: size * 1.3,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
            h3: body.copyWith(
              fontSize: size * 1.15,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
            h4: body.copyWith(fontSize: size, fontWeight: FontWeight.w600),
            h5: body.copyWith(
              fontSize: size,
              fontWeight: FontWeight.w600,
              color: p.muted,
            ),
            h6: body.copyWith(
              fontSize: size,
              fontWeight: FontWeight.w600,
              color: p.muted,
            ),
            strong: body.copyWith(fontWeight: FontWeight.w700),
            em: body.copyWith(fontStyle: FontStyle.italic),
            a: body.copyWith(
              color: p.accent,
              decoration: TextDecoration.underline,
            ),
            code: mono.copyWith(color: p.accent, backgroundColor: p.codeBg),
            codeblockPadding: EdgeInsets.zero,
            codeblockDecoration: const BoxDecoration(),
            blockquote: body.copyWith(
              color: p.muted,
              fontStyle: FontStyle.italic,
            ),
            blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
            blockquoteDecoration: BoxDecoration(
              border: Border(left: BorderSide(color: p.accent, width: 3)),
            ),
            listBullet: body,
            listIndent: 24,
            tableHead: body.copyWith(fontWeight: FontWeight.w700),
            tableBody: body,
            tableBorder: TableBorder.all(color: p.border),
            tableCellsPadding: const EdgeInsets.all(8),
            horizontalRuleDecoration: BoxDecoration(
              border: Border(top: BorderSide(color: p.divider, width: 1)),
            ),
            blockSpacing: 10,
          ),
          builders: <String, MarkdownElementBuilder>{
            'code': _CodeBuilder(p: p, mono: mono),
          },
          imageBuilder: (Uri uri, String? title, String? alt) =>
              _MarkdownImage(uri: uri, alt: alt ?? ''),
        );
      },
    );
  }
}

/// Построитель блоков кода: обрабатывает только ограждённые блоки
/// (element с классом 'language-*'); инлайн-код остаётся со стандартным
/// рендером через стиль `code`.
class _CodeBuilder extends MarkdownElementBuilder {
  final Palette p;
  final TextStyle mono;

  _CodeBuilder({required this.p, required this.mono});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final cls = element.attributes['class'] ?? '';
    if (!cls.startsWith('language-')) return null;
    final raw = element.textContent;
    final code = raw.endsWith('\n') ? raw.substring(0, raw.length - 1) : raw;
    return _CodeBlock(
      code: code,
      lang: cls.substring('language-'.length),
      p: p,
      mono: mono,
    );
  }
}

String _normalizeLang(String raw) {
  final x = raw.toLowerCase().trim();
  const alias = <String, String>{
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
  const known = <String>{
    'python', 'dart', 'javascript', 'typescript', 'java', 'kotlin', 'bash',
    'json', 'yaml', 'xml', 'css', 'sql', 'cpp', 'c', 'go', 'rust',
    'markdown', 'swift', 'php', 'ruby', 'ini', 'diff', 'cs',
  };
  final y = alias[x] ?? x;
  return known.contains(y) ? y : 'plaintext';
}

/// Блок кода: тёмная карточка с подписью языка и кнопкой «Копировать».
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
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    lang.isEmpty ? 'код' : lang,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 12,
                      fontFamily: settings.codeFont,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Копировать',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.copy_rounded, size: 16, color: p.muted),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Код скопирован'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
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

/// Изображение внутри markdown: file://, data URL либо http(s).
/// Скругление 14, высота не более 420, фон codeBg, аккуратная заглушка.
class _MarkdownImage extends StatelessWidget {
  final Uri uri;
  final String alt;

  const _MarkdownImage({required this.uri, required this.alt});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 420),
              color: p.codeBg,
              alignment: Alignment.center,
              child: _image(p),
            ),
          ),
        );
      },
    );
  }

  Widget _image(Palette p) {
    if (uri.scheme == 'file') {
      return Image.file(
        File(uri.toFilePath()),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _placeholder(p),
      );
    }
    if (uri.scheme == 'data') {
      final raw = uri.toString();
      final idx = raw.indexOf(',');
      if (idx >= 0 && idx + 1 < raw.length) {
        try {
          return Image.memory(
            base64Decode(raw.substring(idx + 1)),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _placeholder(p),
          );
        } catch (_) {}
      }
      return _placeholder(p);
    }
    return Image.network(
      uri.toString(),
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => _placeholder(p),
    );
  }

  Widget _placeholder(Palette p) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        alt.isEmpty ? 'Не удалось загрузить изображение' : alt,
        textAlign: TextAlign.center,
        style: TextStyle(color: p.muted, fontSize: 13),
      ),
    );
  }
}
