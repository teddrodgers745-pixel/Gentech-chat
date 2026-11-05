// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_state.dart';

/// Обогащение тела запроса /chat/completions поиском.
///
/// Режимы ([searchMode]):
///  - 'provider' — серверный поиск провайдера: в тело добавляется
///    поле web_search = true;
///  - 'modelAsTool' — отдельный запрос к модели-инструменту
///    ([searchModelId]) с промптом «Найди информация: <запрос>»;
///    полученный ответ добавляется в body['messages'] системным
///    сообщением «Результаты поиска: ...»;
///  - остальные режимы — тело не меняется.
///
/// Любая ошибка поиска (сеть, таймаут, формат ответа) не роняет
/// основной запрос: возвращается исходное тело без изменений.
Future<Map<String, dynamic>> enhanceRequestWithSearch(
  Map<String, dynamic> requestBody,
  String query,
  String searchMode,
  String? searchModelId,
) async {
  if (searchMode == 'provider') {
    requestBody['web_search'] = true;
    return requestBody;
  }
  if (searchMode == 'modelAsTool') {
    final modelId = (searchModelId ?? '').trim();
    if (modelId.isEmpty) return requestBody;
    final q = query.trim();
    if (q.isEmpty) return requestBody;
    final cfg = effectiveConfig();
    final base = cfg.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final key = cfg.apiKey.trim();
    if (base.isEmpty || key.isEmpty) return requestBody;
    final uri = Uri.tryParse('$base/chat/completions');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return requestBody;
    }
    try {
      final resp = await http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(<String, dynamic>{
              'model': modelId,
              'messages': <Map<String, String>>[
                <String, String>{
                  'role': 'user',
                  'content': 'Найди информацию: $q',
                },
              ],
              'stream': false,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return requestBody;
      }
      final result = _answerText(resp.body);
      if (result.isEmpty) return requestBody;
      final messages = requestBody['messages'];
      if (messages is List) {
        messages.add(<String, dynamic>{
          'role': 'system',
          'content': 'Результаты поиска: $result',
        });
      }
    } catch (_) {
      // Сбой поиска не должен ломать основной запрос.
    }
  }
  return requestBody;
}

/// Текст ответа /chat/completions: content первого выбора; '' — не найден.
String _answerText(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) return '';
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return '';
    }
    final msg = (choices.first as Map)['message'];
    if (msg is Map) {
      final c = msg['content'];
      if (c is String) return c.trim();
    }
  } catch (_) {}
  return '';
}
