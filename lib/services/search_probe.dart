// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Итог проверки поддержки серверного веб-поиска провайдером.
enum WebSearchProbeResult {
  /// Ответ 200: провайдер принял запрос с инструментом web_search.
  supported,

  /// Ответ 400: провайдер отклонил инструмент web_search.
  unsupported,

  /// Сетевая ошибка, таймаут либо иной код ответа.
  error,
}

/// Лёгкая проверка поддержки серверного веб-поиска.
///
/// POST {baseUrl}/chat/completions с минимальным телом:
/// модель, одно сообщение 'ping', max_tokens: 1 и
/// tools: [{'type': 'web_search'}]. Ответ 200 — поиск поддерживается,
/// 400 — не поддерживается. Функция никогда не бросает исключений:
/// любые сбои возвращаются как [WebSearchProbeResult.error].
Future<WebSearchProbeResult> probeWebSearchSupport({
  required String baseUrl,
  required String apiKey,
  required String model,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.tryParse('$base/chat/completions');
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      model.trim().isEmpty) {
    return WebSearchProbeResult.error;
  }
  final client = http.Client();
  try {
    final resp = await client
        .post(
          uri,
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(<String, dynamic>{
            'model': model.trim(),
            'messages': <Map<String, String>>[
              <String, String>{'role': 'user', 'content': 'ping'},
            ],
            'max_tokens': 1,
            'stream': false,
            'tools': <Map<String, String>>[
              <String, String>{'type': 'web_search'},
            ],
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return WebSearchProbeResult.supported;
    }
    if (resp.statusCode == 400) {
      return WebSearchProbeResult.unsupported;
    }
    return WebSearchProbeResult.error;
  } on TimeoutException {
    return WebSearchProbeResult.error;
  } catch (_) {
    return WebSearchProbeResult.error;
  } finally {
    client.close();
  }
}
