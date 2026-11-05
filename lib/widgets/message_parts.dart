// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app_state.dart';
import '../core/models/message_part.dart';
import '../theme.dart';

/// Изображение из части сообщения: локальный файл, data URL либо ссылка.
/// Стиль повторяет изображения в markdown: радиус 14, maxHeight 420, codeBg.
class PartImage extends StatelessWidget {
  final ImagePart part;

  const PartImage({super.key, required this.part});

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
    final path = (part.localPath ?? '').trim();
    if (path.isNotEmpty) {
      return Image.file(
        File(path),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _fallback(p),
      );
    }
    final url = (part.remoteUrl ?? '').trim();
    if (url.startsWith('data:')) {
      final idx = url.indexOf(',');
      if (idx >= 0 && idx + 1 < url.length) {
        try {
          return Image.memory(
            base64Decode(url.substring(idx + 1)),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _fallback(p),
          );
        } catch (_) {
          return _fallback(p);
        }
      }
      return _fallback(p);
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Image.network(
        url,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _fallback(p),
      );
    }
    return _fallback(p);
  }

  Widget _fallback(Palette p) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'Не удалось загрузить изображение',
        textAlign: TextAlign.center,
        style: TextStyle(color: p.muted, fontSize: 13),
      ),
    );
  }
}

/// Видео из части сообщения: локальный файл либо https-ссылка,
/// воспроизведение по нажатию; при ошибке — аккуратная карточка-заглушка.
class PartVideo extends StatefulWidget {
  final VideoPart part;

  const PartVideo({super.key, required this.part});

  @override
  State<PartVideo> createState() => _PartVideoState();
}

class _PartVideoState extends State<PartVideo> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant PartVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.part.localPath != widget.part.localPath ||
        oldWidget.part.remoteUrl != widget.part.remoteUrl) {
      _disposeController();
      _failed = false;
      _init();
    }
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    c.removeListener(_onTick);
    c.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    final part = widget.part;
    final path = (part.localPath ?? '').trim();
    VideoPlayerController? c;
    if (path.isNotEmpty) {
      c = VideoPlayerController.file(File(path));
    } else {
      final url = (part.remoteUrl ?? '').trim();
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        if (mounted) setState(() => _failed = true);
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
      if (mounted) setState(() => _failed = true);
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

  void _toggle() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() {});
  }

  String _label() {
    final local = (widget.part.localPath ?? '').trim();
    final remote = (widget.part.remoteUrl ?? '').trim();
    final src = local.isNotEmpty ? local : remote;
    final clean = src.replaceFirst(RegExp(r'^file://'), '');
    final idx = clean.lastIndexOf('/');
    if (idx >= 0 && idx < clean.length - 1) return clean.substring(idx + 1);
    return clean.isEmpty ? 'видео' : clean;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final c = _controller;
        if (_failed || c == null || !c.value.isInitialized) {
          return _placeholder(p);
        }
        final ar = c.value.aspectRatio;
        final ratio = (ar.isFinite && ar > 0) ? ar : 16 / 9;
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                onTap: _toggle,
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: VideoPlayer(c),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                child: Row(
                  children: [
                    Icon(Icons.movie_outlined, size: 18, color: p.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _label(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: fontStyle(
                          settings.codeFont,
                          size: 12,
                          color: p.muted,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: c.value.isPlaying ? 'Пауза' : 'Воспроизвести',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        c.value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 22,
                        color: p.accent,
                      ),
                      onPressed: _toggle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _placeholder(Palette p) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Icon(Icons.videocam_outlined, size: 20, color: p.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _failed ? 'Не удалось загрузить видео' : 'Загрузка видео…',
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ожидающая часть: прогресс асинхронной задачи (например, генерации видео).
class PartPending extends StatelessWidget {
  final PendingPart part;

  const PartPending({super.key, required this.part});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final pct = part.progress.clamp(0.0, 100.0);
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  value: pct > 0 ? pct / 100 : null,
                  strokeWidth: 3,
                  color: p.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      part.name.trim().isEmpty
                          ? 'Генерация в процессе…'
                          : part.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    if (pct > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${pct.round()}%',
                        style: TextStyle(fontSize: 12, color: p.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
