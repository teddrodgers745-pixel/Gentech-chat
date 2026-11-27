// Copyright (c) 2026 Minkail. All rights reserved.
//
// G1-video-player: именованные виджет-тесты единого видеоплеера
// (lib/widgets/video_player_card.dart).
//
// Платформенная реализация video_player подменяется фейком
// (_FakeVideoPlatform extends VideoPlayerPlatform): initialize()
// высылает событие initialized (длительность 30 с), play/pause/seekTo
// записываются и проверяются. Скачивание проверяется через
// path_provider-мок и реальную запись в temp-каталог; шеринг — через
// подмену хука shareFilesHook.
//
//  - G1-T-VIDEO-PLAY-PAUSE: тап по видео — играет, повторный тап — пауза;
//  - G1-T-VIDEO-REPLAY: после конца видео тап повторяет с начала;
//  - G1-T-VIDEO-FULLSCREEN: кнопка «На весь экран» открывает полноэкранный плеер;
//  - G1-T-VIDEO-DOWNLOAD: «Скачать» сохраняет файл и подтверждает;
//  - G1-T-VIDEO-SHARE: «Поделиться» шэрит локальный файл (замокано);
//  - G1-T-GALLERY-VIDEO-OPENS-PLAYER: видео из галереи открывает тот же плеер.
//
// G1-video-player-heal1: добавлен import 'dart:async' (StreamController
// живёт в dart:async); снят const с vpi.VideoEvent(...) — у VideoEvent
// в video_player_platform_interface НЕ const-конструктор; buildView
// возвращает const ColoredBox (prefer_const_constructors); снят const
// с ChatMessage в тесте галереи — у ChatMessage нет const-конструктора
// (мутабельные поля, см. эталонные тесты f5_gallery_media_test.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart' show XFile;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as vpi;

import 'package:gentech_chat/app_state.dart';
import 'package:gentech_chat/core/models/message_part.dart';
import 'package:gentech_chat/features/gallery/artifacts_gallery_screen.dart';
import 'package:gentech_chat/models/chat_message.dart';
import 'package:gentech_chat/widgets/video_player_card.dart';

/// Фейк платформы video_player: создает "плеер" и высылает событие
/// initialized (30 с, 640x360). Все методы play/pause/seekTo/... —
/// no-op с записью вызовов. buildView рисует чёрный прямоугольник
/// вместо нативной текстуры.
class _FakeVideoPlatform extends vpi.VideoPlayerPlatform {
  final List<String> calls = <String>[];
  final Map<int, StreamController<vpi.VideoEvent>> _events =
      <int, StreamController<vpi.VideoEvent>>{};
  int _nextPlayerId = 0;
  Duration _position = Duration.zero;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(vpi.DataSource dataSource) async {
    calls.add('create');
    final id = _nextPlayerId;
    _nextPlayerId++;
    return id;
  }

  @override
  Stream<vpi.VideoEvent> videoEventsFor(int playerId) {
    final controller = StreamController<vpi.VideoEvent>();
    _events[playerId] = controller;
    // VideoEvent — не const-конструктор (video_player_platform_interface).
    controller.add(vpi.VideoEvent(
      eventType: vpi.VideoEventType.initialized,
      duration: Duration(seconds: 30),
      size: Size(640, 360),
    ));
    return controller.stream;
  }

  /// Платформа сообщает «воспроизведение дошло до конца».
  void complete(int playerId) {
    _events[playerId]?.add(vpi.VideoEvent(
      eventType: vpi.VideoEventType.completed,
    ));
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seekTo:${position.inMilliseconds}');
    _position = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async => _position;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    final c = _events.remove(playerId);
    await c?.close();
  }

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: child),
    ),
  );
}

/// Прокачивает плеер до инициализированного состояния (фейковая
/// платформа отвечает мгновенно, достаточно двух pump).
Future<void> _pumpReady(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(_host(child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Разбирает дерево в конце теста: отменяет таймеры плеера и snack-баров.
Future<void> _tearDownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 50));
}

