// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_state.dart';
import '../../core/generation/artifact_repository.dart';
import '../../core/models/artifact.dart';
import '../../theme.dart';

/// Медиа-содержимое артефакта: локальный файл, data URL либо сетевая
/// ссылка. [fit] — обрезать по контейнеру (сетка) либо вписать целиком
/// (просмотр). Локальный файл проверяется на существование: файл,
/// удалённый вручную, показывает аккуратную заглушку, а не серый квадрат.
Widget artifactMedia(
  Artifact a,
  Palette p, {
  BoxFit fit = BoxFit.cover,
}) {
  if (a.kind == Artifact.kindFile) {
    return Center(
      child: Icon(Icons.description_outlined, size: 40, color: p.accent),
    );
  }
  if (a.kind == Artifact.kindVideo) {
    return Center(
      child: Icon(Icons.movie_outlined, size: 40, color: p.accent),
    );
  }
  if (a.hasLocalFile) {
    final f = File(a.localPath.trim());
    return FutureBuilder<bool>(
      future: f.exists(),
      builder: (context, snap) {
        if (snap.data == true) {
          return Image.file(
            f,
            fit: fit,
            errorBuilder: (_, __, ___) => _mediaFallback(p, false),
          );
        }
        return _mediaFallback(p, false);
      },
    );
  }
  final url = a.remoteUrl.trim();
  if (url.startsWith('data:image')) {
    final comma = url.indexOf(',');
    if (comma >= 0 && comma + 1 < url.length) {
      try {
        final bytes = base64Decode(url.substring(comma + 1));
        return Image.memory(
          bytes,
          fit: fit,
          errorBuilder: (_, __, ___) => _mediaFallback(p, false),
        );
      } catch (_) {
        return _mediaFallback(p, false);
      }
    }
    return _mediaFallback(p, false);
  }
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return Image.network(
      url,
      fit: fit,
      errorBuilder: (_, __, ___) => _mediaFallback(p, false),
    );
  }
  return _mediaFallback(p, false);
}

Widget _mediaFallback(Palette p, bool isVideo) {
  return Center(
    child: Icon(
      isVideo ? Icons.movie_outlined : Icons.broken_image_outlined,
      size: 34,
      color: p.muted,
    ),
  );
}

/// Дата в компактном формате 'дд.мм.гггг чч:мм'.
String formatArtifactDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Стоимость в формате '≈ $0.025'; null — оценки нет.
String? formatArtifactCost(double? cost) {
  final v = cost;
  if (v == null || v <= 0) return null;
  final s = v < 0.01
      ? '\$${v.toStringAsFixed(4)}'
      : v < 1
          ? '\$${v.toStringAsFixed(3)}'
          : '\$${v.toStringAsFixed(2)}';
  return '≈ $s';
}

/// Модальное окно просмотра артефакта: изображение в InteractiveViewer
/// (для видео — статичная карточка), промпт, модель, дата, стоимость
/// и кнопки «Поделиться»/«Удалить». Удаление убирает артефакт из индекса
/// [ArtifactRepository] и закрывает окно.
class ArtifactViewer extends StatelessWidget {
  final Artifact artifact;

  const ArtifactViewer({super.key, required this.artifact});

  Future<void> _share() async {
    final a = artifact;
    try {
      if (a.hasLocalFile) {
        final f = File(a.localPath.trim());
        if (await f.exists()) {
          await Share.shareXFiles(
            <XFile>[XFile(f.path)],
            text: a.prompt.trim().isEmpty ? null : a.prompt.trim(),
          );
          return;
        }
      }
      if (a.hasRemoteUrl) {
        await Share.share(a.remoteUrl.trim());
      }
    } catch (_) {
      // Шеринг недоступен на этом устройстве — молча игнорируем.
    }
  }

  Future<void> _delete(BuildContext context) async {
    final nav = Navigator.of(context);
    await ArtifactRepository.instance.delete(artifact.id);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final a = artifact;
        final cost = formatArtifactCost(a.cost);
        return Dialog(
          backgroundColor: p.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      height: 280,
                      color: p.codeBg,
                      child: a.kind == Artifact.kindVideo
                          ? _videoCard(a, p)
                          : InteractiveViewer(
                              maxScale: 8,
                              child: Center(
                                child:
                                    artifactMedia(a, p, fit: BoxFit.contain),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (a.prompt.trim().isNotEmpty) ...[
                    _info(p, 'ПРОМПТ', a.prompt.trim(), mono: false),
                    const SizedBox(height: 10),
                  ],
                  if (a.modelId.trim().isNotEmpty) ...[
                    _info(p, 'МОДЕЛЬ', a.modelId.trim(), mono: true),
                    const SizedBox(height: 10),
                  ],
                  _info(
                    p,
                    'ДАТА',
                    formatArtifactDate(a.createdAt),
                    mono: false,
                  ),
                  if (cost != null) ...[
                    const SizedBox(height: 10),
                    _info(p, 'СТОИМОСТЬ', cost, mono: false),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _share,
                          icon: const Icon(Icons.share_outlined, size: 18),
                          label: const Text('Поделиться'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _delete(context),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFB3261E),
                            side: const BorderSide(color: Color(0xFFB3261E)),
                          ),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Удалить'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _videoCard(Artifact a, Palette p) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.movie_outlined, size: 56, color: p.accent),
          const SizedBox(height: 10),
          Text(
            'Видео',
            style: TextStyle(fontSize: 14, color: p.muted),
          ),
        ],
      ),
    );
  }

  Widget _info(Palette p, String label, String value, {required bool mono}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: p.accent,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: mono
              ? const TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontFamilyFallback: ['monospace'],
                  fontSize: 13,
                  height: 1.4,
                )
              : fontStyle(
                  settings.bodyFont,
                  size: 14,
                  height: 1.4,
                  color: p.text,
                ),
        ),
      ],
    );
  }
}
