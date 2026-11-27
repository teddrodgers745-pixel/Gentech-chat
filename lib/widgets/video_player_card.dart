// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../app_state.dart';
import '../theme.dart';

/// ЕДИНЫЙ видеоплеер приложения (G1-video-player): один код и один дизайн
/// для карточки видео в чате, полноэкранного режима и галереи.
///
/// Возможности:
///  - тап по видео — play/pause (понятно и предсказуемо, нет «мёртвой»
///    кнопки и «второго тапа — стоп»);
///  - полоса перемотки (VideoProgressIndicator с scrubbing) и время
///    «позиция / длительность»;
///  - кнопка «На весь экран» — тот же плеер в полноэкранном Scaffold
///    с автоплеем, скачиванием и шерингом в AppBar;
///  - звук / без звука (setVolume);
///  - повтор после конца (isCompleted -> seekTo(0) + play);
///  - постер-заглушка «Загрузка видео…», пока плеер инициализируется;
///  - ошибка инициализации — карточка с кнопкой «Повторить» (повторная
///    загрузка ТОГО ЖЕ источника, без новой генерации — по духу
///    F1/_RetryableNetworkImage) и с кнопками «Скачать»/«Поделиться»,
///    чтобы видео можно было забрать даже без воспроизведения;
///  - скачивание (Downloads / FilePicker / Documents) и системный шаринг
///    через share_plus.
///
/// Контролы появляются по тапу и угасают через 4 секунды во время
/// воспроизведения; на паузе остаются видимыми.
class VideoPlayerCard extends StatefulWidget {
  const VideoPlayerCard({super.key, required this.source, this.fullscreen = false});

  /// Источник видео: локальный путь ('/...' или 'file://...'),
  /// http(s)-ссылка либо data:video (последняя не проигрывается —
  /// плеер показывает карточку ошибки с кнопками «Скачать»/«Поделиться»).
  final String source;

  /// true — полноэкранный режим: автоплей после инициализации,
  /// кнопка «На весь экран» в контролах не показывается.
  final bool fullscreen;

  @override
  State<VideoPlayerCard> createState() => _VideoPlayerCardState();
}

