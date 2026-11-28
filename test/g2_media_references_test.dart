// Copyright (c) 2026 Minkail. All rights reserved.
//
// G2-media-references: именованные тесты референсов медиа-моделей.
//
// Трассируемый путь UI -> сервис -> исполнитель -> API:
//  1. Скрепка в медиа-композере видна/скрыта строго по каталогу
//     (ActiveModelCapabilities.maxReferenceImages из CatalogEntry);
//  2. Полоса миниатюр референсов: удаление по кнопке, счётчик «N / max»,
//     отбор файлов по типу (jpg/jpeg/png/webp) и лимиту каталога;
//  3. ParameterTranslator: images из параметров запроса попадают в
//     input тела POST /v1/media как список строк (URL / data-URI).
//
// google_fonts в тестах без сети: allowRuntimeFetching = false (см.
// комментарий в test/g1_video_player_test.dart).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gentech_chat/core/generation/model_type_override_store.dart'
    show ModelTypes;
import 'package:gentech_chat/core/generation/parameter_translator.dart';
import 'package:gentech_chat/core/models/active_model_capabilities.dart';
import 'package:gentech_chat/features/composer/adaptive_chat_input_bar.dart';
import 'package:gentech_chat/models/attachment_draft.dart';
import 'package:gentech_chat/models/model_config.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

/// Медиа-модель с референсами из каталога (как grok-imagine-video-1-5:
/// параметр images, min 0, max 7).
const ActiveModelCapabilities _capsWithRefs = ActiveModelCapabilities(
  modelId: 'grok-imagine-video-1-5',
  normalizedId: 'grok-imagine-video-1-5',
  kind: ActiveModelKind.video,
  maxReferenceImages: 7,
);

