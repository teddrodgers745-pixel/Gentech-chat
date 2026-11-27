// Copyright (c) 2026 Minkail. All rights reserved.
//
// F1-retry-resume: повтор после сетевой ошибки ОПРОСА возобновляет
// ТУ ЖЕ задачу (тот же jobId) — без нового POST /v1/media и без новой
// резервации. Запись задачи переживает сетевую ошибку (не удаляется
// из ActiveJobsStore) и подхватывается restorePendingJobs/resumeJob.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gentech_chat/core/generation/active_jobs_store.dart';
import 'package:gentech_chat/core/generation/generation_event.dart';
import 'package:gentech_chat/core/generation/generation_request.dart';
import 'package:gentech_chat/core/generation/generation_service.dart';
import 'package:gentech_chat/core/generation/media_status_poller.dart';
import 'package:gentech_chat/core/generation/model_type_override_store.dart'
    show ModelTypes;
import 'package:gentech_chat/core/models/gen_error.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tempDir = await Directory.systemTemp.createTemp('f1_retry_resume');
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
    'F1-T-RESUME-SAME-JOB: повтор возобновляет тот же jobId '
    'БЕЗ нового POST /media (без новой резервации)',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      var createPosts = 0;
      var pollGets = 0;

      server.listen((request) async {
        final path = request.uri.path;
        if (request.method == 'POST') {
          // Создание новой задачи (в этой проверке его быть НЕ должно).
          createPosts++;
          await utf8.decoder.bind(request).join();
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': 'job-f1-77',
              'status': 'queued',
            }),
          );
          await request.response.close();
          return;
        }
        if (path == '/media/job-f1-77') {
          // Опрос ТОЙ ЖЕ задачи: только GET, никаких повторных созданий.
          pollGets++;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'status': 'completed',
              'data': <String, dynamic>{
                'url': '$base/video.mp4',
              },
            }),
          );
          await request.response.close();
          return;
        }
        if (path == '/video.mp4') {
          request.response.headers.contentType = ContentType.binary;
          request.response.add(List<int>.filled(64, 7));
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });

      try {
        // Задача «уже создана раньше»: запись живёт в ActiveJobsStore
        // (сеть оборвалась во время ОПРОСА, запись не удалялась).
        await ActiveJobsStore.instance.save(AsyncJobRecord(
          jobId: 'job-f1-77',
          baseUrl: base,
          apiKey: 'fixture-key',
          model: 'polza-test/seedance-480p',
          prompt: 'тестовое видео',
        ));

        final events = <GenerationEvent>[];
        final service = GenerationService();
        await for (final ev in service.resumeJob(
          'job-f1-77',
          baseUrl: base,
          apiKey: 'fixture-key',
          model: 'polza-test/seedance-480p',
          prompt: 'тестовое видео',
        )) {
          events.add(ev);
        }

        // Новая задача НЕ создаётся: POST /media не выполнялся вовсе,
        // повторного списания нет.
        expect(
          createPosts,
          0,
          reason: 'повтор после сетевой ошибки не должен делать POST /media',
        );
        // Опрос идёт по ТОМУ ЖЕ jobId.
        expect(pollGets, greaterThan(0));
        final progress = events.whereType<GenProgress>().toList();
        expect(progress, isNotEmpty);
        expect(progress.first.jobId, 'job-f1-77');
        // Задача завершается тем же jobId (видео материализовано/ссылка).
        final completed = events.whereType<GenCompleted>().toList();
        expect(completed, isNotEmpty);
        expect(completed.first.jobId, 'job-f1-77');
        // После завершения запись убрана из хранилища.
        final jobsAfter = await ActiveJobsStore.instance.loadAll();
        expect(jobsAfter.any((j) => j.jobId == 'job-f1-77'), isFalse);
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'F1-T-NETWORK-POLL-KEEPS-RECORD: сетевая ошибка опроса -> '
    'JobStatusUnknown с jobId, запись жива в ActiveJobsStore',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      var createPosts = 0;
      final created = Completer<void>();
      StreamSubscription<GenerationEvent>? sub;

      server.listen((request) async {
        if (request.method == 'POST') {
          createPosts++;
          await utf8.decoder.bind(request).join();
          request.response.write(
            jsonEncode(<String, dynamic>{
              'id': 'job-f1-88',
              'status': 'queued',
            }),
          );
          await request.response.close();
          if (!created.isCompleted) created.complete();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });

      final events = <GenerationEvent>[];
      final service = GenerationService();
      final done = Completer<void>();
      try {
        sub = service.generate(GenerationRequest(
          baseUrl: base,
          apiKey: 'fixture-key',
          model: 'polza-test/seedance-480p',
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'тестовое видео'},
          ],
          stream: false,
          parameters: const <String, dynamic>{},
          routeHint: ModelTypes.video,
        )).listen(
          events.add,
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
        );

        // Задача создана на сервере (ровно ОДИН POST), после чего
        // «рвётся сеть»: опрос больше не достукивается до провайдера
        // (DNS-подобный сбой — сервер недоступен).
        await created.future;
        await server.close(force: true);

        // Транзиентные повторы: пауза 2/4/6 секунды перед сдачей.
        await done.future.timeout(const Duration(seconds: 90), onTimeout: () {});

        expect(
          createPosts,
          1,
          reason: 'ровно одна задача создана — двойной оплаты нет',
        );
        final failures = events.whereType<GenerationFailure>().toList();
        expect(failures, hasLength(1));
        final failure = failures.single;
        // Ошибка типизирована: задача ЖИВА у провайдера, «Повторить»
        // продолжит опрос той же задачи.
        expect(failure.error, isA<JobStatusUnknown>());
        expect(failure.jobId, 'job-f1-88');
        // Запись задачи ПЕРЕЖИЛА сетевую ошибку: не удалена из
        // ActiveJobsStore — восстановится и повтором (resumeJob),
        // и после перезапуска приложения (restorePendingJobs).
        final jobs = await ActiveJobsStore.instance.loadAll();
        expect(jobs.any((j) => j.jobId == 'job-f1-88'), isTrue);

        // Повтор по сохранённому jobId не создаёт новую задачу.
        final server2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final base2 = 'http://127.0.0.1:${server2.port}';
        var createPosts2 = 0;
        server2.listen((request) async {
          if (request.method == 'POST') {
            createPosts2++;
            await utf8.decoder.bind(request).join();
          }
          request.response.write(
            jsonEncode(<String, dynamic>{
              'status': 'completed',
              'data': <String, dynamic>{
                'url': '$base2/video.mp4',
              },
            }),
          );
          await request.response.close();
        });
        try {
          final events2 = <GenerationEvent>[];
          final service2 = GenerationService();
          await for (final ev in service2.resumeJob(
            'job-f1-88',
            baseUrl: base,
            apiKey: 'fixture-key',
            model: 'polza-test/seedance-480p',
            prompt: 'тестовое видео',
          )) {
            events2.add(ev);
          }
          expect(createPosts2, 0,
              reason: 'повтор не должен создавать новую задачу');
          expect(
            events2.whereType<GenProgress>().any((e) => e.jobId == 'job-f1-88'),
            isTrue,
          );
        } finally {
          await server2.close(force: true);
        }
      } finally {
        await sub?.cancel();
      }
    },
  );

  test(
    'F1-T-POLLER-TRANSIENT-RETRIES: сетевые сбои опроса '
    'переживаются БЕЗ создания новой задачи',
    () async {
      var calls = 0;
      final poller = MediaStatusPoller<String>(
        interval: const Duration(milliseconds: 1),
        maxAttempts: 3,
        maxTransientRetries: 2,
        transientBackoffBase: const Duration(milliseconds: 1),
        isCancelled: () => false,
      );
      final events = <String>[];
      // Каркас опроса сам НЕ останавливает стрим после успешной попытки:
      // «ещё выполняется» — тоже результат попытки, и опрос продолжается
      // до maxAttempts. Останавливать опрос обязан вызывающий код (как
      // AsyncJobExecutor._watch / ImagesApiExecutor._pollMediaState —
      // по готовому URL или фатальному коду); иначе первый же ответ
      // «в процессе» обрывал бы опрос, и живая задача умирала бы с
      // JobTimeout. Поэтому стрим потребляется как в исполнителе:
      // первый готовый ответ — остановка опроса.
      await for (final res in poller.poll((attempt) async {
        calls++;
        if (calls <= 2) {
          // Транзиентный сетевой сбой (DNS/обрыв): задача жива,
          // повторять надо ОПРОС, а не создавать новую задачу.
          throw const PollTransientFailure("Failed host lookup: 'polza.ai'");
        }
        return 'done-$attempt';
      })) {
        events.add(res);
        break;
      }

      // Оба сбоя пережиты ВНУТРИ первой логической попытки:
      // задача не пересоздавалась (номер попытки остался 1),
      // опрос дошёл до ответа.
      expect(events, <String>['done-1']);
      expect(calls, 3);

      // Исчерпание транзиентных повторов -> PollTransientFailure наружу:
      // исполнитель обязан отдать JobStatusUnknown и СОХРАНИТЬ запись
      // задачи (никаких новых POST /v1/media).
      var hardCalls = 0;
      final hardPoller = MediaStatusPoller<String>(
        interval: const Duration(milliseconds: 1),
        maxAttempts: 3,
        maxTransientRetries: 1,
        transientBackoffBase: const Duration(milliseconds: 1),
        isCancelled: () => false,
      );
      await expectLater(
        hardPoller.poll((attempt) async {
          hardCalls++;
          throw const PollTransientFailure('network down');
        }).toList(),
        throwsA(isA<PollTransientFailure>()),
      );
      expect(hardCalls, 2);
    },
  );

  test(
    'F1-T-CARD-TEXT: карточка сетевой ошибки опроса говорит '
    '«задача жива, повтор без нового списания»',
    () {
      const err = JobStatusUnknown(jobId: 'job-f1-88', details: 'dns');
      // Транзиентная сетевая ошибка отличается от провала задачи:
      // карточка обязана говорить, что задача продолжает выполняться
      // у провайдера, а повтор не списывает заново.
      expect(err.code, 'status_unknown');
      expect(err.message, contains('продолжает выполняться'));
      expect(err.message, contains('без нового списания'));
    },
  );
}
