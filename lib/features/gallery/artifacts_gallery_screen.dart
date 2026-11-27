// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme.dart';
import 'generated_media_collector.dart';

/// Галерея сгенерированного медиа (F5-gallery-image-load).
///
/// Читает историю чатов (ChatStore) через [GeneratedMediaCollector]:
/// сгенерированные изображения и видео появляются в галерее сразу после
/// сохранения чата, отдельное хранилище артефактов не требуется.
/// Публичный API прежний: `const ArtifactsGalleryScreen()`.
class ArtifactsGalleryScreen extends StatelessWidget {
  const ArtifactsGalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Галерея')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final p = settings.palette;
            final items = GeneratedMediaCollector.collect(store.chats);
            if (items.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.photo_library_outlined,
                        size: 40,
                        color: p.muted,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Пока нет сгенерированных изображений и видео.\n'
                        'Создайте картинку или видео в чате — '
                        'оно появится здесь.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: p.muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              );
            }
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) => _GalleryTile(item: items[i]),
            );
          },
        ),
      ),
    );
  }
}

/// Плитка галереи: изображение открывает полноэкранный просмотр,
/// видео — статичная карточка (просмотр видео остаётся в чате).
class _GalleryTile extends StatelessWidget {
  final GalleryMediaItem item;

  const _GalleryTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    if (item.isVideo) {
      return Container(
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.movie_outlined, size: 26, color: p.accent),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                item.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: p.muted),
              ),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: () => _openViewer(context, item),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: p.codeBg,
          child: _MediaView(item: item, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

/// Локальный файл, https-ссылка либо data-URL; неудача загрузки —
/// аккуратная иконка, галерея не падает.
class _MediaView extends StatelessWidget {
  final GalleryMediaItem item;
  final BoxFit fit;

  const _MediaView({required this.item, required this.fit});

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    if (item.isLocal) {
      return Image.file(
        File(item.path),
        fit: fit,
        errorBuilder: (_, __, ___) => _broken(p),
      );
    }
    if (item.path.startsWith('data:')) {
      final comma = item.path.indexOf(',');
      if (comma >= 0 && comma + 1 < item.path.length) {
        try {
          return Image.memory(
            base64Decode(item.path.substring(comma + 1)),
            fit: fit,
            errorBuilder: (_, __, ___) => _broken(p),
          );
        } catch (_) {}
      }
      return _broken(p);
    }
    return Image.network(
      item.path,
      fit: fit,
      errorBuilder: (_, __, ___) => _broken(p),
    );
  }

  Widget _broken(Palette p) => Icon(
        Icons.broken_image_outlined,
        size: 28,
        color: p.muted,
      );
}

/// Полноэкранный просмотр с масштабированием.
void _openViewer(BuildContext context, GalleryMediaItem item) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(
            item.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5.0,
            child: _MediaView(item: item, fit: BoxFit.contain),
          ),
        ),
      ),
    ),
  );
}
