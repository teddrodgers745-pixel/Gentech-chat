// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:flutter/foundation.dart';

import '../models/gen_error.dart';
import '../providers/model_catalog_adapter.dart';
import '../providers/model_info_resolver.dart';
import 'active_jobs_store.dart';
import 'artifact_materializer.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';
import 'parameter_translator.dart';

/// Результат одного опроса состояния задачи.
class _PollResult {
  final String videoUrl;
  final double? percent;
  final GenError? fatal;

  const _PollResult({this.videoUrl = '', this.percent, this.fatal});

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
/// Схема: POST на создание задачи (с фоллбэком на альтернативные
/// эндпоинты при 404/405) -> сохранение [AsyncJobRecord] в хранилище ->
/// цикл опроса статуса каждые 3 секунды (до 120 попыток) с эмитом
/// [GenProgress] -> при успехе скачивание видео через
/// [ArtifactMaterializer.materializeVideo] и [GenCompleted].
///
/// Задача переживает перезапуск приложения: исполнитель продолжается
/// из сохранённой записи через [resume] (вызывает GenerationService).
class AsyncJobExecutor extends GenerationExecutor {
  static const Duration _pollInterval = Duration(seconds: 3);
  static const int _maxAttempts = 120;
  static const Duration _requestTimeout = Duration(seconds: 60);

  /// Пути создания задачи: первый удачный; 404/405 -> следующий.
  static const List<String> _createPaths = <String>[
    '/videos/generations',
    '/generations',
    '/videos',
  ];

  /// Пути опроса статуса (к каждому добавляется идентификатор задачи).
  static const List<String> _pollPrefixes = <String>[
    '/videos/',
    '/generations/',
    '/jobs/',
  ];

  static const Set<String> _doneStatuses = <String>{
    'succeeded', 'success', 'complete', 'completed', 'done', 'finished', 'ok',
  };
  static const Set<String> _failedStatuses = <String>{
    'failed', 'failure', 'error', 'canceled', 'cancelled', 'rejected',
    'expired',
  };

  /// Статусы «задача ещё выполняется»: при отсутствии явного прогресса
  /// для них генерируется оптимистичный процент по прошедшему времени.
  static const Set<String> _runningStatuses = <String>{
    'processing', 'running', 'in_progress',
  };

  /// Активные исполнители по jobId — для отмены из интерфейса
  /// (кнопка «Отменить» на карточке PendingPart).
  static final Map<String, AsyncJobExecutor> _active =
      <String, AsyncJobExecutor>{};

  bool _cancelled = false;
  String _jobId = '';

  /// Отменяет активную задачу по идентификатору. Задача снимается
  /// из хранилища, PendingPart в чате убирается обработчиком события.
  static void cancelJob(String jobId) {
    final id = jobId.trim();
    if (id.isEmpty) return;
    _active[id]?._cancelled = true;
  }

  /// Отменяет все активные задачи (кнопка «стоп»).
  static void cancelAll() {
    for (final e in _active.values) {
      e._cancelled = true;
    }
  }

