// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';

import '../models/gen_error.dart';
import '../models/model_info.dart' show GenerationRoute, Modality;
import '../providers/model_catalog_adapter.dart';
import '../providers/model_info_resolver.dart';
import 'active_jobs_store.dart';
import 'artifact_materializer.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';
import 'parameter_translator.dart';
import 'parameter_validation_exception.dart';

/// Результат одного опроса состояния задачи.
class _PollResult {
  final String videoUrl;
  final double? percent;

  /// Сервер сообщил «в процессе» без числового прогресса.
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
class AsyncJobExecutor extends GenerationExecutor {
  static const Duration _pollInterval = Duration(seconds: 5);
  static const int _maxAttempts = 150;
  static const Duration _requestTimeout = Duration(seconds: 60);

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
      yield GenProgress(
        jobId: record.jobId,
        percent: 5,
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
        yield GenerationFailure(g);
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
      yield GenProgress(
        jobId: _jobId,
        percent: record.progress > 0 ? record.progress : 5,
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

  /// Цикл опроса: каждые 5 секунд, максимум 150 попыток.
  Stream<GenerationEvent> _watch(
    http.Client client,
    String base,
    AsyncJobRecord record,
  ) async* {
    var lastPct = record.progress > 0 ? record.progress : 5.0;
    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      await Future<void>.delayed(_pollInterval);
      if (_cancelled) {
        await ActiveJobsStore.instance.remove(record.jobId);
        yield const GenerationFailure(
          UnknownGenError(details: 'Задача отменена.'),
        );
        return;
      }
      final res = await _pollOnce(
        client,
        base,
        record.jobId,
        record.apiKey,
        record.createdAt,
        attempt,
      );
      if (_cancelled) {
        await ActiveJobsStore.instance.remove(record.jobId);
        yield const GenerationFailure(
          UnknownGenError(details: 'Задача отменена.'),
        );
        return;
      }
      if (res.isFatal) {
        await ActiveJobsStore.instance.remove(record.jobId);
        yield GenerationFailure(res.fatal!);
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
      final computed = res.percent ?? _defaultPercent(attempt);
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
    await ActiveJobsStore.instance.remove(record.jobId);
    yield const GenerationFailure(
      JobTimeout(details: 'Задача не завершилась за отведённое время.'),
    );
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
          debugPrint('[MediaExec] Request body: $body');
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
        if (isPolza) throw _mapStatus(code, resp.body);
        continue;
      }
      if (code < 200 || code >= 300) throw _mapStatus(code, resp.body);
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
        return _PollResult(percent: _defaultPercent(attempt));
      } catch (e) {
        await _logPollError(attempt, queryUrl, '$e');
        _addSnippet('poll $attempt (ошибка): $e');
        return _PollResult(percent: _defaultPercent(attempt));
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
      if (code == 401 || code == 403) {
        return _PollResult(fatal: AuthError(details: _details(resp.body)));
      }
      if (code == 402) {
        return _PollResult(
          fatal: InsufficientFunds(details: _details(resp.body)),
        );
      }
      if (code == 429) {
        return _PollResult(fatal: RateLimited(details: _details(resp.body)));
      }
      if (code == 404 || code == 405) {
        notFound++;
        continue;
      }
      if (code >= 200 && code < 300) {
        return _parsePollBody(resp.body, createdAt, attempt);
      }
      return _PollResult(percent: _defaultPercent(attempt));
    }
    if (notFound >= prefixes.length) {
      return const _PollResult(
        fatal: UnknownGenError(
          details: 'Задача не найдена у провайдера (404/405).',
        ),
      );
    }
    return _PollResult(percent: _defaultPercent(attempt));
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
      return _PollResult(percent: _defaultPercent(attempt));
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

    var percent = pct;
    if (percent == null || percent <= 0) {
      final elapsed = DateTime.now().difference(createdAt).inSeconds;
      final byTime = (5.0 + elapsed * 1.5).clamp(5.0, 92.0);
      final byAttempt = _defaultPercent(attempt);
      percent = byTime > byAttempt ? byTime : byAttempt;
    }
    return _PollResult(percent: percent, indeterminate: pct == null);
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

  /// Публичный опрос медиа-задачи: каждые 5 секунд, максимум 150 попыток.
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
    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      await Future<void>.delayed(_pollInterval);
      if (isCancelled?.call() ?? false) {
        throw Exception('Задача отменена.');
      }
      final uri = Uri.tryParse('$base/media/$jobId');
      if (uri == null) {
        throw Exception('Некорректный адрес опроса задачи.');
      }
      http.Response resp;
      try {
        resp = await client
            .get(uri, headers: _authHeaders(apiKey))
            .timeout(_requestTimeout);
      } catch (_) {
        onProgress(percent, 'сеть недоступна, попытка $attempt');
        continue;
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw Exception('Неверный API-ключ (401).');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        onProgress(percent, 'HTTP ${resp.statusCode}, попытка $attempt');
        continue;
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
        onProgress(100, 'completed');
        return url;
      }
      if (_doneStatuses.contains(status)) {
        throw Exception('Провайдер завершил задачу, но не вернул медиа.');
      }
      final serverPct = _findPercent(json, 0);
      if (serverPct != null && serverPct > percent) {
        percent = serverPct.clamp(5.0, 95.0);
      } else {
        percent = (percent + 3).clamp(5.0, 92.0);
      }
      onProgress(percent, status.isEmpty ? 'processing' : status);
    }
    throw Exception('Задача не завершилась за отведённое время.');
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

  static GenError _mapStatus(int code, String body) {
    final details = _details(body);
    switch (code) {
      case 401:
      case 403:
        return AuthError(details: details);
      case 402:
        return InsufficientFunds(details: details);
      case 429:
        return RateLimited(details: details);
      case 400:
      case 422:
        return BadRequestError(details: details);
      case 404:
        return ModelNotFoundError(details: details);
    }
    if (code >= 500) return ServerError(statusCode: code, details: details);
    return UnknownGenError(details: 'Ошибка $code. $details');
  }
}
