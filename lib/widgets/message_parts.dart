// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
// G1-video-player: плеер вынесен в единый VideoPlayerCard
// (video_player_card.dart) — тот же код в чате, полном экране и галерее.
// Импорт сохранён по правилам проекта.
// ignore: unused_import
import 'package:video_player/video_player.dart';

import '../app_state.dart';
import '../core/models/message_part.dart';
import '../theme.dart';
import 'video_player_card.dart';

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

/// Видео из части сообщения: единый видеоплеер приложения
/// (G1-video-player). Тап — play/pause; полоса перемотки со временем,
/// звук/без звука, кнопка «На весь экран», повтор после конца,
/// скачивание и шаринг — всё внутри VideoPlayerCard. Один код с
/// галереей и полноэкранным режимом (см. video_player_card.dart).
class PartVideo extends StatelessWidget {
  final VideoPart part;

  const PartVideo({super.key, required this.part});

  @override
  Widget build(BuildContext context) {
    final src = part.isLocal ? (part.localPath ?? '') : (part.remoteUrl ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: VideoPlayerCard(source: src),
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