  @override
  void cancel() {
    // Отмена текущего экземпляра: цикл опроса завершится с ошибкой
    // «Задача отменена» на ближайшей проверке флага.
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
      // Первый прогресс сразу после создания: интерфейс узнаёт jobId.
      yield GenProgress(jobId: record.jobId, percent: 0);
      yield* _watch(client, base, record);
    } on GenError catch (g) {
      if (_cancelled) {
        yield const GenerationFailure(
          UnknownGenError(details: 'Задача отменена.'),
        );
      } else {
        yield GenerationFailure(g);
      }
    } catch (e) {
      if (!_cancelled) {
        yield GenerationFailure(
          NetworkError(details: 'Ошибка соединения: $e'),
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

  /// Продолжает ранее созданную задачу после перезапуска приложения:
  /// без повторного создания — сразу цикл опроса статуса.
  Stream<GenerationEvent> resume(AsyncJobRecord record) async* {
    _cancelled = false;
    _jobId = record.jobId;
    _active[_jobId] = this;
    final client = http.Client();
    try {
      yield GenProgress(jobId: _jobId, percent: record.progress);
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

  /// Цикл опроса: 3 секунды между попытками, максимум 120 попыток.
  Stream<GenerationEvent> _watch(
    http.Client client,
    String base,
    AsyncJobRecord record,
  ) async* {
    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
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
      final pct = res.percent ?? _defaultPercent(attempt);
      await ActiveJobsStore.instance.updateProgress(record.jobId, pct);
      yield GenProgress(jobId: record.jobId, percent: pct);
      await Future<void>.delayed(_pollInterval);
    }
    await ActiveJobsStore.instance.remove(record.jobId);
    yield const GenerationFailure(
      JobTimeout(details: 'Задача не завершилась за отведённое время.'),
    );
  }

  /// Плавная оценка прогресса, когда провайдер его не сообщает.
  static double _defaultPercent(int attempt) {
    final v = attempt * 100 / _maxAttempts;
    return v > 95 ? 95 : v;
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
    // Нормализация параметров под конкретную модель: duration (intChoice)
    // уходит как число (5, 8, 10), пропорция — в формат модели
    // (size, seconds для Sora и т.п.). Без схемы параметры уходят как есть.
    final providerId =
        ModelCatalogAdapter.providerIdFromBaseUrl(base) ?? '';
    final info = ModelInfoResolver.resolveModel(providerId, request.model);
    final translated = ParameterTranslator.translate(
      Map<String, dynamic>.of(request.parameters),
      info,
    );
    final body = jsonEncode(<String, dynamic>{
      'model': request.model,
      'prompt': prompt,
      ...translated,
    });
    for (final path in _createPaths) {
      final uri = Uri.tryParse('$base$path');
      if (uri == null) continue;
      final http.Response resp;
      try {
        resp = await client
            .post(uri, headers: headers, body: body)
            .timeout(_requestTimeout);
      } on TimeoutException {
        continue;
      } catch (e) {
        throw NetworkError(details: 'Ошибка соединения: $e');
      }
      debugPrint(
        'AsyncJobExecutor CREATE $base$path -> ${resp.statusCode}: '
        '${_debugBody(resp.body)}',
      );
      final code = resp.statusCode;
      if (code == 404 || code == 405) continue; // фоллбэк на следующий путь
      if (code < 200 || code >= 300) throw _mapStatus(code, resp.body);
      Object? json;
      try {
        json = jsonDecode(resp.body);
      } catch (_) {}
      final direct = _findVideoUrl(json, 0) ?? _urlFromMessage(json);
      if (direct != null) return _CreateResult(directUrl: direct);
      final id = _findJobId(json, 0);
      if (id == null || id.isEmpty) continue;
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
          'Провайдер не поддерживает создание задач (404 на всех эндпоинтах).',
    );
  }

  Future<_PollResult> _pollOnce(
    http.Client client,
    String base,
    String jobId,
    String apiKey,
    DateTime createdAt,
  ) async {
    var notFound = 0;
    for (final prefix in _pollPrefixes) {
      final uri = Uri.tryParse('$base$prefix$jobId');
      if (uri == null) continue;
      final http.Response resp;
      try {
        resp = await client
            .get(uri, headers: _authHeaders(apiKey))
            .timeout(_requestTimeout);
      } on TimeoutException {
        return const _PollResult();
      } catch (_) {
        // Сетевая трудность — следующая попытка опроса.
        return const _PollResult();
      }
      debugPrint(
        'AsyncJobExecutor POLL $base$prefix$jobId -> ${resp.statusCode}: '
        '${_debugBody(resp.body)}',
      );
      final code = resp.statusCode;
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
        return _parsePollBody(resp.body, createdAt);
      }
      // Прочие коды (5xx и т.п.): временная трудность, пробуем позже.
      return const _PollResult();
    }
    if (notFound >= _pollPrefixes.length) {
      return const _PollResult(
        fatal: UnknownGenError(
          details: 'Задача не найдена у провайдера (404).',
        ),
      );
    }
    return const _PollResult();
  }

  /// Разбор тела ответа опроса статуса.
  ///
  /// Статус ищется в json['status'], json['state'], json['data']['status'],
  /// json['task']['status'] (рекурсивный поиск) и приводится к lowerCase.
  /// Прогресс — json['progress'] / json['data']['progress']: int, double
  /// (0.5 -> 50) либо строка ('50%'). Если прогресс не сообщён (0/null),
  /// а статус 'processing'/'running'/'in_progress', используется
  /// «оптимистичный» прогресс: 5% + 1.5% за каждую секунду ожидания,
  /// максимум 90% — чтобы карточка в чате не застывала на «0%».
  _PollResult _parsePollBody(String body, DateTime createdAt) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return const _PollResult();
    }
    final url = _findVideoUrl(json, 0) ?? _urlFromMessage(json) ?? '';
    final pct = _findPercent(json, 0);
    if (url.isNotEmpty) {
      return _PollResult(videoUrl: url, percent: pct ?? 100);
    }
    final status = (_findStatus(json, 0) ?? '').trim().toLowerCase();
    if (_failedStatuses.contains(status)) {
      return _PollResult(
        fatal: UnknownGenError(details: _pollErrorText(json)),
      );
    }
    if (_doneStatuses.contains(status)) {
      return const _PollResult(
        fatal: UnknownGenError(
          details: 'Провайдер завершил задачу, но не вернул видео.',
        ),
      );
    }
    var percent = pct;
    if ((percent == null || percent <= 0) &&
        _runningStatuses.contains(status)) {
      final elapsed = DateTime.now().difference(createdAt).inSeconds;
      percent = (5 + elapsed * 1.5).clamp(5.0, 90.0);
    }
    return _PollResult(percent: percent);
  }

  /// Текст ошибки задачи из JSON: json['error'] (строка либо объект с
  /// message) либо json['message'].
  static String _pollErrorText(Object? json) {
    if (json is Map) {
      final err = json['error'];
      if (err is Map) {
        final m = err['message'];
        if (m is String && m.trim().isNotEmpty) return _clip(m);
      }
      if (err is String && err.trim().isNotEmpty) return _clip(err);
      final m = json['message'];
      if (m is String && m.trim().isNotEmpty) return _clip(m);
    }
    return 'Провайдер сообщил об ошибке задачи.';
  }

  /// Ссылка на видео внутри choices[0].message (строка либо content):
  /// первый http(s)-адрес видеофайла в тексте сообщения.
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

  /// Тело ответа для debugPrint: JSON перекодируется, длинные ответы
  /// обрезаются, битый JSON печатается как есть.
  static String _debugBody(String body) {
    try {
      final s = jsonEncode(jsonDecode(body));
      return s.length > 2000 ? '${s.substring(0, 2000)}…' : s;
    } catch (_) {
      return body.length > 2000 ? '${body.substring(0, 2000)}…' : body;
    }
  }

  static Map<String, String> _authHeaders(String apiKey) =>
      <String, String>{
        'Authorization': 'Bearer $apiKey',
        'Accept': 'application/json',
      };

  /// Промпт — текст последнего пользовательского сообщения.
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

  /// Рекурсивный поиск числового прогресса ('progress'/'percent').
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
            // '50%', '50', '0.5' — извлекаем число из строки.
            final m =
                RegExp(r'-?\d+(?:[.,]\d+)?').firstMatch(v);
            if (m != null) {
              d = double.tryParse(m.group(0)!.replaceAll(',', '.'));
            }
          }
          if (d != null && d >= 0 && d <= 1) d *= 100;
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

  /// Рекурсивный поиск идентификатора задачи в ответе создания:
  /// сначала специфичные ключи, затем 'id'/'uuid', затем вглубь.
  static String? _findJobId(Object? node, int depth) {
    if (node is Map && depth <= 8) {
      const specific = <String>[
        'job_id', 'jobid', 'task_id', 'taskid', 'request_id', 'requestid',
        'operation_id',
      ];
      for (final k in specific) {
        final v = node[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      for (final entry in node.entries) {
        final k = entry.key.toString().toLowerCase();
        if ((k == 'id' || k == 'uuid') && entry.value is String) {
          final s = (entry.value as String).trim();
          if (s.isNotEmpty && s.length <= 128) return s;
        }
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

  /// Текст ошибки провайдера из JSON-ответа (error.message / message).
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

  /// Перевод кода ответа в типизированную [GenError].
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
