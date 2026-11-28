// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../widgets/video_player_card.dart';
import 'generated_media_collector.dart';

/// Галерея сгенерированного медиа (F5-gallery-image-load, H1-gallery).
///
/// Читает историю чатов (ChatStore) через [GeneratedMediaCollector]:
/// сгенерированные изображения и видео появляются в галерее сразу после
/// сохранения чата, отдельное хранилище артефактов не требуется.
///
/// H1-gallery: над сеткой три раздела — «Все», «Изображения», «Видео» —
/// выбор фильтрует список; у видео-плитки на иконке показывается ПРЕВЬЮ
/// (миниатюра кадра через video_player, кэш [VideoPreviewCache]), play
/// и подпись остаются поверх превью.
///
/// Публичный API прежний: `const ArtifactsGalleryScreen()`
/// (опциональный [chats] — переопределение источника для тестов).
class ArtifactsGalleryScreen extends StatefulWidget {
  /// Переопределение источника чатов (для тестов); null — глобальный store.
  final List<Chat>? chats;

  const ArtifactsGalleryScreen({super.key, this.chats});

  @override
  State<ArtifactsGalleryScreen> createState() => _ArtifactsGalleryScreenState();
}

class _ArtifactsGalleryScreenState extends State<ArtifactsGalleryScreen> {
  /// Выбранный раздел; по умолчанию «Все» (сохранять выбор не требуется).
  GallerySection _section = GallerySection.all;

