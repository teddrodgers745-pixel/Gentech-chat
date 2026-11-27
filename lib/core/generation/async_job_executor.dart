// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';

import '../../app_state.dart' show settings;
import '../models/gen_error.dart';
import '../models/gen_error_mapper.dart';
import '../models/model_info.dart' show GenerationRoute, Modality;
import '../providers/model_catalog_adapter.dart';
import '../providers/model_info_resolver.dart';
import 'active_jobs_store.dart';
import 'artifact_materializer.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';
import 'media_status_poller.dart';
import 'parameter_translator.dart';
import 'parameter_validation_exception.dart';

/// Результат одного опроса состояния задачи.
class _PollResult {
  final String videoUrl;
  final double? percent;

  /// Сервер сообщил «в процессе» без числового прогресса (не прислал
  /// процент вовсе либо прислал <= 0). true — интерфейс показывает
  /// неопределённую индикацию «в процессе…», а не выдуманные проценты
  /// (F1-seedance-restore).
  final bool indeterminate;
  final GenError? fatal;

  const _PollResult({
    this.videoUrl = '',
    this.percent,
    this.indeterminate = false,
    this.fatal,
  });

  bool get isFatal => fatal != null;
  bool get isDone => videoUrl.isNotEmpty;
}

/// Результат публичного опроса медиа-задачи (модель-инструмент):
/// ссылка готова либо задача ещё выполняется.
class _PublicJobPoll {
  /// Готовая ссылка на медиа ('' — задача ещё выполняется).
  final String url;

  /// Текстовый статус для колбэка прогресса.
  final String statusText;

  const _PublicJobPoll({this.url = '', this.statusText = 'processing'});

  bool get isDone => url.isNotEmpty;
}

/// Результат создания задачи.
class _CreateResult {
  final AsyncJobRecord? record;

  /// Провайдер иногда отдаёт готовое видео сразу — тогда опрос не нужен.
  final String directUrl;

  const _CreateResult({this.record, this.directUrl = ''});
}

/// Исполнитель асинхронных видео-задач (kling, veo, sora, wan ...).
///
/// Схема Polza Media API:
///  1. POST {baseUrl}/media с телом {model, input: {...}, async: true};
///  2. При готовом результате сразу скачиваем его;
///  3. Иначе опрашиваем GET {baseUrl}/media/{id} каждые 5 секунд.
/// Для Polza запасные REST-эндпоинты не используются.
///
/// Циклы опроса (внутренний [_watch] и публичный [pollMediaJob]) выполняются
/// общим каркасом [MediaStatusPoller] — единым с исполнителем изображений
/// (R6-audio-robustness-3, п.8); HTTP-коды сводятся к общей типизированной
/// функции GenErrorMapper.fromStatusCode (расхождение 403/402 устранено).
///
/// F1-retry-resume: сетевая ошибка ОПРОСА (DNS/таймаут/обрыв) не убивает
/// задачу — запись остаётся в [ActiveJobsStore], событие ошибки несёт
/// jobId как [JobStatusUnknown], и «Повторить» продолжает опрос ТОЙ ЖЕ
/// задачи без нового POST /media и без новой резервации.
class AsyncJobExecutor extends GenerationExecutor {
  static const Duration _pollInterval = Duration(seconds: 5);
  static const int _maxAttempts = 150;
  static const Duration _requestTimeout = Duration(seconds: 60);

  /// Сколько раз повторить опрос при транзиентной сетевой ошибке,
  /// прежде чем признать статус задачи неизвестным.
  static const int _maxTransientRetries = 3;
  static const Duration _transientBackoffBase = Duration(seconds: 2);

  /// Пути создания задачи для провайдеров, отличных от Polza.
  static const List<String> _createPaths = <String>[
    '/media',
    '/v1/media',
    '/videos/generations',
    '/generations',
    '/videos',
  ];

  /// Пути опроса для провайдеров, отличных от Polza.
  static const List<String> _pollPrefixes = <String>[
    '/media/',
    '/v1/media/',
    '/videos/',
    '/generations/',
    '/jobs/',
  ];

  static const Set<String> _doneStatuses = <String>{
    'completed', 'succeeded', 'success', 'succeed', 'complete', 'done',
    'finished', 'ok',
  };
  static const Set<String> _failedStatuses = <String>{
    'failed', 'failure', 'error', 'canceled', 'cancelled', 'rejected',
    'expired',
  };

  /// Статусы «задача ещё выполняется»: при отсутствии явного прогресса
  /// для них генерируется плавный процент по попыткам/времени.
  static const Set<String> _runningStatuses = <String>{
    'pending', 'processing', 'queued', 'starting', 'in_progress', 'running',
    'created', 'submitted', 'generating', 'modifying', 'started',
  };

  /// Активные исполнители по jobId — для отмены из интерфейса.
  static final Map<String, AsyncJobExecutor> _active =
      <String, AsyncJobExecutor>{};

  bool _cancelled = false;
  String _jobId = '';

  /// Путь к JSONL-файлу диагностики текущей задачи
  /// (Documents/GenTech/debug/video_<timestamp>.log); null — недоступен.
  String? debugLogPath;