class _VideoPlayerCardState extends State<VideoPlayerCard> {
  VideoPlayerController? _controller;
  bool _loading = false;
  bool _failed = false;
  bool _muted = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _disposeController();
      _failed = false;
      _muted = false;
      _initController();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hideTimer = null;
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
    if (!mounted) return;
    final c = _controller;
    // Видео дошло до конца — показываем контролы с кнопкой повтора.
    if (c != null && c.value.isCompleted && !_controlsVisible) {
      _showControls();
    }
    setState(() {});
  }

  void _showControls() {
    _hideTimer?.cancel();
    _hideTimer = null;
    final playing = _controller?.value.isPlaying ?? false;
    if (playing) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _controlsVisible = false);
      });
    }
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
  }

  Future<void> _initController() async {
    final src = widget.source.trim();
    if (!isPlayableVideoSource(src)) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    final c = createVideoPlayerController(src);
    try {
      await c.initialize();
    } catch (_) {
      try {
        await c.dispose();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
      return;
    }
    if (!mounted) {
      try {
        await c.dispose();
      } catch (_) {}
      return;
    }
    c.addListener(_onTick);
    setState(() {
      _controller = c;
      _loading = false;
      _controlsVisible = true;
    });
    if (widget.fullscreen && !c.value.isPlaying) {
      unawaited(c.play());
    }
    _showControls();
  }

  void _retry() {
    _disposeController();
    _initController();
  }

  void _onVideoTap() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final v = c.value;
    if (v.isCompleted ||
        (v.duration > Duration.zero && v.position >= v.duration)) {
      // Повтор после конца: с нуля, а не молчаливый «второй тап — стоп».
      unawaited(c.seekTo(Duration.zero));
      unawaited(c.play());
    } else if (v.isPlaying) {
      unawaited(c.pause());
    } else {
      unawaited(c.play());
    }
    _showControls();
  }

  void _toggleMute() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() => _muted = !_muted);
    unawaited(c.setVolume(_muted ? 0.0 : 1.0));
    _showControls();
  }

  void _openFullscreen() {
    final c = _controller;
    // Останавливаем встроенный плеер — звук не должен идти дважды.
    if (c != null && c.value.isPlaying) {
      unawaited(c.pause());
    }
    openFullscreenVideo(context, widget.source);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final c = _controller;
        if (widget.fullscreen) {
          return _fullscreenBody(p, c);
        }
        return _cardBody(p, c);
      },
    );
  }

  Widget _cardBody(Palette p, VideoPlayerController? c) {
    if (_failed || c == null || !c.value.isInitialized) {
      return _placeholderCard(p, c);
    }
    final ar = c.value.aspectRatio;
    final ratio = (ar.isFinite && ar > 0) ? ar : 16 / 9;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: ratio,
            child: _videoStack(),
          ),
          _footer(p),
        ],
      ),
    );
  }

  Widget _fullscreenBody(Palette p, VideoPlayerController? c) {
    final Widget content;
    if (_failed || c == null || !c.value.isInitialized) {
      content = _placeholderCard(p, c);
    } else {
      final ar = c.value.aspectRatio;
      final ratio = (ar.isFinite && ar > 0) ? ar : 16 / 9;
      content = AspectRatio(
        aspectRatio: ratio,
        child: _videoStack(),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(child: content),
    );
  }

  Widget _videoStack() {
    final c = _controller!;
    return GestureDetector(
      key: const ValueKey('g1_video_tap_area'),
      behavior: HitTestBehavior.opaque,
      onTap: _onVideoTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ColoredBox(
            color: Colors.black,
            child: VideoPlayer(c),
          ),
          IgnorePointer(
            ignoring: true,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _controlsVisible ? 1.0 : 0.0,
              child: _centerButton(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _controlsVisible ? 1.0 : 0.0,
                child: _bottomControls(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _centerButton() {
    final v = _controller!.value;
    final IconData icon;
    if (v.isCompleted ||
        (v.duration > Duration.zero && v.position >= v.duration)) {
      icon = Icons.replay_rounded;
    } else if (v.isPlaying) {
      icon = Icons.pause_rounded;
    } else {
      icon = Icons.play_arrow_rounded;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24),
      ),
      child: Icon(icon, size: 40, color: Colors.white),
    );
  }

  Widget _bottomControls() {
    final c = _controller;
    if (c == null) return const SizedBox.shrink();
    final p = settings.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: VideoProgressIndicator(
              c,
              allowScrubbing: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              colors: VideoProgressColors(
                playedColor: p.accent,
                bufferedColor: Colors.white38,
                backgroundColor: Colors.white24,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
            child: Row(
              children: [
                Text(
                  '${formatVideoTime(c.value.position)} / '
                  '${formatVideoTime(c.value.duration)}',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
                const Spacer(),
                IconButton(
                  tooltip: _muted ? 'Включить звук' : 'Выключить звук',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    size: 20,
                    color: Colors.white,
                  ),
                  onPressed: _toggleMute,
                ),
                if (!widget.fullscreen) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'На весь экран',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.fullscreen_rounded,
                      size: 22,
                      color: Colors.white,
                    ),
                    onPressed: _openFullscreen,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.movie_outlined, size: 18, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              videoDisplayName(widget.source),
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
            tooltip: 'Скачать',
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            icon: Icon(Icons.download_rounded, size: 22, color: p.muted),
            onPressed: () => saveVideoToDevice(context, widget.source),
          ),
          IconButton(
            tooltip: 'Поделиться',
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            icon: Icon(Icons.share_outlined, size: 20, color: p.muted),
            onPressed: () => shareVideo(context, widget.source),
          ),
        ],
      ),
    );
  }

  /// Загрузка либо ошибка: карточка с именем, состоянием и действиями —
  /// скачать и поделиться можно даже без воспроизведения.
  Widget _placeholderCard(Palette p, VideoPlayerController? c) {
    final loading = _loading || (c != null && !c.value.isInitialized);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            height: 42,
            child: loading
                ? Padding(
                    padding: const EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.accent,
                    ),
                  )
                : Container(
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.videocam_outlined,
                        size: 22, color: p.accent),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  videoDisplayName(widget.source),
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
                  _failed ? 'Не удалось загрузить видео' : 'Загрузка видео…',
                  style: TextStyle(fontSize: 12, color: p.muted),
                ),
              ],
            ),
          ),
          if (_failed)
            IconButton(
              tooltip: 'Повторить',
              visualDensity: VisualDensity.compact,
              iconSize: 22,
              icon: Icon(Icons.refresh_rounded, size: 20, color: p.muted),
              onPressed: _retry,
            ),
          IconButton(
            tooltip: 'Скачать',
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            icon: Icon(Icons.download_rounded, size: 22, color: p.muted),
            onPressed: () => saveVideoToDevice(context, widget.source),
          ),
          IconButton(
            tooltip: 'Поделиться',
            visualDensity: VisualDensity.compact,
            iconSize: 22,
            icon: Icon(Icons.share_outlined, size: 20, color: p.muted),
            onPressed: () => shareVideo(context, widget.source),
          ),
        ],
      ),
    );
  }
}