  void _select(GallerySection s) {
    if (s == _section) return;
    setState(() => _section = s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Галерея')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final p = settings.palette;
            final allItems =
                GeneratedMediaCollector.collect(widget.chats ?? store.chats);
            final items = GeneratedMediaCollector.filter(allItems, _section);
            return Column(
              children: [
                _SectionSwitcher(current: _section, onSelect: _select),
                Expanded(
                  child: items.isEmpty
                      ? _EmptyHint(palette: p, section: _section)
                      : GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, i) =>
                              _GalleryTile(item: items[i]),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Переключатель разделов галереи (H1-T-SECTIONS): три сегмента в стиле
/// приложения — палитра [Palette], те же радиусы, что у плиток.
class _SectionSwitcher extends StatelessWidget {
  final GallerySection current;
  final ValueChanged<GallerySection> onSelect;

  const _SectionSwitcher({required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          _segment(GallerySection.all, 'Все'),
          _segment(GallerySection.images, 'Изображения'),
          _segment(GallerySection.videos, 'Видео'),
        ],
      ),
    );
  }

  Widget _segment(GallerySection section, String label) {
    final p = settings.palette;
    final selected = section == current;
    return Expanded(
      child: GestureDetector(
        key: ValueKey('gallery_section_${section.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(section),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? p.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? Colors.white : p.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Заглушка пустой галереи (H1-gallery): своя подсказка для каждого
/// раздела — «Все» повторяет текст прежней пустой ветки (F5),
/// «Изображения»/«Видео» уточняют, чего именно пока нет.
class _EmptyHint extends StatelessWidget {
  final Palette palette;
  final GallerySection section;

  const _EmptyHint({required this.palette, required this.section});

  @override
  Widget build(BuildContext context) {
    final String message;
    switch (section) {
      case GallerySection.all:
        message = 'Пока нет сгенерированных изображений и видео.\n'
            'Создайте картинку или видео в чате — оно появится здесь.';
        break;
      case GallerySection.images:
        message = 'В разделе «Изображения» пока пусто.\n'
            'Сгенерируйте картинку в чате — она появится здесь.';
        break;
      case GallerySection.videos:
        message = 'В разделе «Видео» пока пусто.\n'
            'Сгенерируйте видео в чате — оно появится здесь.';
        break;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 40,
              color: palette.muted,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Плитка галереи: изображение открывает полноэкранный просмотр,
/// видео (G1-video-player) — тот же полноэкранный плеер, что и в чате.
/// H1-gallery: у видео-плитки под play и подписью показывается превью
/// (миниатюра кадра) через [GalleryVideoPreview]; при недоступном превью
/// остаётся аккуратный фон.
class _GalleryTile extends StatelessWidget {
  final GalleryMediaItem item;

  const _GalleryTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    if (item.isVideo) {
      return GestureDetector(
        onTap: () => _openVideoViewer(context, item),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            color: p.card,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_hasPreviewSource(item))
                  GalleryVideoPreview(
                    path: item.thumbnailSource ?? item.path,
                    isLocal: item.isLocal,
                  )
                else
                  Container(color: p.codeBg),
                // Треугольник play остаётся ПОВЕРХ превью (H1-gallery).
                Center(
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Colors.black38, blurRadius: 6),
                      ],
                    ),
                    child: const Icon(
                      Icons.play_circle_outline,
                      size: 34,
                      color: Colors.white,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _VideoLabel(label: item.displayName),
                ),
              ],
            ),
          ),
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

/// Подпись видео-плитки поверх превью, с мягким затемнением снизу —
/// читается и на светлом, и на тёмном кадре.
class _VideoLabel extends StatelessWidget {
  final String label;

  const _VideoLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      child: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 10, color: Colors.white),
      ),
    );
  }
}

/// Есть ли смысл строить превью для видео-элемента: локальный существующий
/// файл либо http(s)-ссылка. data-URL видео и отсутствующие файлы превью
/// не получают (плитка показывает фон с play и подписью).
bool _hasPreviewSource(GalleryMediaItem item) {
  if (item.thumbnailSource == null) return false;
  if (item.isLocal) return File(item.path).existsSync();
  final s = item.path;
  if (s.startsWith('data:')) return false;
  return s.startsWith('http://') || s.startsWith('https://');
}

/// Превью (миниатюра кадра) видео для плитки галереи (H1-gallery).
///
/// Кадр рендерится через video_player: контроллер инициализируется,
/// ставится на паузу и сматывается на 150 мс, чтобы платформа отрисовала
/// кадр. Готовые контроллеры кэшируются в [VideoPreviewCache] — повторное
/// открытие галереи не переинициализирует то же видео. Если превью
/// недоступно (нет файла, data-URL, ошибка декодирования/платформы),
/// показывается аккуратный фолбэк — галерея не падает.
class GalleryVideoPreview extends StatefulWidget {
  final String path;
  final bool isLocal;

  const GalleryVideoPreview({
    super.key,
    required this.path,
    required this.isLocal,
  });

  @override
  State<GalleryVideoPreview> createState() => _GalleryVideoPreviewState();
}

class _GalleryVideoPreviewState extends State<GalleryVideoPreview> {
  late final Future<VideoPlayerController?> _acquired;

  @override
  void initState() {
    super.initState();
    _acquired =
        VideoPreviewCache.instance.acquire(widget.path, widget.isLocal);
  }

  @override
  void dispose() {
    VideoPreviewCache.instance.release(widget.path);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    return FutureBuilder<VideoPlayerController?>(
      future: _acquired,
      builder: (context, snap) {
        final controller = snap.data;
        if (snap.connectionState == ConnectionState.done &&
            controller != null &&
            controller.value.isInitialized) {
          final ar = controller.value.aspectRatio;
          final safeAr = ar > 0 ? ar : 1.0;
          // Заполнение плитки БЕЗ искажения пропорций кадра: FittedBox
          // (cover) масштабирует кадр целиком и аккуратно обрезает лишнее.
          return ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: 1.0,
                height: 1.0 / safeAr,
                child: VideoPlayer(controller),
              ),
            ),
          );
        }
        if (snap.connectionState == ConnectionState.done) {
          // Провал: нет файла / ошибка декодирования / нет платформенной
          // поддержки — показываем фон с иконкой, галерея не падает.
          return Container(
            color: p.codeBg,
            alignment: Alignment.center,
            child: Icon(Icons.videocam_outlined, size: 26, color: p.muted),
          );
        }
        // Инициализация в полёте: спокойный фон (play и подпись рисует
        // плитка поверх).
        return Container(color: p.codeBg);
      },
    );
  }
}

/// In-memory кэш превью-контроллеров видео для галереи (H1-gallery).
///
/// Кэширует ГОТОВЫЕ (инициализированные, на паузе, смотанные на 150 мс)
/// контроллеры video_player по пути источника: открытие галереи
/// переиспользует уже готовый кадр вместо повторной инициализации того же
/// видео. Контроллер, видимый хотя бы одной плитке (uses > 0), не
/// вытесняется; неиспользуемые вытесняются по LRU и освобождаются —
/// в памяти живёт не более [maxEntries] контроллеров. Пути с неудачной
/// инициализацией запоминаются в «чёрном списке», чтобы сетка не
/// перезапускала заведомо падающее превью при каждом перестроении.
class VideoPreviewCache {
  VideoPreviewCache._();