  /// События задачи для сниппетов PendingPart.
  final List<String> _snippets = <String>[];

  /// Raw-тело последнего ответа создания задачи.
  String rawCreateBody = '';

  /// Сниппет 'file: <путь>' добавляется в debugSnippets один раз.
  bool _fileSnippetAdded = false;

  /// Отменяет активную задачу по идентификатору.
  static void cancelJob(String jobId) {
    final id = jobId.trim();
    if (id.isEmpty) return;
    _active[id]?._cancelled = true;
  }

  /// Отменяет все активные задачи.
  static void cancelAll() {
    for (final e in _active.values) {
      e._cancelled = true;
    }
  }

  @override
  void cancel() {
    _cancelled = true;
  }

  /// Выбор провайдера Polza из настроек приложения: сортировка
  /// (по умолчанию по цене — самый дешёвый), конкретный провайдер
  /// не закрепляется. Для не-Polza провайдеров поле не добавляется.
  static Map<String, dynamic> _providerSelectionBody() {
    final sort = settings.providerSort.trim().toLowerCase();
    if (sort.isEmpty) return const <String, dynamic>{};
    return <String, dynamic>{
      'provider': <String, dynamic>{'sort': sort},
    };
  }

  @override
  Stream<GenerationEvent> run(GenerationRequest request) async* {
    _cancelled = false;
    final prompt = _promptFrom(request);
    if (prompt.isEmpty) {
      yield const GenerationFailure(
        BadRequestError(details: 'Промпт пуст — опишите видео.'),
      );
      return;
    }
    final base = request.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final client = http.Client();
    try {
      await _initDebugLog();
      final created = await _createJob(client, base, request, prompt);
      if (_cancelled) {
        yield const GenerationFailure(
          UnknownGenError(details: 'Задача отменена.'),
        );
        return;
      }
      if (created.directUrl.isNotEmpty) {
        final local = await ArtifactMaterializer.materializeVideo(
          created.directUrl,
          client: client,
          prompt: prompt,
          modelId: request.model,
          cost: request.estimatedUsd,
        );
        if (_cancelled) {
          yield const GenerationFailure(
            UnknownGenError(details: 'Задача отменена.'),
          );
          return;
        }
        yield GenCompleted(
          jobId: 'direct',
          localPath: local ?? '',
          remoteUrl: local == null ? created.directUrl : '',
        );
        return;
      }
      final record = created.record;
      if (record == null) {
        yield const GenerationFailure(
          UnknownGenError(
            details: 'Провайдер не создал задачу: идентификатор не найден.',
          ),
        );
        return;
      }
      _jobId = record.jobId;
      _active[_jobId] = this;
      await ActiveJobsStore.instance.save(record);
      // F1-seedance-restore: до первого ответа провайдера процент не
      // известен — первый прогресс неопределённый («в процессе…»),
      // а не фиктивные 5%/0%.
      yield GenProgress(
        jobId: record.jobId,
        percent: 5,
        indeterminate: true,
        debugSnippets: _debugPayload(),
        debugLogPath: debugLogPath,
      );
      yield* _watch(client, base, record);
    } on GenError catch (g) {
      if (_cancelled) {
        yield const GenerationFailure(
          UnknownGenError(details: 'Задача отменена.'),
        );
      } else {
        // F1-retry-resume: jobId для повтора несёт только транзиентная
        // сетевая ошибка ОПРОСА (JobStatusUnknown) — задача жива у
        // провайдера, «Повторить» продолжит её. Фатальные ошибки
        // (провалена на сервере / отменена / ошибка создания) jobId не
        // несут: повтор обязан создать НОВУЮ задачу, а не крутить мёртвую.
        yield GenerationFailure(
          g,
          jobId: g is JobStatusUnknown ? g.jobId : '',
        );
      }
    } on ParameterValidationException catch (e) {
      if (!_cancelled) {
        yield GenerationFailure(BadRequestError(details: e.message));
      }
    } catch (e, st) {
      if (!_cancelled) {
        // TEMP-DIAG-UNMODIFIABLE
        // TODO(2026-12-31): удалить после установления причины исключения.
        // Стек остаётся в локальной диагностике, но не попадает в карточку.
        await _logJson(<String, dynamic>{
          'phase': 'exception',
          'exceptionType': e.runtimeType.toString(),
          'stack': st.toString(),
        });
        if (kDebugMode) {
          debugPrint(
            '[TEMP-DIAG-UNMODIFIABLE] ${e.runtimeType}\n$st',
          );
        }
        yield const GenerationFailure(
          NetworkError(details: 'Не удалось выполнить генерацию видео.'),
        );
      } else {
        yield const GenerationFailure(
          UnknownGenError(details: 'Задача отменена.'),
        );
      }
    } finally {
      if (_jobId.isNotEmpty && identical(_active[_jobId], this)) {
        _active.remove(_jobId);
      }
      client.close();
    }
  }