/// Полноэкранный просмотр видео: тот же плеер (автоплей, перемотка,
/// звук, повтор) плюс скачивание и шеринг в AppBar. Используется и из
/// карточки в чате, и из галереи — один код, один дизайн.
class _FullscreenVideoPage extends StatelessWidget {
  final String source;
  final String name;

  const _FullscreenVideoPage({required this.source, required this.name});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('g1_fullscreen_video'),
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Скачать',
            icon: const Icon(Icons.download),
            onPressed: () => saveVideoToDevice(context, source),
          ),
          IconButton(
            tooltip: 'Поделиться',
            icon: const Icon(Icons.share),
            onPressed: () => shareVideo(context, source),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: VideoPlayerCard(
            key: const ValueKey('g1_fullscreen_video_player'),
            source: source,
            fullscreen: true,
          ),
        ),
      ),
    );
  }
}

/// Открывает полноэкранный плеер того же источника.
void openFullscreenVideo(
  BuildContext context,
  String source, {
  String? name,
}) {
  final s = source.trim();
  if (s.isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _FullscreenVideoPage(
        source: s,
        name: (name == null || name.trim().isEmpty)
            ? videoDisplayName(s)
            : name,
      ),
    ),
  );
}

/// Играть ли этот источник: локальный путь, file://-URL или http(s).
/// data:video проигрыванию не подлежит — карточка ошибки с действиями.
bool isPlayableVideoSource(String source) {
  final s = source.trim();
  return s.startsWith('/') ||
      s.startsWith('file://') ||
      s.startsWith('http://') ||
      s.startsWith('https://');
}

/// Создаёт VideoPlayerController под тип источника.
VideoPlayerController createVideoPlayerController(String source) {
  final s = source.trim();
  if (s.startsWith('http://') || s.startsWith('https://')) {
    return VideoPlayerController.networkUrl(Uri.parse(s));
  }
  final path =
      s.startsWith('file://') ? Uri.parse(s).toFilePath() : s;
  return VideoPlayerController.file(File(path));
}

/// Короткое имя видеофайла: последний сегмент пути без query.
String videoDisplayName(String source) {
  final clean = source.trim().replaceFirst(RegExp(r'^file://'), '');
  if (clean.startsWith('data:')) return 'видео';
  final withoutQuery = clean.split('?').first;
  final idx = withoutQuery.lastIndexOf('/');
  if (idx >= 0 && idx < withoutQuery.length - 1) {
    return withoutQuery.substring(idx + 1);
  }
  return withoutQuery.isEmpty ? 'видео' : withoutQuery;
}

/// Хук системного шеринга: в проде — share_plus (системный share sheet),
/// в виджет-тестах G1 — подменяется замоканной функцией.
Future<void> Function(List<XFile> files) shareFilesHook = shareViaSharePlus;

/// Продовый шэринг видеофайла через системный share sheet.
Future<void> shareViaSharePlus(List<XFile> files) =>
    Share.shareXFiles(files);

