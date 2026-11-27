// Copyright (c) 2026 Minkail. All rights reserved.

import '../../core/models/message_part.dart';
import '../../models.dart';

/// Один элемент галереи сгенерированного медиа (F5-gallery-image-load).
class GalleryMediaItem {
  /// true — видео, false — изображение.
  final bool isVideo;

  /// Локальный путь (без префикса 'file://') для локальных файлов,
  /// http(s)-ссылка либо data-URL для сетевых.
  final String path;

  /// Файл лежит на диске устройства.
  final bool isLocal;

  /// Заголовок чата-источника (контекст в галерее).
  final String chatTitle;

  /// Момент последнего обновления чата-источника.
  final DateTime addedAt;

  const GalleryMediaItem({
    required this.isVideo,
    required this.path,
    required this.isLocal,
    required this.chatTitle,
    required this.addedAt,
  });

  /// Короткое имя для подписи: последний сегмент пути без query.
  String get displayName {
    if (path.startsWith('data:')) return 'медиа';
    final clean = path.split('?').first;
    final idx = clean.lastIndexOf('/');
    return idx >= 0 && idx < clean.length - 1
        ? clean.substring(idx + 1)
        : (clean.isEmpty ? 'медиа' : clean);
  }
}

/// Собирает сгенерированные моделью изображения и видео из ИСТОРИИ ЧАТОВ
/// (F5-gallery-image-load, выбранное решение).
///
/// Источник правды — ChatStore: история чатов персистится в
/// SharedPreferences и уже содержит сгенерированное медиа в двух видах:
/// - части ImagePart/VideoPart (в том числе результат модели-инструмента
///   и видео-задач: GenCompleted -> VideoPart, ToolMedia -> ImagePart);
/// - markdown-ссылки `![изображение](...)` от ImagesApiExecutor.
/// Отдельное хранилище артефактов синхронизировать не нужно: галерея
/// всегда показывает то же самое, что и чаты, а новая генерация
/// появляется в галерее сама после сохранения чата.
///
/// Пользовательские сообщения не сканируются; текст, источники и
/// ожидающие задачи (PendingPart) медиа не считаются.
class GeneratedMediaCollector {
  /// Markdown-изображение: ![alt](target). Цель без пробелов —
  /// как отдаёт ImagesApiExecutor (`![изображение](file:///...)`).
  static final RegExp _markdownImage =
      RegExp(r'!\[[^\]]*\]\(([^)\s]+)\)');

  const GeneratedMediaCollector._();

  /// Свежие медиа — первыми: чаты сортируются по updatedAt по убыванию,
  /// внутри чата сообщения обходятся с конца.
  static List<GalleryMediaItem> collect(List<Chat> chats) {
    final ordered = List<Chat>.of(chats)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final seen = <String>{};
    final out = <GalleryMediaItem>[];
    for (final chat in ordered) {
      for (final m in chat.messages.reversed) {
        if (m.role == 'user') continue;
        for (final mp in m.parts) {
          final item = _fromPart(mp, chat);
          if (item != null && seen.add(item.path)) out.add(item);
        }
        final content = m.content.trim();
        if (content.isEmpty) continue;
        for (final match in _markdownImage.allMatches(content)) {
          final item = _fromSource(match.group(1) ?? '', chat);
          if (item != null && seen.add(item.path)) out.add(item);
        }
      }
    }
    return out;
  }

  /// Часть сообщения -> элемент галереи; не-медиа части игнорируются.
  static GalleryMediaItem? _fromPart(MessagePart mp, Chat chat) {
    if (mp is ImagePart) {
      return _fromSource(
        mp.isLocal ? (mp.localPath ?? '') : (mp.remoteUrl ?? ''),
        chat,
      );
    }
    if (mp is VideoPart) {
      return _fromSource(
        mp.isLocal ? (mp.localPath ?? '') : (mp.remoteUrl ?? ''),
        chat,
        isVideo: true,
      );
    }
    return null;
  }

  /// Сырой источник -> элемент галереи; неподдерживаемые схемы
  /// (пустые строки, прочие протоколы) отбрасываются.
  static GalleryMediaItem? _fromSource(
    String raw,
    Chat chat, {
    bool isVideo = false,
  }) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('file://')) {
      s = s.substring('file://'.length);
      if (s.isEmpty) return null;
      return GalleryMediaItem(
        isVideo: isVideo,
        path: s,
        isLocal: true,
        chatTitle: chat.title,
        addedAt: chat.updatedAt,
      );
    }
    // F5-gallery-image-load-heal2: ImagePart.fromPath / VideoPart.fromPath
    // хранят ГОЛЫЙ абсолютный путь без префикса 'file://' — это такой же
    // локальный файл, как и file://-ссылка. Раньше такой источник попадал
    // в «неподдерживаемую схему» и отбрасывался: локальные ImagePart вообще
    // не доходили до галереи (F5-T-GALLERY-IMAGE-AND-VIDEO: 2 вместо 3).
    // Нормализация как у file://-ветки гарантирует единый path-ключ дедупа:
    // `file:///x/img.png` и `/x/img.png` — один элемент, а не два.
    if (s.startsWith('/')) {
      return GalleryMediaItem(
        isVideo: isVideo,
        path: s,
        isLocal: true,
        chatTitle: chat.title,
        addedAt: chat.updatedAt,
      );
    }
    if (s.startsWith('data:image') || s.startsWith('data:video')) {
      return GalleryMediaItem(
        isVideo: isVideo,
        path: s,
        isLocal: false,
        chatTitle: chat.title,
        addedAt: chat.updatedAt,
      );
    }
    if (s.startsWith('http://') || s.startsWith('https://')) {
      return GalleryMediaItem(
        isVideo: isVideo,
        path: s,
        isLocal: false,
        chatTitle: chat.title,
        addedAt: chat.updatedAt,
      );
    }
    return null;
  }
}