  /// Продолжает ранее созданную задачу после перезапуска приложения.
  Stream<GenerationEvent> resume(AsyncJobRecord record) async* {
    _cancelled = false;
    _jobId = record.jobId;
    _active[_jobId] = this;
    await _initDebugLog();
    final client = http.Client();
    try {
      // F1-seedance-restore: сохранённый прогресс мог быть синтетическим
      // (сервер не сообщал процент) — первый прогресс после возобновления
      // неопределённый, пока опрос не принесёт реальный процент > 0.
      yield GenProgress(
        jobId: _jobId,
        percent: record.progress > 0 ? record.progress : 5,
        indeterminate: true,
        debugSnippets: _debugPayload(),
        debugLogPath: debugLogPath,
      );
      yield* _watch(
        client,
        record.baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        record,
      );
    } finally {
      if (_jobId.isNotEmpty && identical(_active[_jobId], this)) {
        _active.remove(_jobId);
      }
      client.close();
    }
  }

  /// Цикл опроса: каждые 5 секунд, максимум 150 попыток. Каркас попыток
  /// и транзиентных повторов общий с исполнителем изображений и публичным
  /// опросом — [MediaStatusPoller]; различия интервалов и UI остаются здесь.
  Stream<GenerationEvent> _watch(
    http.Client client,
    String base,
    AsyncJobRecord record,
  ) async* {
    var lastPct = record.progress > 0 ? record.progress : 5.0;
    final poller = MediaStatusPoller<_PollResult>(
      interval: _pollInterval,
      maxAttempts: _maxAttempts,
      maxTransientRetries: _maxTransientRetries,
      transientBackoffBase: _transientBackoffBase,
      isCancelled: () => _cancelled,
      onTransientRetry: (attempt, retry, message) {
        // Диагностика повторов остаётся в JSONL-журнале задачи.
        unawaited(_logJson(<String, dynamic>{
          'phase': 'poll_transient',
          'n': attempt,
          'retry': retry,
          'error': message,
        }));
      },
    );
    try {
      await for (final res in poller.poll(
        (attempt) => _pollOnce(
          client,
          base,
          record.jobId,
          record.apiKey,
          record.createdAt,
          attempt,
        ),
      )) {
        if (res.isFatal) {
          await ActiveJobsStore.instance.remove(record.jobId);
          yield GenerationFailure(res.fatal!, jobId: record.jobId);
          return;
        }
        if (res.isDone) {
          yield GenProgress(
            jobId: record.jobId,
            percent: 100,
            debugSnippets: _debugPayload(),
            debugLogPath: debugLogPath,
          );
          final local = await ArtifactMaterializer.materializeVideo(
            res.videoUrl,
            client: client,
            prompt: record.prompt,
            modelId: record.model,
          );
          if (_cancelled) {
            await ActiveJobsStore.instance.remove(record.jobId);
            yield const GenerationFailure(
              UnknownGenError(details: 'Задача отменена.'),
            );
            return;
          }
          await ActiveJobsStore.instance.remove(record.jobId);
          yield GenCompleted(
            jobId: record.jobId,
            localPath: local ?? '',
            remoteUrl: local == null ? res.videoUrl : '',
          );
          return;
        }
        final computed = res.percent ?? 5.0;
        if (computed > lastPct) lastPct = computed;
        await ActiveJobsStore.instance.updateProgress(record.jobId, lastPct);
        yield GenProgress(
          jobId: record.jobId,
          percent: lastPct,
          indeterminate: res.indeterminate,
          debugSnippets: _debugPayload(),
          debugLogPath: debugLogPath,
        );
      }
      // Лимит попыток исчерпан без результата.
      await ActiveJobsStore.instance.remove(record.jobId);
      yield GenerationFailure(
        const JobTimeout(
          details: 'Задача не завершилась за отведённое время.',
        ),
        jobId: record.jobId,
      );
    } on PollCancelled {
      await ActiveJobsStore.instance.remove(record.jobId);
      yield const GenerationFailure(
        UnknownGenError(details: 'Задача отменена.'),
      );
      return;
    } on PollTransientFailure catch (e) {
      await _logJson(<String, dynamic>{
        'phase': 'poll_give_up',
        'jobId': record.jobId,
        'error': e.message,
      });
      // Задача уже создана: не удаляем запись, чтобы её можно было
      // возобновить без повторной оплаты.
      yield GenerationFailure(
        JobStatusUnknown(
          jobId: record.jobId,
          details: 'Не удалось получить статус задачи: ${e.message}',
        ),
        jobId: record.jobId,
      );
      return;
    }
  }

  /// Плавная оценка прогресса, когда провайдер его не сообщает.
  static double _defaultPercent(int attempt) {
    final v = 5.0 + attempt * 2.5;
    return v > 92.0 ? 92.0 : v;
  }

