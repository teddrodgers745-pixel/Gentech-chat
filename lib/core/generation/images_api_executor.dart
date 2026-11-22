// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/gen_error.dart';
import '../models/generation_schema.dart';
import '../providers/model_catalog_adapter.dart';
import '../providers/model_info_resolver.dart';
import 'artifact_materializer.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';
import 'image_dialect.dart';
import 'parameter_translator.dart';
import 'parameter_validation_exception.dart';

/// Состояние одного опроса статуса генерации изображения.
class _ImagePollState {
  /// Готовая ссылка на изображение (null — ещё генерируется).
  final String? url;

  /// Текущий процент (0..100).
  final double percent;

  /// Текстовый статус провайдера ('pending'/'processing'/...).
  final String status;

  const _ImagePollState({
    this.url,
    this.percent = 0,
    this.status = 'processing',
  });
}

/// Исполнитель генерации изображений (HTTP через dio).
///
/// Поддерживает:
///  - Polza Media API: POST {baseUrl}/media с телом
///    {model, input: {...}, async: true} и автоматическим опросом
///    GET {baseUrl}/media/{id} каждые 4 секунды (интервал 3-5 с по
///    документации), пока статус не станет completed/failed; результат
///    берётся из `data.url` (или `output`);
///  - openAiStandard: POST {baseUrl}/images/generations;
///  - shortImagesPath: POST {baseUrl}/images (RouterAI);
///  - openRouterChatImages: POST {baseUrl}/chat/completions.
class ImagesApiExecutor extends GenerationExecutor {
  /// Stage 4.1 (d): in-memory blacklist параметров, не поддерживаемых
  /// моделью (выучено из 'warnings' медиа-ответа).
  static final Map<String, Set<String>> _unsupportedParamsByModel =
      <String, Set<String>>{};

  /// Выбранная пропорция изображения ('1:1', '16:9', '9:16').
  final String aspectRatio;

  static const Duration _timeout = Duration(seconds: 180);
  static const Duration _pollInterval = Duration(seconds: 4);
  static const int _maxPollAttempts = 90;

  Dio? _dio;
  CancelToken? _cancelToken;
  bool _cancelled = false;

  ImagesApiExecutor({this.aspectRatio = '1:1'});

  /// Размер холста для пропорции; неизвестные значения -> квадрат.
  static String sizeForRatio(String ratio) {
    switch (ratio.trim()) {
      case '16:9':
        return '1792x1024';
      case '9:16':
        return '1024x1792';
      default:
        return '1024x1024';
    }
  }

