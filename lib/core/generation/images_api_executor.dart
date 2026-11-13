// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:dio/dio.dart';

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

/// Исполнитель генерации изображений (HTTP через dio).
///
/// Работает с тремя диалектами API ([ImageApiDialect]):
///  - openAiStandard: POST {baseUrl}/images/generations (Polza и другие
///    OpenAI-совместимые провайдеры);
///  - shortImagesPath: POST {baseUrl}/images (RouterAI);
///  - openRouterChatImages: POST {baseUrl}/chat/completions с полями
///    modalities и image_config (OpenRouter).
///
/// Параметры генерации (size, aspect_ratio, resolution и т.п.) собираются
/// по generationSchema модели через [ParameterTranslator] и вливаются
/// в тело POST-запроса; для диалекта OpenRouter — внутри image_config.
/// Если основной REST-эндпоинт ответил 404/405, запрос автоматически
/// повторяется на альтернативном эндпоинте.
///
/// Промпт берётся из последнего пользовательского сообщения [GenerationRequest].
/// Результат отдаётся одним событием [GenerationDelta] с markdown-изображением:
/// ссылка провайдера либо file://-путь локальной копии (URL и data URL
/// сохраняются через [ArtifactMaterializer]). Ошибка — последнее событие
/// [GenerationFailure] с типизированным [GenError].
class ImagesApiExecutor extends GenerationExecutor {
  /// Выбранная пропорция изображения ('1:1', '16:9', '9:16').
  final String aspectRatio;

  static const Duration _timeout = Duration(seconds: 180);

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
    final dialect = ImageDialectResolver.resolve(
      baseUrl: base,
      providerId: ModelCatalogAdapter.providerIdFromBaseUrl(base) ?? '',
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
        dio, token, base, dialect, request, prompt,
      );
      if (_cancelled) return;
      final status = resp.statusCode ?? 0;
      final body = resp.data ?? '';
      if (status < 200 || status >= 300) {
        yield GenerationFailure(_mapError(status, body));
        return;
      }
      final sources = _extractImageSourcesFromResponse(body);
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

  /// Один запрос картинки с учётом диалекта и автоматическим фоллбэком
  /// между /images/generations и /images при ответе 404/405.
  Future<Response<String>> _requestImage(
    Dio dio,
    CancelToken token,
    String base,
    ImageApiDialect dialect,
    GenerationRequest request,
    String prompt,
  ) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${request.apiKey}',
    };
    // Сведения о модели (эвристика по идентификатору, каталог в
    // исполнителе недоступен) и нормализация параметров под её
    // generationSchema: какие поля и в каком виде ожидает провайдер.
    final providerId = ModelCatalogAdapter.providerIdFromBaseUrl(base) ?? '';
    final info = ModelInfoResolver.resolveModel(providerId, request.model);
    // Параметры из панели ввода (aspect_ratio, quality) поверх выбранной
    // конструктором пропорции: нормализуются по схеме/каталогу модели.
    final rawParams = <String, dynamic>{
      ParamKeys.aspectRatio: aspectRatio,
      ...request.parameters,
    };
    final translated = await ParameterTranslator.translateWithCatalog(
      modelId: request.model,
      rawParams: rawParams,
      fallback: () => ParameterTranslator.translate(rawParams, info),
    );
    if (dialect == ImageApiDialect.openRouterChatImages) {
      return dio.post<String>(
        '$base${ImageDialectResolver.primaryPath(dialect)}',
        data: _openRouterBody(request.model, prompt, translated),
        options: Options(headers: headers),
        cancelToken: token,
      );
    }
    final fallback = ImageDialectResolver.fallbackRestPath(dialect);
    final body = _restBody(request.model, prompt, translated);
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

  /// Тело запроса OpenRouter: изображения приходят через chat/completions
  /// с явным перечислением модальностей; параметры генерации собираются
  /// в image_config — из результата translate либо из плоских ключей,
  /// если модель не сообщила openRouterChatConfig-схему.
  Map<String, dynamic> _openRouterBody(
    String model,
    String prompt,
    Map<String, dynamic> translated,
  ) {
    final body = <String, dynamic>{
      'model': model,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': prompt},
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

  /// Промпт — текст последнего пользовательского сообщения
  /// (строка либо массив частей с текстовыми блоками).
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

  /// Универсальный парсер ответа провайдера: рекурсивный обход JSON
  /// собирает все источники изображений — поля url/image_url (http, https,
  /// data URL) и b64_json (оборачивается в data URL). Работает для
  /// формата {data: [...]}, {images: [...]}, {url: ...} и для ответа
  /// OpenRouter (choices -> message -> images / content).
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
          if ((k == 'url' || k == 'image_url') &&
              (s.startsWith('http://') ||
                  s.startsWith('https://') ||
                  s.startsWith('data:image'))) {
            out.add(s);
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

  /// Источник из ответа -> URI для markdown. URL и data URL сохраняются
  /// локально (ссылки провайдеров часто временные); при неудаче остаётся
  /// исходная ссылка — картинка всё равно отображается в чате.
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
    // Сырой base64 без префикса: считаем PNG.
    final local = await ArtifactMaterializer.materializeDataUrl(
      'data:image/png;base64,$s',
      prompt: prompt,
      modelId: modelId,
      cost: cost,
    );
    if (local != null) return 'file://$local';
    return s;
  }

  /// Текст ошибки провайдера из JSON-ответа (error.message / message).
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

  /// Перевод кода ответа в типизированную [GenError].
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
