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
import '../core/models/gen_error_mapper.dart';
import '../core/models/message_part.dart';
import '../features/chat/widgets/error_bubble.dart';
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

  /// Части сообщения (ImagePart/VideoPart) для прямого отображения.
  /// По умолчанию пусто: обычные сообщения рендерятся как раньше.
  final List<MessagePart> parts;

  const MessageView({
    super.key,
    required this.message,
    this.streaming = false,
    this.onRegenerate,
    this.parts = const <MessagePart>[],
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

        // Сообщение-ошибка генерации: рендерится через ErrorBubble.
        if (message.role != 'user' && message.errorCode.trim().isNotEmpty) {
          final err = GenErrorMapper.fromCode(
            message.errorCode.trim(),
            details: message.errorText,
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: ErrorBubble(error: err, onRetry: onRegenerate),
          );
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
              ..._partsWidgets(p),
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

  /// Части сообщения: изображение (локальный файл либо ссылка) и видео.
  /// Текстовые и ожидающие части здесь не рендерятся: текст уже входит
  /// в основной контент, ожидающие части живут в панели ввода.
  List<Widget> _partsWidgets(Palette p) {
    if (parts.isEmpty) return const <Widget>[];
    final out = <Widget>[];
    for (final part in parts) {
      switch (part) {
        case ImagePart():
          out.add(_PartImage(part: part, p: p));
        case VideoPart():
          out.add(_PartVideo(part: part, p: p));
        case ErrorPart():
          out.add(ErrorBubble(error: part.error, onRetry: onRegenerate));
        case TextPart():
        case PendingPart():
          break;
      }
    }
    return out;
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
          imageBuilder: (Uri uri, String? title, String? alt) {
            return _MarkdownImage(uri: uri, alt: alt ?? '');
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

/// Изображение внутри markdown-ответа: локальный файл (file://, как
/// сохраняет ImagesApiExecutor) либо сетевая ссылка. Ошибка загрузки
/// показывается аккуратной заглушкой, сообщение не ломается.
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
        final Widget image;
        if (uri.scheme == 'file') {
          image = Image.file(
            File(uri.toFilePath()),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _placeholder(p),
          );
        } else {
          image = Image.network(
            uri.toString(),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _placeholder(p),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 420),
              alignment: Alignment.center,
              color: p.codeBg,
              child: image,
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder(Palette p) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        'Не удалось загрузить изображение',
        textAlign: TextAlign.center,
        style: TextStyle(color: p.muted, fontSize: 13),
      ),
    );
  }
}

/// Изображение из части сообщения: локальный файл, https-ссылка либо
/// data URL. Стиль повторяет изображения в markdown-ответах:
/// та же рамка, радиус 14, фон codeBg и предел высоты 420.
class _PartImage extends StatelessWidget {
  final ImagePart part;
  final Palette p;

  const _PartImage({required this.part, required this.p});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 420),
          alignment: Alignment.center,
          color: p.codeBg,
          child: _image(),
        ),
      ),
    );
  }

  Widget _image() {
    if (part.isLocal) {
      return Image.file(
        File(part.localPath ?? ''),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _fallback,
      );
    }
    final url = (part.remoteUrl ?? '').trim();
    if (url.startsWith('data:image')) {
      final comma = url.indexOf(',');
      if (comma >= 0 && comma + 1 < url.length) {
        try {
          final bytes = base64Decode(url.substring(comma + 1));
          return Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _fallback,
          );
        } catch (_) {
          return _fallback;
        }
      }
      return _fallback;
    }
    if (url.isEmpty) return _fallback;
    return Image.network(
      url,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => _fallback,
    );
  }

  Widget get _fallback => Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'Не удалось загрузить изображение',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.muted, fontSize: 13),
        ),
      );
}

/// Видео из части сообщения: карточка в стиле FileCard с иконкой,
/// именем файла и пометкой «Видео».
class _PartVideo extends StatelessWidget {
  final VideoPart part;
  final Palette p;

  const _PartVideo({required this.part, required this.p});

  String get _name {
    final src = part.isLocal ? (part.localPath ?? '') : (part.remoteUrl ?? '');
    final clean = src.replaceFirst(RegExp(r'^file://'), '');
    final idx = clean.lastIndexOf('/');
    if (idx >= 0 && idx < clean.length - 1) return clean.substring(idx + 1);
    return clean.isEmpty ? 'видео' : clean;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.movie_outlined, size: 22, color: p.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: fontStyle(
                    settings.codeFont,
                    size: 14,
                    weight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Видео',
                  style: TextStyle(fontSize: 12, color: p.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