  static final VideoPreviewCache instance = VideoPreviewCache._();

  /// Максимальное число закэшированных превью-контроллеров.
  static const int maxEntries = 24;

  final Map<String, _PreviewEntry> _entries = {};
  final Set<String> _failed = {};

  /// Возвращает будущий готовый контроллер превью (null — превью для пути
  /// недоступно) и увеличивает счётчик использований записи.
  Future<VideoPlayerController?> acquire(String key, bool isLocal) {
    if (_failed.contains(key)) {
      return Future<VideoPlayerController?>.value();
    }
    var entry = _entries[key];
    if (entry == null) {
      if (_entries.length >= maxEntries) _evict();
      entry = _PreviewEntry();
      _entries[key] = entry;
    }
    // Ненулевая локальная ссылка: замыкание ниже не сохраняет promotion
    // переменной [entry] (объявлена как `_PreviewEntry?`), поэтому работа
    // с записью внутри `.then` идёт через `current`.
    final current = entry;
    current
      ..uses += 1
      ..lastUsed = DateTime.now();
    // `??=` возвращает присвоенное (уже ненулевое) будущее: и существующая
    // инициализация «в полёте», и только что запущенная возвращаются как
    // `Future<VideoPlayerController?>` без лишнего re-read nullable-поля.
    final init = current.init ??= _startInit(key, isLocal).then((c) {
      final attached = identical(_entries[key], current);
      current.controller = c;
      if (!attached) _disposeEntry(current);
      return attached ? c : null;
    });
    return init;
  }

  /// Уменьшает счётчик использований; неиспользуемая запись сверх лимита
  /// вытесняется и освобождается.
  void release(String key) {
    final entry = _entries[key];
    if (entry == null) return;
    entry.uses -= 1;
    if (entry.uses <= 0 && _entries.length > maxEntries) {
      _entries.remove(key);
      _disposeEntry(entry);
    }
  }

  /// Полная очистка кэша (для тестов): освобождает готовые контроллеры;
  /// инициализации «в полёте» освобождает их завершающий .then.
  void clearForTests() {
    final keys = _entries.keys.toList();
    for (final key in keys) {
      final entry = _entries.remove(key)!;
      _disposeEntry(entry);
    }
    _failed.clear();
  }

  Future<VideoPlayerController?> _startInit(String key, bool isLocal) async {
    VideoPlayerController? controller;
    try {
      controller = isLocal
          ? VideoPlayerController.file(File(key))
          : VideoPlayerController.networkUrl(Uri.parse(key));
      await controller.initialize();
      await controller.pause();
      // Сматываем чуть вперёд, чтобы платформа гарантированно отрисовала
      // кадр: на позиции 0 некоторые платформы держат пустую поверхность.
      final duration = controller.value.duration;
      if (duration > const Duration(milliseconds: 150)) {
        await controller.seekTo(const Duration(milliseconds: 150));
      }
      return controller;
    } catch (_) {
      // Превью не получилось — не оставляем контроллер и не ретраим путь.
      controller?.dispose();
      _failed.add(key);
      return null;
    }
  }

  void _evict() {
    String? oldestKey;
    DateTime? oldestAt;
    for (final e in _entries.entries) {
      if (e.value.uses > 0) continue; // виден хотя бы одной плитке
      if (oldestAt == null || e.value.lastUsed.isBefore(oldestAt)) {
        oldestAt = e.value.lastUsed;
        oldestKey = e.key;
      }
    }
    if (oldestKey == null) return;
    _disposeEntry(_entries.remove(oldestKey)!);
  }

  void _disposeEntry(_PreviewEntry entry) {
    entry.controller?.dispose();
    entry.controller = null;
  }
}

class _PreviewEntry {
  VideoPlayerController? controller;
  Future<VideoPlayerController?>? init;
  int uses = 0;
  DateTime lastUsed = DateTime.now();
}

/// Полноэкранный видеоплеер из галереи: тот же единый плеер
/// (video_player_card.dart), что и в карточке чата.
void _openVideoViewer(BuildContext context, GalleryMediaItem item) {
  openFullscreenVideo(
    context,
    item.path,
    name: item.displayName,
  );
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