/// Медиа-модель без лимита референсов в каталоге.
const ActiveModelCapabilities _capsNoRefs = ActiveModelCapabilities(
  modelId: 'video-without-refs',
  normalizedId: 'video-without-refs',
  kind: ActiveModelKind.video,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // google_fonts в виджет-тестах не ходит в сеть: fontStyle возвращает
  // plain TextStyle (см. комментарий в test/g1_video_player_test.dart).
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('G2-T-CAPS: supportsReferenceImages определяется каталогом', () {
    expect(_capsWithRefs.maxReferenceImages, 7);
    expect(_capsWithRefs.supportsReferenceImages, isTrue);
    expect(_capsNoRefs.maxReferenceImages, isNull);
    expect(_capsNoRefs.supportsReferenceImages, isFalse);
  });

  testWidgets(
    'G2-T-ATTACH-VISIBLE-WHEN-SUPPORTED: у медиа-модели с '
    'maxReferenceImages: 7 в медиа-композере видна скрепка',
    (tester) async {
      await tester.pumpWidget(_host(
        const AdaptiveChatInputBar(
          config: TextModelConfig(),
          capabilities: _capsWithRefs,
          modelType: ModelTypes.video,
        ),
      ));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('g2_media_attach')),
        findsOneWidget,
        reason: 'каталог разрешил 7 референсов — скрепка должна быть видна',
      );
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
    },
  );

  testWidgets(
    'G2-T-ATTACH-HIDDEN-WHEN-UNSUPPORTED: у медиа-модели без '
    'maxReferenceImages скрепки в медиа-композере нет',
    (tester) async {
      await tester.pumpWidget(_host(
        const AdaptiveChatInputBar(
          config: TextModelConfig(),
          capabilities: _capsNoRefs,
          modelType: ModelTypes.video,
        ),
      ));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('g2_media_attach')),
        findsNothing,
        reason: 'каталог не сообщил лимит — скрепка скрыта',
      );
      expect(find.byIcon(Icons.attach_file), findsNothing);
    },
  );

  testWidgets(
    'G2-T-LIMIT-AND-STRIP: миниатюры референсов с удалением и '
    'счётчиком «N / max»; свыше лимита файлы не добавляются',
    (tester) async {
      // G2-fix-analyze-heal1: createTempSync вместо `await createTemp`.
      // В testWidgets тело выполняется в fake-async зоне: настоящий
      // dart:io I/O завершается только через реальный event loop,
      // к которому тело не возвращается, поэтому `await createTemp`
      // никогда не разрешался — тест висел до TimeoutException
      // (10 минут). Синхронный вызов fake-async не перехватывает.
      final dir = Directory.systemTemp.createTempSync('g2_refs');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final refs = <AttachmentDraft>[
        for (var i = 0; i < 7; i++)
          AttachmentDraft(
            file: File('${dir.path}/ref_$i.png')
              ..writeAsBytesSync(<int>[1, 2, 3, i]),
            status: AttachmentStatus.ready,
          ),
      ];

      var removedAt = -1;
      await tester.pumpWidget(_host(
        AdaptiveChatInputBar(
          config: const TextModelConfig(),
          capabilities: _capsWithRefs,
          modelType: ModelTypes.video,
          mediaAttachments: refs,
          onRemoveMediaAttachment: (i) => removedAt = i,
        ),
      ));
      await tester.pump();

      // Счётчик лимита и семь миниатюр с кнопками удаления.
      expect(find.text('7 / 7'), findsOneWidget,
          reason: 'счётчик «N / max» виден над полем ввода');
      expect(find.byIcon(Icons.close_rounded), findsNWidgets(7),
          reason: 'у каждой миниатюры есть кнопка удаления');

      // Удаление: тап по кнопке первой миниатюры снимает референс.
      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pump();
      expect(removedAt, 0,
          reason: 'удаление миниатюры сообщает индекс наверх');

      // Отбор файлов НЕ добавляет свыше лимита: 9 изображений при
      // max 7 — 7 принимаются, 2 лишних отклоняются.
      final over = selectMediaReferenceFiles(
        paths: <String>[for (var i = 0; i < 9; i++) 'pick_$i.png'],
        currentCount: 0,
        maxReferenceImages: 7,
      );
      expect(over.accepted, hasLength(7));
      expect(over.rejectedOverLimit, 2);

      // Лимит исчерпан до отбора: ничего не добавляется — UI покажет
      // «Максимум референсов для этой модели: 7».
      final full = selectMediaReferenceFiles(
        paths: const <String>['one_more.png'],
        currentCount: 7,
        maxReferenceImages: 7,
      );
      expect(full.accepted, isEmpty);
      expect(full.limitAlreadyReached, isTrue);

      // Типы: только jpg/jpeg/png/webp; txt/mp4 отклоняются.
      final typed = selectMediaReferenceFiles(
        paths: const <String>['a.png', 'b.JPG', 'note.txt', 'clip.mp4'],
        currentCount: 0,
        maxReferenceImages: 7,
      );
      expect(typed.accepted, <String>['a.png', 'b.JPG']);
      expect(typed.rejectedWrongType, 2);
    },
  );

  test(
    'G2-T-TRANSLATOR-IMAGES-IN-MEDIA-INPUT: images уходят в input '
    'тела POST /v1/media',
    () {
      const images = <String>[
        'data:image/jpeg;base64,AAA',
        'data:image/png;base64,BBB',
      ];
      final out = ParameterTranslator.toPolzaMediaInput(
        'портрет кота',
        <String, dynamic>{
          'aspect_ratio': '16:9',
          'images': images,
        },
        isVideo: true,
      );
      expect(out['prompt'], 'портрет кота');
      expect(out['aspect_ratio'], '16:9');
      expect(out['images'], images,
          reason: 'референсы обязаны присутствовать в input.images');

      // Лимит каталога (если он задан исполнителю) обрезает список.
      final truncated = ParameterTranslator.toPolzaMediaInput(
        'промпт',
        <String, dynamic>{
          'images': <String>[
            for (var i = 0; i < 9; i++) 'data:image/png;base64,IMG$i',
          ],
        },
        isVideo: false,
        maxReferenceImages: 7,
      );
      expect(truncated['images'], hasLength(7));

      // Референсов нет — ключа images в input нет.
      final absent = ParameterTranslator.toPolzaMediaInput(
        'промпт',
        <String, dynamic>{},
      );
      expect(absent.containsKey('images'), isFalse);
    },
  );

  test('G2-T-DATAURI: файл референса кодируется в data:image/...;base64',
      () async {
    final dir = await Directory.systemTemp.createTemp('g2_datauri');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final bytes = <int>[1, 2, 3, 4, 5];
    final png = File('${dir.path}/ref.png')..writeAsBytesSync(bytes);
    final uri = await mediaReferenceDataUri(png);
    expect(uri, startsWith('data:image/png;base64,'));
    final payload =
        (uri ?? '').substring('data:image/png;base64,'.length);
    expect(base64Decode(payload).toList(), bytes);

    // Не-изображение референсом не является.
    final txt = File('${dir.path}/note.txt')..writeAsStringSync('x');
    expect(await mediaReferenceDataUri(txt), isNull);
  });
}