/// Читает байты видео из локального файла, data URL или по http(s).
Future<Uint8List> readVideoBytes(String source) async {
  final s = source.trim();
  if (s.startsWith('data:')) {
    final idx = s.indexOf(',');
    if (idx < 0 || idx + 1 >= s.length) {
      throw const FormatException('bad data url');
    }
    return base64Decode(s.substring(idx + 1));
  }
  if (s.startsWith('http://') || s.startsWith('https://')) {
    final resp =
        await http.get(Uri.parse(s)).timeout(const Duration(seconds: 120));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }
  final path = s.startsWith('file://') ? Uri.parse(s).toFilePath() : s;
  return File(path).readAsBytes();
}

/// Сохраняет видео на устройство с видимым состоянием:
/// «Сохранение видео…» -> «Видео сохранено: …» либо «Не удалось…».
/// Порядок: Downloads (Android) -> системный диалог сохранения
/// (FilePicker) -> Downloads/Documents через path_provider.
Future<void> saveVideoToDevice(BuildContext context, String source) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void snack(String text) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  final s = source.trim();
  if (s.isEmpty) {
    snack('Не удалось сохранить видео');
    return;
  }
  snack('Сохранение видео…');
  try {
    final bytes = await readVideoBytes(s);
    if (bytes.isEmpty) throw Exception('Пустой файл');
    final fileName =
        'vid_${DateTime.now().millisecondsSinceEpoch}${videoExtFor(s)}';
    var savedPath = '';

    if (Platform.isAndroid) {
      try {
        final dlDir = Directory('/storage/emulated/0/Download');
        if (await dlDir.exists()) {
          final outFile = File('${dlDir.path}/$fileName');
          await outFile.writeAsBytes(bytes, flush: true);
          savedPath = outFile.path;
        }
      } catch (_) {
        savedPath = '';
      }
    }

    if (savedPath.isEmpty) {
      try {
        final picked = await FilePicker.platform.saveFile(
          dialogTitle: 'Сохранить видео',
          fileName: fileName,
          type: FileType.video,
          bytes: bytes,
        );
        if (picked != null && picked.isNotEmpty) {
          final f = File(picked);
          if (!await f.exists() || await f.length() == 0) {
            await f.writeAsBytes(bytes, flush: true);
          }
          savedPath = picked;
        }
      } catch (_) {
        savedPath = '';
      }
    }

    if (savedPath.isEmpty) {
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final outFile = File('${dir.path}/$fileName');
      await outFile.writeAsBytes(bytes, flush: true);
      savedPath = outFile.path;
    }
    snack('Видео сохранено: $fileName');
  } catch (_) {
    snack('Не удалось сохранить видео');
  }
}

/// Шаринг видео: локальный файл шэрится как есть, сетевой/data —
/// сначала скачивается во временный файл, затем системный share sheet.
Future<void> shareVideo(BuildContext context, String source) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void snack(String text) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  final s = source.trim();
  if (s.isEmpty) {
    snack('Не удалось поделиться видео');
    return;
  }
  try {
    final path = await _videoSharePath(s);
    await shareFilesHook([XFile(path)]);
  } catch (_) {
    snack('Не удалось поделиться видео');
  }
}

/// Путь файла для шеринга: локальный — как есть, удалённый —
/// временная копия.
Future<String> _videoSharePath(String source) async {
  final s = source.trim();
  if (s.startsWith('/')) return s;
  if (s.startsWith('file://')) return Uri.parse(s).toFilePath();
  final bytes = await readVideoBytes(s);
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/vid_${DateTime.now().millisecondsSinceEpoch}'
    '${videoExtFor(s)}',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Расширение файла по источнику; по умолчанию .mp4.
String videoExtFor(String source) {
  final clean = source.trim().split('?').first.toLowerCase();
  if (clean.endsWith('.webm')) return '.webm';
  if (clean.endsWith('.mov')) return '.mov';
  if (clean.endsWith('.avi')) return '.avi';
  return '.mp4';
}

/// «мин:сс» / «ч:мм:сс» для строки времени под полосой перемотки.
String formatVideoTime(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}