  @override
  Stream<GenerationEvent> run(GenerationRequest request) async* {
    _cancelled = false;
    final prompt = _promptFrom(request);
    if (prompt.isEmpty) {
      yield const GenerationFailure(
        BadRequestError(details: 'Промпт пуст — опишите изображение.'),
      );
      return;
    }
    final base = request.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final providerId =
        ModelCatalogAdapter.providerIdFromBaseUrl(base) ?? '';
    final dialect = ImageDialectResolver.resolve(
      baseUrl: base,
      providerId: providerId,
    );
    final dio = Dio(
      BaseOptions(
        connectTimeout: _timeout,
        receiveTimeout: _timeout,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    _dio = dio;
    final token = CancelToken();
    _cancelToken = token;
    try {
      final resp = await _requestImage(
        dio,
        token,
        base,
        providerId,
        dialect,
        request,
        prompt,
      );
      if (_cancelled) return;
      final status = resp.statusCode ?? 0;
      final body = resp.data ?? '';
      if (status < 200 || status >= 300) {
        yield GenerationFailure(_mapError(status, body));
        return;
      }
      _learnWarnings(body, request.model);
      var sources = _extractImageSourcesFromResponse(body);

      // Если POST /v1/media вернул асинхронную задачу (status: pending /
      // processing и id задачи без готового URL), опрашиваем GET /v1/media/{id}
      // каждые 4 секунды до статуса completed/failed.
      if (sources.isEmpty) {
        final asyncJobId = _extractAsyncJobId(body);
        if (asyncJobId != null && asyncJobId.isNotEmpty) {
          yield GenProgress(jobId: asyncJobId, percent: 10);
          await for (final st in _pollMediaStatus(
            dio: dio,
            token: token,
            base: base,
            apiKey: request.apiKey,
            jobId: asyncJobId,
          )) {
            if (_cancelled) return;
            final url = st.url;
            if (url != null && url.isNotEmpty) {
              sources = <String>[url];
              break;
            }
            yield GenProgress(jobId: asyncJobId, percent: st.percent);
          }
        }
      }

      if (_cancelled) return;
      if (sources.isEmpty) {
        yield const GenerationFailure(
          UnknownGenError(details: 'Провайдер не вернул изображение.'),
        );
        return;
      }
      final display = await _toDisplayUri(sources.first, request);
      if (_cancelled) return;
      yield GenerationDelta(content: '![изображение]($display)');
    } on GenError catch (g) {
      if (!_cancelled) yield GenerationFailure(g);
    } on DioException catch (e) {
      if (_cancelled || e.type == DioExceptionType.cancel) return;
      final t = e.type;
      if (t == DioExceptionType.connectionTimeout ||
          t == DioExceptionType.receiveTimeout ||
          t == DioExceptionType.sendTimeout) {
        yield const GenerationFailure(
          NetworkError(details: 'Провайдер не ответил за 180 секунд.'),
        );
      } else {
        yield GenerationFailure(
          NetworkError(details: 'Ошибка соединения: ${e.message ?? e}'),
        );
      }
    } on ParameterValidationException catch (e) {
      if (!_cancelled) {
        yield GenerationFailure(BadRequestError(details: e.message));
      }
    } catch (e) {
      if (!_cancelled) {
        yield GenerationFailure(
          NetworkError(details: 'Ошибка соединения: $e'),
        );
      }
    } finally {
      if (identical(_dio, dio)) _dio = null;
      if (identical(_cancelToken, token)) _cancelToken = null;
    }
  }

  /// Опрос GET {baseUrl}/media/{id} каждые 4 секунды по спецификации
  /// Polza Media API: статусы pending/processing/completed/failed,
  /// результат — `data.url` (или `output`).
  Stream<_ImagePollState> _pollMediaStatus({
    required Dio dio,
    required CancelToken token,
    required String base,
    required String apiKey,
    required String jobId,
  }) async* {
    final cleanKey = apiKey
        .trim()
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
    final headers = <String, String>{
      'Authorization': 'Bearer $cleanKey',
      'Accept': 'application/json',
    };
    for (int attempt = 1; attempt <= _maxPollAttempts; attempt++) {
      await Future<void>.delayed(_pollInterval);
      if (_cancelled) return;
      final resp = await dio.get<String>(
        '$base/media/$jobId',
        options: Options(headers: headers),
        cancelToken: token,
      );
      if (_cancelled) return;
      final code = resp.statusCode ?? 0;
      final body = resp.data ?? '';
      if (code == 401 || code == 403) {
        throw AuthError(details: _errorDetails(body));
      }
      if (code == 402) {
        throw InsufficientFunds(details: _errorDetails(body));
      }
      if (code < 200 || code >= 300) continue;

      Object? json;
      try {
        json = jsonDecode(body);
      } catch (_) {
        continue;
      }
      if (json is! Map) continue;
      final status = (json['status'] ?? json['state'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (status == 'failed' ||
          status == 'error' ||
          status == 'cancelled' ||
          status == 'canceled') {
        throw UnknownGenError(details: _errorDetails(body));
      }
      final extracted = _extractImageSourcesFromResponse(body);
      if (extracted.isNotEmpty) {
        yield _ImagePollState(url: extracted.first, percent: 100, status: status);
        return;
      }
      if (status == 'completed' ||
          status == 'succeeded' ||
          status == 'success' ||
          status == 'done') {
        yield _ImagePollState(percent: 100, status: status);
        return;
      }
      // Числового прогресса провайдер не отдал — считаем сами, чтобы
      // индикатор не зависал на 0%.
      final pct = (10.0 + attempt * 2.0).clamp(10.0, 92.0);
      yield _ImagePollState(
        percent: pct,
        status: status.isEmpty ? 'processing' : status,
      );
    }
    throw const JobTimeout(
      details: 'Генерация изображения не завершилась за отведённое время.',
    );
  }

  static String? _extractAsyncJobId(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final status = (j['status'] ?? j['state'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final id = (j['id'] ?? j['job_id'] ?? j['task_id'] ?? '')
            .toString()
            .trim();
        if (id.isNotEmpty &&
            (status.isEmpty ||
                status == 'pending' ||
                status == 'processing' ||
                status == 'queued' ||
                status == 'starting' ||
                status == 'in_progress')) {
          return id;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Один запрос картинки с учётом диалекта и автоматическим фоллбэком
  /// между /media, /images/generations и /images при ответе 404/405.
  Future<Response<String>> _requestImage(
    Dio dio,
    CancelToken token,
    String base,
    String providerId,
    ImageApiDialect dialect,
    GenerationRequest request,
    String prompt,
  ) async {
    final cleanKey = request.apiKey
        .trim()
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $cleanKey',
    };
    final info = ModelInfoResolver.resolveModel(providerId, request.model);
    final rawParams = <String, dynamic>{
      ParamKeys.aspectRatio: aspectRatio,
      ...request.parameters,
    };
    final translated = await ParameterTranslator.translateWithCatalog(
      modelId: request.model,
      rawParams: rawParams,
      fallback: () => ParameterTranslator.translate(rawParams, info),
    );
    _dropUnsupportedParams(translated, request.model);
    final isPolza = providerId == 'polza' ||
        base.toLowerCase().contains('polza.ai');
    if (isPolza) {
      final res = translated[ParamKeys.resolution];
      if (res is String && res.trim().isNotEmpty) {
        translated['image_resolution'] = res.trim();
      }
    }
    if (dialect == ImageApiDialect.openRouterChatImages) {
      return dio.post<String>(
        '$base${ImageDialectResolver.primaryPath(dialect)}',
        data: _openRouterBody(request.model, prompt, translated),
        options: Options(headers: headers),
        cancelToken: token,
      );
    }
    final body = _restBody(request.model, prompt, translated);
    // Для Polza пробуем сначала /media (единый эндпоинт Polza Media API):
    // тело {model, input: {...}, async: true} — параметры генерации лежат
    // внутри input, иначе провайдер их игнорирует.
    if (isPolza) {
      final mediaBody = <String, dynamic>{
        'model': request.model,
        'input': ParameterTranslator.toPolzaMediaInput(
          prompt,
          translated,
          isVideo: false,
        ),
        'async': true,
      };
      final mediaResp = await dio.post<String>(
        '$base/media',
        data: mediaBody,
        options: Options(headers: headers),
        cancelToken: token,
      );
      final mediaCode = mediaResp.statusCode ?? 0;
      if (mediaCode != 404 && mediaCode != 405) {
        return mediaResp;
      }
    }
    final fallback = ImageDialectResolver.fallbackRestPath(dialect);
    final first = await dio.post<String>(
      '$base${ImageDialectResolver.primaryPath(dialect)}',
      data: body,
      options: Options(headers: headers),
      cancelToken: token,
    );
    final code = first.statusCode ?? 0;
    if (fallback != null && (code == 404 || code == 405)) {
      return dio.post<String>(
        '$base$fallback',
        data: body,
        options: Options(headers: headers),
        cancelToken: token,
      );
    }
    return first;
  }

  /// Тело REST-запроса: базовые поля плюс нормализованные параметры
  /// модели (size, aspect_ratio, image_resolution ... — по её схеме).
  Map<String, dynamic> _restBody(
    String model,
    String prompt,
    Map<String, dynamic> translated,
  ) {
    final params = Map<String, dynamic>.of(translated)
      ..remove('image_config');
    return <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'n': 1,
      ...params,
    };
  }

  /// Тело запроса OpenRouter.
  Map<String, dynamic> _openRouterBody(
    String model,
    String prompt,
    Map<String, dynamic> translated,
  ) {
    final body = <String, dynamic>{
      'model': model,
      'messages': <Map<String, dynamic>>[
        <Map<String, dynamic>>{'role': 'user', 'content': prompt},
      ],
      'modalities': <String>['image', 'text'],
    };
    final cfg = <String, dynamic>{};
    final direct = translated['image_config'];
    if (direct is Map) {
      cfg.addAll(Map<String, dynamic>.from(direct));
    }
    for (final key in const <String>['aspect_ratio', 'size', 'quality']) {
      final v = translated[key];
      if (v != null && !cfg.containsKey(key)) cfg[key] = v;
    }
    if (cfg.isNotEmpty) body['image_config'] = cfg;
    return body;
  }

  static void _learnWarnings(String body, String modelId) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return;
    }
    if (json is! Map) return;
    final raw = json['warnings'];
    if (raw is! List) return;
    final patterns = <RegExp>[
      RegExp(
        r'''(?:parameter|param)\s*[`'"]?(\w+)[`'"]?\s+(?:is\s+)?not supported''',
        caseSensitive: false,
      ),
      RegExp(
        r'''(?:parameter|param)\s*[`'"]?(\w+)[`'"]?\s+(?:is\s+)?unsupported''',
        caseSensitive: false,
      ),
      RegExp(r'''[`'"]?(\w+)[`'"]?\s+ignored''', caseSensitive: false),
    ];
    for (final w in raw) {
      if (w == null) continue;
      final s = w.toString();
      for (final re in patterns) {
        final m = re.firstMatch(s);
        final name = m?.group(1);
        if (name == null || name.isEmpty) continue;
        final set =
            _unsupportedParamsByModel.putIfAbsent(modelId, () => <String>{});
        if (set.add(name)) {
          debugPrint("[media] blacklist: '$name' for $modelId (warnings)");
        }
      }
    }
  }

  static void _dropUnsupportedParams(
    Map<String, dynamic> params,
    String modelId,
  ) {
    final blocked = _unsupportedParamsByModel[modelId];
    if (blocked == null || blocked.isEmpty) return;
    for (final key in List<String>.of(params.keys)) {
      if (!blocked.contains(key)) continue;
      params.remove(key);
      debugPrint("[media] dropped unsupported param '$key' for model $modelId");
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    final t = _cancelToken;
    final d = _dio;
    _cancelToken = null;
    _dio = null;
    try {
      t?.cancel();
    } catch (_) {}
    try {
      d?.close();
    } catch (_) {}
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

  /// Универсальный парсер ответа провайдера: собирает источники из
  /// `data.url`, `output`, `url`, `image_url`, `b64_json`.
  static List<String> _extractImageSourcesFromResponse(String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return const <String>[];
    }
    final out = <String>[];
    _walkForSources(json, out, 0);
    return out;
  }

  static void _walkForSources(Object? node, List<String> out, int depth) {
    if (node == null || depth > 10 || out.length >= 8) return;
    if (node is Map) {
      node.forEach((key, value) {
        final k = key.toString().toLowerCase();
        if (value is String && value.trim().isNotEmpty) {
          final s = value.trim();
          if (k == 'b64_json') {
            out.add(s.startsWith('data:') ? s : 'data:image/png;base64,$s');
            return;
          }
          if ((k == 'url' || k == 'image_url' || k == 'output') &&
              (s.startsWith('http://') ||
                  s.startsWith('https://') ||
                  s.startsWith('data:image'))) {
            out.add(s);
          }
          return;
        }
        if (k == 'output' && value is List) {
          for (final item in value) {
            if (item is String) {
              final s = item.trim();
              if (s.startsWith('http://') ||
                  s.startsWith('https://') ||
                  s.startsWith('data:image')) {
                out.add(s);
              }
            } else {
              _walkForSources(item, out, depth + 1);
            }
          }
          return;
        }
        _walkForSources(value, out, depth + 1);
      });
      return;
    }
    if (node is List) {
      for (final e in node) {
        _walkForSources(e, out, depth + 1);
      }
    }
  }

  static Future<String> _toDisplayUri(
    String source,
    GenerationRequest request,
  ) async {
    final s = source.trim();
    final prompt = _promptFrom(request);
    final modelId = request.model;
    final cost = request.estimatedUsd;
    if (s.startsWith('data:')) {
      final local = await ArtifactMaterializer.materializeDataUrl(
        s,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      );
      if (local != null) return 'file://$local';
      return s;
    }
    if (s.startsWith('http://') || s.startsWith('https://')) {
      final local = await ArtifactMaterializer.materialize(
        s,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      );
      if (local != null) return 'file://$local';
      return s;
    }
    final local = await ArtifactMaterializer.materializeDataUrl(
      'data:image/png;base64,$s',
      prompt: prompt,
      modelId: modelId,
      cost: cost,
    );
    if (local != null) return 'file://$local';
    return s;
  }

  static String _errorDetails(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        final m = (j['error'] as Map)['message'];
        if (m != null) return m.toString();
      }
      if (j is Map && j['message'] != null) return j['message'].toString();
    } catch (_) {}
    return body.length > 300 ? body.substring(0, 300) : body;
  }

  static GenError _mapError(int code, String body) {
    final details = _errorDetails(body);
    switch (code) {
      case 401:
        return AuthError(details: details);
      case 402:
        return InsufficientFunds(details: details);
      case 429:
        return RateLimited(details: details);
      case 404:
        return ModelNotFoundError(details: details);
      case 400:
      case 422:
        return BadRequestError(details: details);
    }
    if (code >= 500) return ServerError(statusCode: code, details: details);
    return UnknownGenError(details: details);
  }
}
