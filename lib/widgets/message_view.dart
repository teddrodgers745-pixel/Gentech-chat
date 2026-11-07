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
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../core/generation/async_job_executor.dart';
import '../core/utils/currency_format.dart';
import '../core/utils/reasoning_mapper.dart';
import '../core/models/gen_error_mapper.dart';
import '../core/models/message_part.dart';
import '../features/chat/widgets/error_bubble.dart';
import '../features/gallery/artifacts_gallery_screen.dart';
import '../models.dart';
import '../services/tts_service.dart';
import '../theme.dart';
import 'file_card.dart';
import 'thinking_indicator.dart';
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
    return RepaintBoundary(
      child: ListenableBuilder(
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
          return Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 680),
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
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
            ),
          );
        }

        // Плашка «Думает...»: стриминг идёт, текст ответа ещё пуст, а
        // уровень размышлений не выключен — reasoning-модели думают
        // 10-20 секунд до первого токена, показываем счётчик секунд.
        final thinking = streaming &&
            message.content.isEmpty &&
            ReasoningMapper.fromId(settings.reasoningLevel) !=
                ReasoningLevel.off;

        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
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
              ..._costWidgets(p),
              ..._sourcesWidgets(p),
              if (thinking) ThinkingIndicator(p: p),
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
          ),
        );
        },
      ),
    );
  }

  /// Разбивает контент сообщения на обычный markdown и карточки файлов
  /// (блоки кода с именем файла: ```html name=index.html).
  List<Widget> _contentWidgets(String content) {
    if (content.trim().isEmpty) return const <Widget>[];
    final out = <Widget>[];
    for (final seg in splitFileBlocks(content, streaming: streaming)) {
      if (seg.isFile) {
        out.add(
          FileCard(
            fileName: seg.fileName,
            code: seg.code,
            lang: seg.lang,
            forming: seg.forming,
          ),
        );
      } else if (seg.text.trim().isNotEmpty) {
        out.add(RichMarkdown(seg.text));
      }
    }
    return out.isEmpty ? <Widget>[RichMarkdown(content)] : out;
  }

  /// Строка стоимости под ответом: мелкая серая подпись вида
  /// '≈ 0,42 ₽ · 1240 ток.' — только если в частях сообщения есть
  /// TextPart с MessageCost (приходит из usage провайдера) и генерация
  /// уже завершена.
  List<Widget> _costWidgets(Palette p) {
    if (streaming) return const <Widget>[];
    // Экономика: стоимость показывается только если включено в настройках;
    // базовая сумма (в рублях) конвертируется в выбранную валюту.
    if (!settings.showCost) return const <Widget>[];
    for (final part in message.parts) {
      if (part is TextPart && part.cost != null) {
        final c = part.cost!;
        return <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '≈ ${CurrencyFormat.format(c.cost, settings.currency)} '
              '· ${c.totalTokens} ток.',
              style: TextStyle(fontSize: 12, color: p.muted),
            ),
          ),
        ];
      }
    }
    return const <Widget>[];
  }

  /// Блок «Источники» под текстом ответа: ссылки из TextPart.sources
  /// (citations/annotations провайдера) чипами с хостом ссылки;
  /// тап открывает ссылку во внешнем браузере. Во время стриминга
  /// блок не показывается — источники приходят в конце генерации.
  List<Widget> _sourcesWidgets(Palette p) {
    if (streaming) return const <Widget>[];
    final sources = <String>[];
    for (final part in message.parts) {
      if (part is TextPart) {
        for (final s in part.sources) {
          final t = s.trim();
          if (t.isNotEmpty && !sources.contains(t)) sources.add(t);
        }
      }
    }
    if (sources.isEmpty) return const <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Источники:',
              style: TextStyle(fontSize: 12, color: p.muted),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final url in sources)
                  ActionChip(
                    avatar: Icon(Icons.public, size: 16, color: p.accent),
                    label: Text(
                      Uri.tryParse(url)?.host ?? url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.text),
                    ),
                    onPressed: () => _openSourceUrl(url),
                  ),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  /// Открывает ссылку-источник во внешнем браузере. Ошибки (нет браузера,
  /// битая ссылка) молча игнорируются — чат не должен падать.
  static Future<void> _openSourceUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Части сообщения: изображение, видео (с воспроизведением),
  /// ожидающая асинхронная задача (прогресс + отмена) и ошибка.
  /// Текстовая часть не рендерится отдельно: текст уже входит в контент.
  List<Widget> _partsWidgets(Palette p) {
    final list = parts.isEmpty ? message.parts : parts;
    if (list.isEmpty) return const <Widget>[];
    final out = <Widget>[];
    for (final part in list) {
      switch (part) {
        case ImagePart():
          out.add(_PartImage(part: part, p: p));
        case VideoPart():
          out.add(_PartVideo(part: part, p: p));
        case PendingPart():
          out.add(_PartPending(part: part, p: p));
        case ErrorPart():
          out.add(ErrorBubble(error: part.error, onRetry: onRegenerate));
        case TextPart():
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
          size: 13,
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
      code: mono.copyWith(
        backgroundColor: p.codeBg.withValues(alpha: 0.55),
        color: p.accent,
      ),
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
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(p),
          );
        } else {
          image = Image.network(
            uri.toString(),
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(p),
          );
        }
        final src = uri.toString();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                GestureDetector(
                  onTap: () => _openFullscreenImage(context, src),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 420),
                    color: p.codeBg,
                    child: image,
                  ),
                ),
                _ImageActions(source: src, p: p),
              ],
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
    final src = part.isLocal ? (part.localPath ?? '') : (part.remoteUrl ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            GestureDetector(
              onTap: () => _openFullscreenImage(context, src),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 420),
                color: p.codeBg,
                child: _image(),
              ),
            ),
            _ImageActions(source: src, p: p),
          ],
        ),
      ),
    );
  }

  Widget _image() {
    if (part.isLocal) {
      return Image.file(
        File(part.localPath ?? ''),
        width: double.infinity,
        fit: BoxFit.cover,
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
            width: double.infinity,
            fit: BoxFit.cover,
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
      width: double.infinity,
      fit: BoxFit.cover,
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

/// Оверлей-кнопки изображения в чате: «Скачать» (share_plus: системный
/// диалог позволяет сохранить файл в «Загрузки») и «В галерею».
class _ImageActions extends StatelessWidget {
  final String source;
  final Palette p;

  const _ImageActions({required this.source, required this.p});

  void _openGallery(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ArtifactsGalleryScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 6,
      right: 6,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (source.trim().isNotEmpty)
            _circleButton(
              tooltip: 'Скачать',
              icon: Icons.download,
              onTap: () => _saveChatImage(context, source),
            ),
          const SizedBox(width: 6),
          _circleButton(
            tooltip: 'В галерею',
            icon: Icons.photo_library,
            onTap: () => _openGallery(context),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(
        side: BorderSide(color: Colors.white24, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Открывает полноэкранный просмотр изображения с масштабированием.
void _openFullscreenImage(BuildContext context, String source) {
  final s = source.trim();
  if (s.isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              tooltip: 'Скачать',
              icon: const Icon(Icons.download),
              onPressed: () => _saveChatImage(ctx, s),
            ),
          ],
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5.0,
            child: _buildFullscreenImageWidget(s),
          ),
        ),
      ),
    ),
  );
}

Widget _buildFullscreenImageWidget(String s) {
  if (s.startsWith('data:image')) {
    final comma = s.indexOf(',');
    if (comma >= 0 && comma + 1 < s.length) {
      try {
        return Image.memory(
          base64Decode(s.substring(comma + 1)),
          fit: BoxFit.contain,
        );
      } catch (_) {}
    }
  }
  if (s.startsWith('http://') || s.startsWith('https://')) {
    return Image.network(s, fit: BoxFit.contain);
  }
  final path = s.startsWith('file://')
      ? Uri.parse(s).toFilePath()
      : s.replaceFirst(RegExp(r'^file://'), '');
  return Image.file(File(path), fit: BoxFit.contain);
}

/// Физически сохраняет изображение в папку Downloads (или через FilePicker).
Future<void> _saveChatImage(BuildContext context, String source) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void snack(String text) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  try {
    final s = source.trim();
    final Uint8List bytes;
    if (s.startsWith('data:')) {
      final idx = s.indexOf(',');
      if (idx < 0) throw const FormatException('bad data url');
      bytes = base64Decode(s.substring(idx + 1));
    } else if (s.startsWith('http://') || s.startsWith('https://')) {
      final resp = await http
          .get(Uri.parse(s))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      bytes = resp.bodyBytes;
    } else {
      final path = s.startsWith('file://')
          ? Uri.parse(s).toFilePath()
          : s.replaceFirst(RegExp(r'^file://'), '');
      bytes = await File(path).readAsBytes();
    }
    if (bytes.isEmpty) throw Exception('Пустой файл');

    final fileName =
        'img_${DateTime.now().millisecondsSinceEpoch}${_imageExtFor(s)}';

    var saved = false;
    if (Platform.isAndroid) {
      try {
        final dlDir = Directory('/storage/emulated/0/Download');
        if (await dlDir.exists()) {
          final outFile = File('${dlDir.path}/$fileName');
          await outFile.writeAsBytes(bytes, flush: true);
          saved = true;
          snack('Сохранено в Загрузки: $fileName');
        }
      } catch (_) {
        saved = false;
      }
    }

    if (!saved) {
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Сохранить изображение',
        fileName: fileName,
        type: FileType.image,
        bytes: bytes,
      );
      if (savedPath != null && savedPath.isNotEmpty) {
        final f = File(savedPath);
        if (!await f.exists() || await f.length() == 0) {
          await f.writeAsBytes(bytes, flush: true);
        }
        saved = true;
        snack('Сохранено в Загрузки');
      }
    }

    if (!saved) {
      final dir = (await getDownloadsDirectory()) ??
          await getApplicationDocumentsDirectory();
      final outFile = File('${dir.path}/$fileName');
      await outFile.writeAsBytes(bytes, flush: true);
      snack('Сохранено: ${outFile.path}');
    }
  } catch (_) {
    snack('Не удалось сохранить изображение');
  }
}

