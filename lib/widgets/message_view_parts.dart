// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../app_state.dart';
import '../core/generation/async_job_executor.dart';
import '../core/models/message_part.dart';
import '../theme.dart';

/// Изображение из части сообщения: локальный файл, https-ссылка либо
/// data URL. Стиль повторяет изображения в markdown-ответах:
/// та же рамка, радиус 14, фон codeBg и предел высоты 420.
class MessagePartImage extends StatelessWidget {
  final ImagePart part;
  final Palette p;

  const MessagePartImage({super.key, required this.part, required this.p});

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

/// Видео из части сообщения: карточка с воспроизведением (video_player).
/// Локальный файл либо https-ссылка; при неудаче инициализации —
/// статичная карточка с иконкой.
class MessagePartVideo extends StatefulWidget {
  final VideoPart part;
  final Palette p;

  const MessagePartVideo({super.key, required this.part, required this.p});

  @override
  State<MessagePartVideo> createState() => _MessagePartVideoState();
}

class _MessagePartVideoState extends State<MessagePartVideo> {
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
/// видео) и кнопка отмены по jobId. При наличии диагностики задачи
/// (debugSnippets либо debugLogPath) под прогрессом показывается
/// сворачиваемый блок отладки.
class MessagePartPending extends StatelessWidget {
  final PendingPart part;
  final Palette p;

  const MessagePartPending({super.key, required this.part, required this.p});

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

  /// Сворачиваемый блок отладки: сниппеты моноширинным шрифтом,
  /// путь debug-файла и кнопка копирования всего сразу.
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