  Future<_CreateResult> _createJob(
    http.Client client,
    String base,
    GenerationRequest request,
    String prompt,
  ) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      ..._authHeaders(request.apiKey),
    };
    final providerId =
        ModelCatalogAdapter.providerIdFromBaseUrl(base) ?? '';
    final info = ModelInfoResolver.resolveModel(providerId, request.model);
    final rawParams = Map<String, dynamic>.of(request.parameters);
    final translated = await ParameterTranslator.translateWithCatalog(
      modelId: request.model,
      rawParams: rawParams,
      fallback: () => ParameterTranslator.translate(rawParams, info),
    );
    final isVideoModel = info.outputModalities.contains(Modality.video) ||
        info.route == GenerationRoute.asyncJob;
    final isPolza = providerId == 'polza' ||
        base.toLowerCase().contains('polza.ai');
    debugPrint('[PolzaVideo] create: async=true (video route: $isVideoModel)');
    final bodyMap = isPolza
        ? <String, dynamic>{
            'model': request.model,
            'input': ParameterTranslator.toPolzaMediaInput(
              prompt,
              translated,
              isVideo: true,
            ),
            'async': true,
            // Выбор провайдера из настроек (по умолчанию sort: price) —
            // конкретный провайдер не закрепляется.
            ..._providerSelectionBody(),
          }
        : <String, dynamic>{
            'model': request.model,
            'prompt': prompt,
            ...translated,
            'async': true,
          };
    final body = jsonEncode(bodyMap);
    final paths = isPolza ? const <String>['/media'] : _createPaths;
    for (final path in paths) {
      final uri = Uri.tryParse('$base$path');
      if (uri == null) continue;
      final http.Response resp;
      try {
        if (isPolza) {
          debugPrint('[PolzaVideo] Request body: $body');
        }
        resp = await client
            .post(uri, headers: headers, body: body)
            .timeout(_requestTimeout);
      } on TimeoutException {
        if (isPolza) {
          throw const NetworkError(
            details: 'Провайдер не ответил при создании задачи.',
          );
        }
        continue;
      } catch (e) {
        if (e is GenError) rethrow;
        throw NetworkError(details: 'Ошибка соединения: $e');
      }
      final String rawCreate = resp.body;
      rawCreateBody = rawCreate;
      debugPrint(
        'AsyncJobExecutor CREATE $base$path -> ${resp.statusCode}: '
        '${_debugBody(rawCreate)}',
      );
      await _logCreate('$base$path', resp.statusCode, rawCreate);
      final code = resp.statusCode;
      if (code == 404 || code == 405) {
        if (isPolza) {
          throw GenErrorMapper.fromStatusCode(code, resp.body);
        }
        continue;
      }
      if (code < 200 || code >= 300) {
        throw GenErrorMapper.fromStatusCode(code, resp.body);
      }
      Object? json;
      try {
        json = jsonDecode(rawCreate);
      } catch (_) {}
      final status = (_findStatus(json, 0) ?? '').trim().toLowerCase();
      if (_failedStatuses.contains(status)) {
        throw UnknownGenError(details: _pollErrorText(json));
      }
      final direct = _extractCompletedUrl(json) ??
          (_doneStatuses.contains(status) ? _findAnyMediaUrl(json, 0) : null) ??
          _urlFromMessage(json);
      final id = _findJobId(json, 0);
      if (direct != null &&
          direct.isNotEmpty &&
          (id == null || id.isEmpty || _doneStatuses.contains(status))) {
        _addSnippet('create: ${_excerpt(rawCreateBody)}');
        return _CreateResult(directUrl: direct);
      }
      if (id == null || id.isEmpty) {
        final fallbackDirect = _findVideoUrl(json, 0);
        if (fallbackDirect != null && fallbackDirect.isNotEmpty) {
          _addSnippet('create: ${_excerpt(rawCreateBody)}');
          return _CreateResult(directUrl: fallbackDirect);
        }
        continue;
      }
      _addSnippet('create: ${_excerpt(rawCreateBody)}');
      return _CreateResult(
        record: AsyncJobRecord(
          jobId: id,
          baseUrl: base,
          apiKey: request.apiKey,
          model: request.model,
          prompt: prompt,
        ),
      );
    }
    throw const UnknownGenError(
      details:
          'Провайдер не создал задачу: идентификатор результата не найден.',
    );
  }

  Future<_PollResult> _pollOnce(
    http.Client client,
    String base,
    String jobId,
    String apiKey,
    DateTime createdAt,
    int attempt,
  ) async {
    var notFound = 0;
    final prefixes = base.toLowerCase().contains('polza.ai')
        ? const <String>['/media/']
        : _pollPrefixes;
    for (final prefix in prefixes) {
      final queryUrl = '$base$prefix$jobId';
      final uri = Uri.tryParse(queryUrl);
      if (uri == null) continue;
      final http.Response resp;
      try {
        resp = await client
            .get(uri, headers: _authHeaders(apiKey))
            .timeout(_requestTimeout);
      } on TimeoutException catch (e) {
        await _logPollError(attempt, queryUrl, 'timeout: $e');
        _addSnippet('poll $attempt (ошибка): timeout');
        throw PollTransientFailure('timeout: $e');
      } catch (e) {
        await _logPollError(attempt, queryUrl, '$e');
        _addSnippet('poll $attempt (ошибка): $e');
        throw PollTransientFailure('$e');
      }
      final String rawPollBody = resp.body;
      debugPrint(
        'AsyncJobExecutor POLL $queryUrl -> ${resp.statusCode}: '
        '${_debugBody(rawPollBody)}',
      );
      final code = resp.statusCode;
      if (code >= 200 && code < 300) {
        await _logPollBody(attempt, queryUrl, code, rawPollBody);
        _addSnippet('poll $attempt (http=$code): ${_excerpt(rawPollBody)}');
      } else {
        final err = 'HTTP $code: ${_details(rawPollBody)}';
        await _logPollError(attempt, queryUrl, err);
        _addSnippet('poll $attempt (http=$code): ${_excerpt(err)}');
      }
      if (code == 401 || code == 403 || code == 402 || code == 429) {
        // Единая типизированная функция: расхождения 403/402 между
        // исполнителями устранены (R6, п.8).
        return _PollResult(
          fatal: GenErrorMapper.fromStatusCode(code, resp.body),
        );
      }
      if (code == 404 || code == 405) {
        notFound++;
        continue;
      }
      if (code >= 200 && code < 300) {
        return _parsePollBody(resp.body, createdAt, attempt);
      }
      // F1-seedance-restore: сервер не сообщил процент — прогресс
      // неопределённый, а не выдуманное число.
      return _PollResult(
        percent: _defaultPercent(attempt),
        indeterminate: true,
      );
    }
    if (notFound >= prefixes.length) {
      return const _PollResult(
        fatal: UnknownGenError(
          details: 'Задача не найдена у провайдера (404/405).',
        ),
      );
    }
    return _PollResult(percent: _defaultPercent(attempt), indeterminate: true);
  }

  /// Разбор тела ответа опроса статуса.
  _PollResult _parsePollBody(
    String body,
    DateTime createdAt,
    int attempt,
  ) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return _PollResult(
        percent: _defaultPercent(attempt),
        indeterminate: true,
      );
    }
    final status = (_findStatus(json, 0) ?? '').trim().toLowerCase();
    final pct = _findPercent(json, 0);
    debugPrint('[Polling] status: $status, progress: ${pct ?? '-'}');

    if (_failedStatuses.contains(status)) {
      return _PollResult(
        fatal: UnknownGenError(details: _pollErrorText(json)),
      );
    }

    final url = _extractCompletedUrl(json) ??
        (_doneStatuses.contains(status) ? _findAnyMediaUrl(json, 0) : null) ??
        _findVideoUrl(json, 0) ??
        _urlFromMessage(json) ??
        '';

    if (url.isNotEmpty &&
        (_doneStatuses.contains(status) ||
            (!_runningStatuses.contains(status)))) {
      return _PollResult(videoUrl: url, percent: 100);
    }

    if (_doneStatuses.contains(status)) {
      if (url.isNotEmpty) {
        return _PollResult(videoUrl: url, percent: 100);
      }
      return const _PollResult(
        fatal: UnknownGenError(
          details: 'Провайдер завершил задачу, но не вернул ссылку на медиа.',
        ),
      );
    }

    // F1-seedance-restore: прогресс неопределён, когда сервер НЕ прислал
    // процент ИЛИ прислал <= 0 (видео-модели Polza отдают progress: 0,
    // пока задача processing). Плавная оценка остаётся в поле percent
    // для совместимости, но indeterminate=true не позволяет карточке
    // выдавать её за реальный процент провайдера.
    final hasServerPct = pct != null && pct > 0;
    var percent = pct;
    if (!hasServerPct) {
      final elapsed = DateTime.now().difference(createdAt).inSeconds;
      final byTime = (5.0 + elapsed * 1.5).clamp(5.0, 92.0);
      final byAttempt = _defaultPercent(attempt);
      percent = byTime > byAttempt ? byTime : byAttempt;
    }
    return _PollResult(percent: percent, indeterminate: !hasServerPct);
  }

  /// Извлекает URL из полей ответа медиа-задачи.
  static String? _extractCompletedUrl(Object? node) {
    if (node is! Map) return null;
    final data = node['data'];
    if (data is Map) {
      final u = data['url'] ?? data['video_url'] ?? data['file_url'];
      if (u is String && _isHttpOrDataUrl(u)) return u.trim();
      final nestedOut = data['output'];
      final fromNested = _extractFromOutput(nestedOut);
      if (fromNested != null) return fromNested;
    } else if (data is List) {
      for (final item in data) {
        if (item is Map) {
          final u = item['url'] ?? item['video_url'] ?? item['file_url'];
          if (u is String && _isHttpOrDataUrl(u)) return u.trim();
        } else if (item is String && _isHttpOrDataUrl(item)) {
          return item.trim();
        }
      }
    }
    final fromOutput = _extractFromOutput(node['output']);
    if (fromOutput != null) return fromOutput;

    final fromResult = _extractFromOutput(node['result']);
    if (fromResult != null) return fromResult;

    final topUrl = node['video_url'] ?? node['url'];
    if (topUrl is String && _isHttpOrDataUrl(topUrl)) return topUrl.trim();

    return null;
  }

  static String? _extractFromOutput(Object? output) {
    if (output == null) return null;
    if (output is String && _isHttpOrDataUrl(output)) return output.trim();
    if (output is Map) {
      final u = output['url'] ?? output['video_url'] ?? output['audio_url'];
      if (u is String && _isHttpOrDataUrl(u)) return u.trim();
      final list = output['urls'] ?? output['files'] ?? output['data'];
      if (list is List) return _extractFromOutput(list);
    }
    if (output is List) {
      for (final item in output) {
        if (item is String && _isHttpOrDataUrl(item)) return item.trim();
        if (item is Map) {
          final u = item['url'] ?? item['video_url'] ?? item['file_url'];
          if (u is String && _isHttpOrDataUrl(u)) return u.trim();
        }
      }
    }
    return null;
  }

  static bool _isHttpOrDataUrl(String s) {
    final t = s.trim();
    return t.startsWith('http://') ||
        t.startsWith('https://') ||
        t.startsWith('data:');
  }

  /// Любой валидный URL в дереве ответа, когда статус уже completed.
  static String? _findAnyMediaUrl(Object? node, int depth) {
    if (node == null || depth > 8) return null;
    if (node is String) {
      return _isHttpOrDataUrl(node) ? node.trim() : null;
    }
    if (node is Map) {
      for (final k in const <String>[
        'url',
        'video_url',
        'output',
        'file_url',
        'download_url',
      ]) {
        final v = node[k];
        if (v is String && _isHttpOrDataUrl(v)) return v.trim();
      }
      for (final entry in node.entries) {
        final k = entry.key.toString().toLowerCase();
        if (k == 'id' || k == 'model' || k == 'status') continue;
        final r = _findAnyMediaUrl(entry.value, depth + 1);
        if (r != null) return r;
      }
    }
    if (node is List) {
      for (final item in node) {
        final r = _findAnyMediaUrl(item, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Текст ошибки задачи из JSON.
  static String _pollErrorText(Object? json) {
    if (json is Map) {
      for (final key in const <String>[
        'error', 'message', 'details', 'reason',
      ]) {
        final t = _errorFieldText(json[key]);
        if (t != null) return _clip(t);
      }
      final data = json['data'];
      if (data is Map) {
        for (final key in const <String>[
          'error', 'message', 'details', 'reason',
        ]) {
          final t = _errorFieldText(data[key]);
          if (t != null) return _clip(t);
        }
      }
    }
    return 'Провайдер сообщил об ошибке задачи.';
  }

  static String? _errorFieldText(Object? v) {
    if (v is Map) {
      final m = v['message'] ?? v['detail'] ?? v['error'];
      if (m is String && m.trim().isNotEmpty) return m;
      return null;
    }
    if (v is String && v.trim().isNotEmpty) return v;
    return null;
  }

  static String? _urlFromMessage(Object? json) {
    if (json is! Map) return null;
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return null;
    }
    final msg = (choices.first as Map)['message'];
    final String? text;
    if (msg is Map) {
      final content = msg['content'];
      text = content is String ? content : null;
    } else if (msg is String) {
      text = msg;
    } else {
      text = null;
    }
    if (text == null) return null;
    final m = RegExp(r'https?://\S+?\.(?:mp4|webm|mov)(?:\?\S*)?')
        .firstMatch(text);
    return m?.group(0);
  }

  static String? extractJobId(Map<String, dynamic> json) =>
      _findJobId(json, 0);

  static String? extractMediaUrl(Map<String, dynamic> json) {
    final byCompleted = _extractCompletedUrl(json);
    if (byCompleted != null) return byCompleted;
    final byField = _findVideoUrl(json, 0);
    if (byField != null) return byField;
    return _urlFromMessage(json);
  }

  /// Публичный опрос медиа-задачи (модель-инструмент): каждые 5 секунд,
  /// максимум 150 попыток. Выполняется тем же каркасом [MediaStatusPoller],
  /// что и внутренний цикл видео-задачи (единый компонент опроса, R6 п.8);
  /// публичный контракт колбэков и исключений сохранён прежним:
  /// GenError при 401/403, Exception при остальных неудачах.
  Future<String> pollMediaJob({
    required http.Client client,
    required String baseUrl,
    required String apiKey,
    required String jobId,
    required void Function(double progress, String statusText) onProgress,
    bool Function()? isCancelled,
  }) async {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    var percent = 5.0;
    onProgress(percent, 'pending');
    final poller = MediaStatusPoller<_PublicJobPoll>(
      interval: _pollInterval,
      maxAttempts: _maxAttempts,
      maxTransientRetries: _maxTransientRetries,
      transientBackoffBase: _transientBackoffBase,
      isCancelled: isCancelled,
      onTransientRetry: (attempt, retry, message) {
        onProgress(percent, 'сеть недоступна, попытка $attempt');
      },
    );
    try {
      await for (final st in poller.poll(
        (attempt) => _publicPollAttempt(
          client,
          base,
          apiKey,
          jobId,
          attempt,
          onProgress: (pct, text) {
            if (pct > percent) percent = pct;
            onProgress(percent, text);
          },
        ),
      )) {
        onProgress(100, 'completed');
        return st.url;
      }
    } on PollCancelled {
      throw Exception('Задача отменена.');
    } on PollTransientFailure catch (e) {
      throw Exception('Не удалось получить статус задачи: ${e.message}');
    }
    throw Exception('Задача не завершилась за отведённое время.');
  }

  /// Одна логическая попытка публичного опроса. Фатальные коды (401/403)
  /// сводятся к общей типизированной функции GenErrorMapper.fromStatusCode;
  /// сбои сети — PollTransientFailure; остальные коды — «ещё не готово».
  Future<_PublicJobPoll> _publicPollAttempt(
    http.Client client,
    String base,
    String apiKey,
    String jobId,
    int attempt, {
    required void Function(double percent, String statusText) onProgress,
  }) async {
    final uri = Uri.tryParse('$base/media/$jobId');
    if (uri == null) {
      throw const PollTransientFailure('Некорректный адрес опроса задачи.');
    }
    final http.Response resp;
    try {
      resp = await client
          .get(uri, headers: _authHeaders(apiKey))
          .timeout(_requestTimeout);
    } on TimeoutException catch (e) {
      throw PollTransientFailure('timeout: $e');
    } catch (e) {
      throw PollTransientFailure('$e');
    }
    final code = resp.statusCode;
    if (code == 401 || code == 403) {
      throw GenErrorMapper.fromStatusCode(code, resp.body);
    }
    if (code < 200 || code >= 300) {
      onProgress(_defaultPercent(attempt), 'HTTP $code, попытка $attempt');
      return const _PublicJobPoll(statusText: 'processing');
    }
    Map<String, dynamic> json = <String, dynamic>{};
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map) json = Map<String, dynamic>.from(decoded);
    } catch (_) {}
    final status = (_findStatus(json, 0) ?? '').trim().toLowerCase();
    if (_failedStatuses.contains(status)) {
      throw Exception(_pollErrorText(json));
    }
    final url = extractMediaUrl(json) ??
        (_doneStatuses.contains(status) ? _findAnyMediaUrl(json, 0) : null) ??
        '';
    if (url.isNotEmpty &&
        (_doneStatuses.contains(status) ||
            !_runningStatuses.contains(status))) {
      return _PublicJobPoll(url: url, statusText: 'completed');
    }
    if (_doneStatuses.contains(status)) {
      throw Exception('Провайдер завершил задачу, но не вернул медиа.');
    }
    final serverPct = _findPercent(json, 0);
    final double pct;
    if (serverPct != null && serverPct > 0) {
      pct = serverPct.clamp(5.0, 95.0);
    } else {
      pct = _defaultPercent(attempt);
    }
    onProgress(pct, status.isEmpty ? 'processing' : status);
    return _PublicJobPoll(statusText: status.isEmpty ? 'processing' : status);
  }

  // ---------- диагностика зависания (JSONL-лог) ----------

  Future<void> _initDebugLog() async {
    if (debugLogPath != null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/GenTech/debug');
      await dir.create(recursive: true);
      final ts = DateTime.now().millisecondsSinceEpoch;
      debugLogPath = '${dir.path}/video_$ts.log';
    } catch (e) {
      debugPrint('AsyncJobExecutor: debug log init failed: $e');
      debugLogPath = null;
    }
  }

  Future<void> _logJson(Map<String, dynamic> entry) async {
    final path = debugLogPath;
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString('${jsonEncode(entry)}\n', mode: FileMode.append);
    } catch (e) {
      debugPrint('AsyncJobExecutor: debug log write failed: $e');
    }
  }

  Future<void> _logCreate(String url, int code, String raw) =>
      _logJson(<String, dynamic>{
        'phase': 'create',
        'url': url,
        'http': code,
        'body': raw,
      });

  Future<void> _logPollBody(int n, String url, int code, String raw) =>
      _logJson(<String, dynamic>{
        'phase': 'poll',
        'n': n,
        'url': url,
        'http': code,
        'body': raw,
      });

  Future<void> _logPollError(int n, String url, String error) =>
      _logJson(<String, dynamic>{
        'phase': 'poll',
        'n': n,
        'url': url,
        'error': error,
      });

  void _addSnippet(String s) {
    _snippets.add(s);
    if (_snippets.length > 6) {
      _snippets.removeRange(0, _snippets.length - 6);
    }
  }

  List<String> _debugPayload() {
    final out = <String>[];
    final path = debugLogPath;
    if (path != null && path.isNotEmpty && !_fileSnippetAdded) {
      _fileSnippetAdded = true;
      out.add('file: $path');
    }
    final events = _snippets.length > 3
        ? _snippets.sublist(_snippets.length - 3)
        : _snippets;
    return <String>[...out, ...events];
  }

  static String _excerpt(String raw) {
    final t = raw.replaceAll('\n', ' ').trim();
    return t.length > 500 ? '${t.substring(0, 500)}…' : t;
  }

  static String _debugBody(String body) {
    try {
      final s = jsonEncode(jsonDecode(body));
      return s.length > 2000 ? '${s.substring(0, 2000)}…' : s;
    } catch (_) {
      return body.length > 2000 ? '${body.substring(0, 2000)}…' : body;
    }
  }

  static Map<String, String> _authHeaders(String apiKey) {
    final cleanKey = apiKey
        .trim()
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
    return <String, String>{
      'Authorization': 'Bearer $cleanKey',
      'Accept': 'application/json',
    };
  }

  static String _promptFrom(GenerationRequest request) {
    for (final m in request.messages.reversed) {
      if (m['role'] != 'user') continue;
      final content = m['content'];
      if (content is String) {
        final t = content.trim();
        if (t.isNotEmpty) return t;
      }
      if (content is List) {
        final buf = StringBuffer();
        for (final part in content) {
          if (part is Map && part['type'] == 'text') {
            final t = part['text'];
            if (t is String) buf.write(t);
          }
        }
        final t = buf.toString().trim();
        if (t.isNotEmpty) return t;
      }
    }
    return '';
  }

  /// Рекурсивный поиск ссылки на видео в JSON-ответе провайдера.
  static String? _findVideoUrl(Object? node, int depth) {
    if (node is String) {
      final s = node.trim();
      if (s.isEmpty) return null;
      final isUrl = s.startsWith('http://') ||
          s.startsWith('https://') ||
          s.startsWith('data:video');
      final lower = s.toLowerCase();
      final looksLikeVideo = lower.contains('.mp4') ||
          lower.contains('.webm') ||
          lower.contains('.mov') ||
          lower.contains('video') ||
          lower.contains('media');
      return isUrl && looksLikeVideo ? s : null;
    }
    if (node == null || depth > 8) return null;
    if (node is Map) {
      for (final entry in node.entries) {
        final k = entry.key.toString().toLowerCase();
        final v = entry.value;
        if (v is String) {
          final s = v.trim();
          if (s.isEmpty) continue;
          final isUrl = s.startsWith('http://') ||
              s.startsWith('https://') ||
              s.startsWith('data:video');
          if (isUrl &&
              (k.contains('video') ||
                  k == 'url' ||
                  k.endsWith('_url') ||
                  k.contains('output') ||
                  k.contains('download') ||
                  k.contains('result'))) {
            return s;
          }
          continue;
        }
        final r = _findVideoUrl(v, depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    if (node is List) {
      for (final e in node) {
        final r = _findVideoUrl(e, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Рекурсивный поиск текстового статуса задачи ('status'/'state').
  static String? _findStatus(Object? node, int depth) {
    if (node is Map && depth <= 8) {
      for (final entry in node.entries) {
        final k = entry.key.toString().toLowerCase();
        if ((k == 'status' || k == 'state') && entry.value is String) {
          return entry.value as String;
        }
      }
      for (final entry in node.entries) {
        final r = _findStatus(entry.value, depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    if (node is List && depth <= 8) {
      for (final e in node) {
        final r = _findStatus(e, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Рекурсивный поиск числового прогресса.
  static double? _findPercent(Object? node, int depth) {
    if (node is Map && depth <= 8) {
      for (final entry in node.entries) {
        final k = entry.key.toString().toLowerCase();
        if (k == 'progress' || k == 'percent' || k == 'percentage') {
          final v = entry.value;
          double? d;
          if (v is num) {
            d = v.toDouble();
          } else if (v is String) {
            final m = RegExp(r'-?\d+(?:[.,]\d+)?').firstMatch(v);
            if (m != null) {
              d = double.tryParse(m.group(0)!.replaceAll(',', '.'));
            }
          }
          if (d != null && d > 0 && d <= 1) d *= 100;
          if (d != null && d >= 0 && d <= 100) return d;
        }
      }
      for (final entry in node.entries) {
        final r = _findPercent(entry.value, depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    if (node is List && depth <= 8) {
      for (final e in node) {
        final r = _findPercent(e, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Рекурсивный поиск идентификатора задачи в ответе создания.
  static String? _findJobId(Object? node, int depth) {
    if (node is Map && depth <= 8) {
      const specific = <String>[
        'id', 'job_id', 'jobid', 'task_id', 'taskid', 'request_id',
        'requestid', 'operation_id', 'uuid',
      ];
      for (final k in specific) {
        final v = node[k];
        if (v is String && v.trim().isNotEmpty && v.trim().length <= 128) {
          return v.trim();
        }
        if (v is num) return v.toString();
      }
      for (final entry in node.entries) {
        final r = _findJobId(entry.value, depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    if (node is List && depth <= 8) {
      for (final e in node) {
        final r = _findJobId(e, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  static String _details(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final err = j['error'];
        if (err is Map) {
          final m = err['message'];
          if (m is String && m.trim().isNotEmpty) return _clip(m);
        }
        final m = j['message'];
        if (m is String && m.trim().isNotEmpty) return _clip(m);
      }
    } catch (_) {}
    return _clip(body);
  }

  static String _clip(String s) {
    final t = s.trim();
    return t.length > 300 ? t.substring(0, 300) : t;
  }
}