Directory? _tempDir;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _tempDir = await Directory.systemTemp.createTemp('g1_video_player');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => _tempDir!.path,
    );
  });

  tearDown(() async {
    try {
      await _tempDir?.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets(
    'G1-T-VIDEO-PLAY-PAUSE: тап по видео запускает воспроизведение, '
    'повторный тап ставит на паузу — нет «мёртвой» кнопки play',
    (tester) async {
      final fake = _FakeVideoPlatform();
      vpi.VideoPlayerPlatform.instance = fake;

      await _pumpReady(
        tester,
        const VideoPlayerCard(source: 'https://fixture.example/g1.mp4'),
      );

      // Плеер инициализирован, платформа создала видеоплеер.
      expect(fake.calls, contains('create'));
      // До тапа видео стоит: иконка play.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      // Тап по видео — воспроизведение.
      await tester.tap(find.byKey(const ValueKey('g1_video_tap_area')));
      await tester.pump();
      expect(fake.calls, contains('play'),
          reason: 'тап по видео обязан запустить платформенный play');
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget,
          reason: 'во время воспроизведения видна иконка паузы');

      // Повторный тап — пауза (без «второго тапа — стоп»).
      await tester.tap(find.byKey(const ValueKey('g1_video_tap_area')));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget,
          reason: 'на паузе снова видна иконка play');

      await _tearDownTree(tester);
    },
  );

  testWidgets(
    'G1-T-VIDEO-REPLAY: после конца видео кнопка повтора запускает '
    'воспроизведение с начала (seekTo(0) + play)',
    (tester) async {
      final fake = _FakeVideoPlatform();
      vpi.VideoPlayerPlatform.instance = fake;

      await _pumpReady(
        tester,
        const VideoPlayerCard(source: 'https://fixture.example/g1.mp4'),
      );

      // Платформа сообщает: воспроизведение дошло до конца.
      fake.complete(0);
      await tester.pump();
      expect(find.byIcon(Icons.replay_rounded), findsOneWidget,
          reason: 'после конца видео предлагается повтор');

      // Тап по видео — повтор с начала, а не «второй тап — стоп».
      await tester.tap(find.byKey(const ValueKey('g1_video_tap_area')));
      await tester.pump();
      expect(fake.calls, contains('seekTo:0'),
          reason: 'повтор обязан перематывать в начало');
      expect(fake.calls, contains('play'),
          reason: 'повтор обязан запускать воспроизведение');

      await _tearDownTree(tester);
    },
  );

  testWidgets(
    'G1-T-VIDEO-FULLSCREEN: кнопка «На весь экран» открывает '
    'полноэкранный плеер с автоплеем',
    (tester) async {
      final fake = _FakeVideoPlatform();
      vpi.VideoPlayerPlatform.instance = fake;

      await _pumpReady(
        tester,
        const VideoPlayerCard(source: 'https://fixture.example/g1.mp4'),
      );
      final playsBefore = fake.calls.where((c) => c == 'play').length;

      await tester.tap(find.byTooltip('На весь экран'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('g1_fullscreen_video')), findsOneWidget,
          reason: 'полноэкранный плеер открыт');
      expect(find.byType(VideoPlayerCard), findsNWidgets(2),
          reason: 'в полном экране — тот же единый плеер, а не вторая '
              'реализация');
      expect(
        fake.calls.where((c) => c == 'play').length,
        greaterThan(playsBefore),
        reason: 'в полном экране видео запускается автоматически',
      );

      await _tearDownTree(tester);
    },
  );

  testWidgets(
    'G1-T-VIDEO-DOWNLOAD: «Скачать» сохраняет видеофайл на устройство '
    'и показывает подтверждение',
    (tester) async {
      final fake = _FakeVideoPlatform();
      vpi.VideoPlayerPlatform.instance = fake;

      final srcDir = Directory('${_tempDir!.path}/src')
        ..createSync(recursive: true);
      final src = File('${srcDir.path}/vid_source.mp4');
      src.writeAsBytesSync(List<int>.filled(160, 7));

      final dlDir = Directory('${_tempDir!.path}/downloads')
        ..createSync(recursive: true);
      // getDownloadsDirectory возвращает каталог загрузок теста.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async =>
            call.method == 'getDownloadsDirectory' ? dlDir.path : _tempDir!.path,
      );

      await _pumpReady(
        tester,
        VideoPlayerCard(source: src.path),
      );

      await tester.tap(find.byTooltip('Скачать'));
      await tester.pump();
      // Видимое состояние: сохранение идёт.
      expect(find.text('Сохранение видео…'), findsOneWidget);

      // Разрешаем реальному вводу-выводу завершиться.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      // Подтверждение с именем файла.
      expect(find.textContaining('Видео сохранено'), findsOneWidget);
      // Файл действительно записан в каталог загрузок.
      final saved =
          dlDir.listSync().whereType<File>().toList();
      expect(saved, hasLength(1),
          reason: 'видеофайл записан в Downloads');
      expect(saved.single.path, endsWith('.mp4'));

      await _tearDownTree(tester);
    },
  );

  testWidgets(
    'G1-T-VIDEO-SHARE: «Поделиться» открывает системный шаринг '
    'с файлом (замокано)',
    (tester) async {
      final fake = _FakeVideoPlatform();
      vpi.VideoPlayerPlatform.instance = fake;

      final srcDir = Directory('${_tempDir!.path}/src')
        ..createSync(recursive: true);
      final src = File('${srcDir.path}/vid_source.mp4');
      src.writeAsBytesSync(List<int>.filled(128, 7));

      List<XFile>? shared;
      shareFilesHook = (files) async {
        shared = files;
      };
      addTearDown(() => shareFilesHook = shareViaSharePlus);

      await _pumpReady(
        tester,
        VideoPlayerCard(source: src.path),
      );

      await tester.tap(find.byTooltip('Поделиться'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(shared, isNotNull,
          reason: 'тап «Поделиться» обязан вызвать системный шаринг');
      expect(shared!.length, 1);
      expect(shared!.single.path, src.path,
          reason: 'шарится сам видеофайл');

      await _tearDownTree(tester);
    },
  );

  testWidgets(
    'G1-T-GALLERY-VIDEO-OPENS-PLAYER: видео в галерее открывает тот же '
    'плеер с воспроизведением, скачиванием и шарингом',
    (tester) async {
      final fake = _FakeVideoPlatform();
      vpi.VideoPlayerPlatform.instance = fake;

      final chat = store.createChat();
      chat.title = 'Видео';
      // ChatMessage не имеет const-конструктора (мутабельные поля) —
      // эталон f5_gallery_media_test.dart; внутренняя VideoPart — const.
      chat.messages.add(ChatMessage(
        id: 'g1-msg',
        role: 'assistant',
        parts: <MessagePart>[
          const VideoPart.fromUrl('https://cdn.example.com/g1.mp4'),
        ],
      ));

      await tester.pumpWidget(const MaterialApp(
        home: ArtifactsGalleryScreen(),
      ));
      await tester.pump();

      // Плитка видео видна и открывает плеер по тапу.
      expect(find.text('g1.mp4'), findsOneWidget);
      await tester.tap(find.text('g1.mp4'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('g1_fullscreen_video')), findsOneWidget,
          reason: 'видео из галереи открывает полноэкранный плеер');
      expect(find.byType(VideoPlayerCard), findsOneWidget);
      // Плеер в галерее тот же: автоплей, скачивание и шаринг доступны.
      expect(fake.calls, contains('play'),
          reason: 'видео в галерее воспроизводится');
      expect(find.byTooltip('Скачать'), findsOneWidget,
          reason: 'скачивание доступно из полноэкранного плеера');
      expect(find.byTooltip('Поделиться'), findsOneWidget,
          reason: 'шаринг доступен из полноэкранного плеера');

      // Плитка видео не является мёртвой статичной карточкой.
      await _tearDownTree(tester);
      store.chats.clear();
      store.current = null;
    },
  );
}