/// Расширение файла по источнику (data URL, путь либо ссылка).
String _imageExtFor(String source) {
  final clean = source.split('?').first.toLowerCase();
  for (final e in const ['.png', '.jpg', '.jpeg', '.webp', '.gif']) {
    if (clean.endsWith(e)) return e == '.jpeg' ? '.jpg' : e;
  }
  if (source.startsWith('data:image/')) {
    final mime = source
        .substring('data:image/'.length)
        .split(';')
        .first;
    if (mime.contains('jpeg')) return '.jpg';
    if (mime.contains('webp')) return '.webp';
    if (mime.contains('gif')) return '.gif';
  }
  return '.png';
}

/// Видео из части сообщения: карточка с воспроизведением (video_player).
/// Локальный файл либо https-ссылка; при неудаче инициализации —
/// статичная карточка с иконкой, как раньше.
class _PartVideo extends StatefulWidget {
  final VideoPart part;
  final Palette p;

  const _PartVideo({required this.part, required this.p});

  @override
  State<_PartVideo> createState() => _PartVideoState();
}

class _PartVideoState extends State<_PartVideo> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    c?.removeListener(_onTick);
    c?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    VideoPlayerController? c;
    final part = widget.part;
    if (part.isLocal) {
      final path = (part.localPath ?? '').trim();
      if (path.isEmpty) {
        _fail();
        return;
      }
      c = VideoPlayerController.file(File(path));
    } else {
      final url = (part.remoteUrl ?? '').trim();
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        _fail();
        return;
      }
      c = VideoPlayerController.networkUrl(Uri.parse(url));
    }
    try {
      await c.initialize();
    } catch (_) {
      try {
        await c.dispose();
      } catch (_) {}
      _fail();
      return;
    }
    if (!mounted) {
      try {
        await c.dispose();
      } catch (_) {}
      return;
    }
    c.addListener(_onTick);
    setState(() => _controller = c);
  }

  void _fail() {
    if (mounted) setState(() => _failed = true);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  String get _name {
    final part = widget.part;
    final src = part.isLocal ? (part.localPath ?? '') : (part.remoteUrl ?? '');
    final clean = src.replaceFirst(RegExp(r'^file://'), '');
    final idx = clean.lastIndexOf('/');
    if (idx >= 0 && idx < clean.length - 1) return clean.substring(idx + 1);
    return clean.isEmpty ? 'видео' : clean;
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_failed || c == null || !c.value.isInitialized) return _staticCard();
    final ar = c.value.aspectRatio;
    final ratio = (ar.isFinite && ar > 0) ? ar : 16 / 9;
    final p = widget.p;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: _togglePlay,
            child: AspectRatio(
              aspectRatio: ratio,
              child: VideoPlayer(c),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                Icon(Icons.movie_outlined, size: 18, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: fontStyle(
                      settings.codeFont,
                      size: 13,
                      weight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: c.value.isPlaying ? 'Пауза' : 'Воспроизвести',
                  visualDensity: VisualDensity.compact,
                  iconSize: 24,
                  icon: Icon(
                    c.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: p.accent,
                  ),
                  onPressed: _togglePlay,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _staticCard() {
    final p = widget.p;
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

/// Ожидающая часть: круговой прогресс асинхронной задачи (генерация
/// видео) и кнопка отмены по jobId. Стиль карточки — как у VideoPart.
/// При наличии диагностики задачи (debugSnippets либо debugLogPath)
/// под прогрессом показывается сворачиваемый блок отладки: последние
/// события моноширинным шрифтом, путь JSONL-лога и кнопка копирования.
class _PartPending extends StatelessWidget {
  final PendingPart part;
  final Palette p;

  const _PartPending({required this.part, required this.p});

  /// Есть ли отладочные данные для показа.
  bool get _hasDebug =>
      (part.debugSnippets != null && part.debugSnippets!.isNotEmpty) ||
      part.debugLogPath != null;

  /// Сниппет для показа: обрезается до 500 символов.
  static String _clipSnippet(String s) {
    final t = s.trim();
    return t.length > 500 ? '${t.substring(0, 500)}…' : t;
  }

  @override
  Widget build(BuildContext context) {
    final pct = part.progress.clamp(0.0, 100.0);
    final p = this.p;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 42,
                height: 42,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: CircularProgressIndicator(
                        value: pct <= 0 ? null : pct / 100,
                        strokeWidth: 3,
                        color: p.accent,
                      ),
                    ),
                    Icon(Icons.movie_outlined, size: 18, color: p.accent),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      part.name.trim().isEmpty ? 'Генерация видео' : part.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${pct.toStringAsFixed(0)}%',
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                  ],
                ),
              ),
              if (part.jobId.trim().isNotEmpty)
                IconButton(
                  tooltip: 'Отменить',
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                  icon: Icon(Icons.close_rounded, size: 20, color: p.muted),
                  onPressed: () => AsyncJobExecutor.cancelJob(part.jobId),
                ),
            ],
          ),
          if (_hasDebug) _debugTile(context, p),
        ],
      ),
    );
  }

  /// Сворачиваемый блок отладки: сниппеты моноширинным шрифтом
  /// (до 500 символов каждый), путь debug-файла и кнопка копирования
  /// всего сразу в буфер обмена одним тапом.
  Widget _debugTile(BuildContext context, Palette p) {
    final snippets = part.debugSnippets ?? const <String>[];
    final path = part.debugLogPath ?? '';
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
        initiallyExpanded: false,
        iconColor: p.muted,
        collapsedIconColor: p.muted,
        expandedAlignment: Alignment.centerLeft,
        title: Text(
          'Показать отладочную информацию',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 13),
        ),
        trailing: IconButton(
          tooltip: 'Копировать отладку',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: Icon(Icons.copy_rounded, size: 18, color: p.muted),
          onPressed: () {
            Clipboard.setData(
              ClipboardData(text: '${snippets.join('\n')}\n$path'),
            );
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Отладка скопирована'),
                duration: Duration(seconds: 1),
              ),
            );
          },
        ),
        children: [
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in snippets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      _clipSnippet(s),
                      style: TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontFamilyFallback: const ['monospace'],
                        fontSize: 11,
                        height: 1.45,
                        color: p.text,
                      ),
                    ),
                  ),
                if (path.isNotEmpty)
                  Text(
                    'Файл: $path',
                    style: TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontFamilyFallback: const ['monospace'],
                      fontSize: 10.5,
                      color: p.muted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
