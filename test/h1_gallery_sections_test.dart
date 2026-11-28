// Copyright (c) 2026 Minkail. All rights reserved.

// H1-gallery: именованные живые тесты галереи.
//
// - H1-T-SECTIONS: на экране галереи видны три раздела (Все/Изображения/Видео).
// - H1-T-FILTER: фильтр по разделу (collector-level: «Видео» — только видео,
//   «Изображения» — только картинки, «Все» — и то и другое).
// - H1-T-THUMBNAIL: у видео-плитки рендерится превью-кадр через video_player
//   (фейк платформы, как в G1), а не только фон с треугольником.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/features/gallery/artifacts_gallery_screen.dart';
import 'package:gentech_chat/features/gallery/generated_media_collector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart' show VideoPlayer;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Фейк платформенной реализации video_player (по образу G1-тестов):
/// переопределяет и старое (create/buildView), и новое
/// (createWithOptions/buildViewWithOptions) API — состав будущих вызовов
/// контроллера зависит от зафиксированной версии пакета. Остальные методы
/// не переопределяются: контроллер вызывает только перечисленные.
class _FakeVideoPlatform extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}

  @override
  Future<int> create(DataSource dataSource) async => 7;

  @override
  Future<int> createWithOptions(VideoCreationOptions options) async => 7;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      Stream<VideoEvent>.value(const VideoEvent(
        eventType: VideoEventType.initialized,
        duration: Duration(seconds: 6),
        size: Size(640, 360),
      ));

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
}

GalleryMediaItem _image(String path) => GalleryMediaItem(
      isVideo: false,
      path: path,
      isLocal: false,
      chatTitle: 'чат',
      addedAt: DateTime(2026, 11, 28),
    );

GalleryMediaItem _video(String path) => GalleryMediaItem(
      isVideo: true,
      path: path,
      isLocal: false,
      chatTitle: 'чат',
      addedAt: DateTime(2026, 11, 28),
      thumbnailSource: path,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    VideoPreviewCache.instance.clearForTests();
  });

  testWidgets('H1-T-SECTIONS: видны три раздела — Все, Изображения, Видео',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ArtifactsGalleryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Все'), findsOneWidget);
    expect(find.text('Изображения'), findsOneWidget);
    expect(find.text('Видео'), findsOneWidget);
    // Сегмент «Все» выбран по умолчанию — ключ сегмента присутствует.
    expect(find.byKey(const ValueKey('gallery_section_all')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('gallery_section_images')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('gallery_section_videos')), findsOneWidget);
  });

  test('H1-T-FILTER: разделы фильтруют элементы — Все/Изображения/Видео',
      () {
    final items = <GalleryMediaItem>[
      _image('https://example.com/a.png'),
      _video('https://example.com/v1.mp4'),
      _image('https://example.com/b.png'),
      _video('https://example.com/v2.mp4'),
    ];

    final all = GeneratedMediaCollector.filter(items, GallerySection.all);
    expect(all.length, 4);

    final images = GeneratedMediaCollector.filter(items, GallerySection.images);
    expect(images.length, 2);
    expect(images.every((e) => !e.isVideo), isTrue);

    final videos = GeneratedMediaCollector.filter(items, GallerySection.videos);
    expect(videos.length, 2);
    expect(videos.every((e) => e.isVideo), isTrue);
  });

  testWidgets('H1-T-THUMBNAIL: у видео рендерится превью-кадр, а не только '
      'фон с треугольником', (tester) async {
    VideoPlayerPlatform.instance = _FakeVideoPlatform();
    addTearDown(() {
      VideoPlayerPlatform.instance = _PlaceholderVideoPlatform();
    });

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: GalleryVideoPreview(
          path: 'https://example.com/clip.mp4',
          isLocal: false,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Превью построено: внутри виджета-превью живёт VideoPlayer
    // (инициализированный контроллер, поставленный на паузу), а не
    // только фон с иконкой-фолбэком.
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(find.byType(GalleryVideoPreview), findsOneWidget);
  });
}
