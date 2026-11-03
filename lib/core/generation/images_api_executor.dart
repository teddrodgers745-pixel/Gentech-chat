// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/gen_error.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';

/// Исполнитель генерации изображений: запрос к OpenAI-совместимому
/// эндпоинту POST {baseUrl}/images/generations.
///
/// Промпт берётся из последнего пользовательского сообщения [GenerationRequest];
/// пропорция задаётся при создании исполнителя и переводится в размер холста
/// (поле size). Результат отдаётся одним событием [GenerationDelta] с
/// markdown-изображением: ссылка провайдера либо file://-путь, если провайдер
/// вернул base64 (файл сохраняется в Documents/GenTech/images). Ошибка —
/// последнее событие [GenerationFailure] с типизированным [GenError].
class ImagesApiExecutor extends GenerationExecutor {
  /// Выбранная пропорция изображения ('1:1', '16:9', '9:16').
  final String aspectRatio;

  static const Duration _timeout = Duration(seconds: 180);

  http.Client? _client;
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
    final client = http.Client();
    _client = client;
    try {
      final resp = await client
          .post(
            Uri.parse('$base/images/generations'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${request.apiKey}',
            },
            body: jsonEncode(<String, dynamic>{
              'model': request.model,
              'prompt': prompt,
              'n': 1,
              'size': sizeForRatio(aspectRatio),
            }),
          )
          .timeout(_timeout);
      if (_cancelled) return;
      if (resp.statusCode != 200) {
        yield GenerationFailure(_mapError(resp.statusCode, resp.body));
        return;
      }
      final imageUri = await _extractImageUri(resp.body);
      if (_cancelled) return;
      if (imageUri == null || imageUri.isEmpty) {
        yield const GenerationFailure(
          UnknownGenError(details: 'Провайдер не вернул изображение.'),
        );
        return;
      }
      yield GenerationDelta(content: '![изображение]($imageUri)');
    } on TimeoutException {
      if (!_cancelled) {
        yield const GenerationFailure(
          NetworkError(details: 'Провайдер не ответил за 180 секунд.'),
        );
      }
    } catch (e) {
      if (!_cancelled) {
        yield GenerationFailure(NetworkError(details: 'Ошибка соединения: $e'));
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _client?.close();
    _client = null;
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

  /// Из ответа берётся url либо b64_json первой картинки;
  /// base64 сохраняется локально и отдаётся как file://-ссылка.
  static Future<String?> _extractImageUri(String body) async {
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final data = j['data'];
      if (data is! List || data.isEmpty) return null;
      final first = data.first;
      if (first is! Map) return null;
      final url = ((first['url'] as String?) ?? '').trim();
      if (url.isNotEmpty) return url;
      final b64 = ((first['b64_json'] as String?) ?? '').trim();
      if (b64.isEmpty) return null;
      final path = await _saveBase64(b64);
      return 'file://$path';
    } catch (_) {
      return null;
    }
  }

  static Future<String> _saveBase64(String b64) async {
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/GenTech/images');
    await folder.create(recursive: true);
    final file = File(
      '${folder.path}/img_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(base64Decode(b64), flush: true);
    return file.path;
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
