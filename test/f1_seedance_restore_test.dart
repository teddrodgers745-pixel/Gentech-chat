// Copyright (c) 2026 Minkail. All rights reserved.
//
// F1-seedance-restore: именованные тесты исправления «0% вместо
// "в процессе…"» и «потеря задачи после убийства приложения».
//
// F1-T-SEEDANCE-NO-ZERO-PERCENT: провайдер (живой локальный сервер)
// отвечает status=processing, progress=0 — исполнитель обязан отдать
// GenProgress с indeterminate=true; ни одно событие прогресса не
// показывает числовой процент без реальных данных сервера.
//
// F1-T-SEEDANCE-PENDING-SERIALIZATION: PendingPart с jobId и
// indeterminate переживает round-trip ChatMessage.toJson/fromJson —
// карточка «Генерация видео» восстанавливается после перезапуска
// приложения (дыра «у PendingPart нет сериализации» закрыта проверкой).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gentech_chat/core/generation/generation_event.dart';
import 'package:gentech_chat/core/generation/generation_request.dart';
import 'package:gentech_chat/core/generation/generation_service.dart';
import 'package:gentech_chat/core/generation/model_type_override_store.dart'
    show ModelTypes;
import 'package:gentech_chat/core/models/message_part.dart';
import 'package:gentech_chat/models/chat_message.dart';

/// HttpOverrides зоны с живым локальным HttpServer: каждый HttpClient()
/// внутри зоны получает собственный настоящий клиент через базовую
/// реализацию dart:io (см. подробное обоснование в f1_retry_resume_test.dart).
class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('f1_seedance_restore');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (call) async => tempDir.path,
    );
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'F1-T-SEEDANCE-NO-ZERO-PERCENT: processing с progress: 0 — '
    'GenProgress indeterminate, ни одного «0%» без indeterminate',
    () async {
      await HttpOverrides.runWithHttpOverrides<Future<void>>(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final base = 'http://127.0.0.1:${server.port}';
        var polls = 0;
        server.listen((request) async {
          if (request.method == 'POST') {
            await utf8.decoder.bind(request).join();
            request.response.write(jsonEncode(<String, dynamic>{
              'id': 'job-seed-1',
              'status': 'queued',
            }));
            await request.response.close();
            return;
          }
          polls++;
          request.response.headers.contentType =
              ContentType('application', 'json');
          if (polls == 1) {
            // Точный сценарий живого лога: провайдер отдаёт 0,
            // пока задача в processing.
            request.response.write(jsonEncode(<String, dynamic>{
              'status': 'processing',
              'progress': 0,
            }));
          } else {
            request.response.write(jsonEncode(<String, dynamic>{
              'status': 'completed',
              'data': <String, dynamic>{'url': '$base/video.mp4'},
            }));
          }
          await request.response.close();
        });

        try {
          final events = <GenerationEvent>[];
          final service = GenerationService();
          await for (final ev in service.generate(GenerationRequest(
            baseUrl: base,
            apiKey: 'fixture-key',
            model: 'bytedance/seedance-2-mini',
            messages: <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'тестовое видео'},
            ],
            stream: false,
            parameters: const <String, dynamic>{},
            routeHint: ModelTypes.video,
          ))) {
            events.add(ev);
          }

          final progress = events.whereType<GenProgress>().toList();
          expect(progress, isNotEmpty);
          // Первый прогресс после создания задачи — неопределённый
          // («в процессе…»), а не фиктивный процент.
          expect(progress.first.indeterminate, isTrue);
          // Числовой процент без indeterminate допустим ТОЛЬКО при
          // реальных данных сервера (percent > 0); сценарий «0%» и
          // «синтетический процент как будто от сервера» исключены.
          for (final p in progress) {
            if (!p.indeterminate) {
              expect(p.percent, greaterThan(0),
                  reason: 'показ процента без indeterminate разрешён '
                      'только при реальном прогрессе сервера > 0');
            }
          }
          expect(
            events.whereType<GenCompleted>(),
            isNotEmpty,
            reason: 'задача доводится до готового видео',
          );
        } finally {
          await server.close(force: true);
        }
      }, _RealHttpOverrides());
    },
    // Один цикл опроса ~5 секунд плюс загрузка видео: запас на CI.
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'F1-T-SEEDANCE-PENDING-SERIALIZATION: PendingPart с jobId и '
    'indeterminate переживает round-trip ChatMessage.toJson/fromJson',
    () {
      final msg = ChatMessage(
        id: 'seed-msg',
        role: 'assistant',
        parts: <MessagePart>[
          PendingPart(
            name: 'Генерация видео',
            jobId: 'gen_2237626207858462721',
            indeterminate: true,
          ),
        ],
      );

      final restored = ChatMessage.fromJson(
        Map<String, dynamic>.from(msg.toJson()),
      );

      final part = restored.parts.whereType<PendingPart>().single;
      expect(part.name, 'Генерация видео');
      expect(part.jobId, 'gen_2237626207858462721',
          reason: 'jobId обязателен для возобновления опроса '
              'restorePendingJobs/resumeJob');
      expect(part.indeterminate, isTrue,
          reason: 'карточка после перезапуска показывает «в процессе…», '
              'а не 0%');
    },
  );
}
