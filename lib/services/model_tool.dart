// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/tool.dart';
import 'chat_service.dart';

/// Выполнение «модели-инструмента»: отдельный запрос к другой модели
/// по OpenAI-совместимому API (chat/completions либо responses).
/// Адрес, ключ и модель задаёт пользователь в редакторе инструмента.
class ModelToolRunner {
  static const Duration _timeout = Duration(seconds: 60);

  static Future<ToolOutcome> run(Tool tool, String argumentsRaw) async {
    final args = <String, dynamic>{};
    final raw = argumentsRaw.trim();
    if (raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) args.addAll(Map<String, dynamic>.from(d));
      } catch (_) {
        return const ToolOutcome(
          false,
          'Ошибка: модель передала некорректные аргументы (не JSON-объект).',
        );
      }
    }

    final prompt = _promptFromArgs(args);
    if (prompt.trim().isEmpty) {
      return const ToolOutcome(
        false,
        'Ошибка: не удалось сформировать запрос из аргументов вызова.',
      );
    }

    final base = tool.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      return const ToolOutcome(
        false,
        'Ошибка: у инструмента не задан Base URL.',
      );
    }
    if (tool.modelId.trim().isEmpty) {
      return const ToolOutcome(
        false,
        'Ошибка: у инструмента не задана модель.',
      );
    }

    final baseUri = Uri.tryParse(base);
    if (baseUri == null ||
        (baseUri.scheme != 'http' && baseUri.scheme != 'https') ||
        !baseUri.hasAuthority ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment) {
      return const ToolOutcome(
        false,
        'Ошибка: Base URL инструмента должен быть абсолютным HTTP(S)-адресом '
            'без учётных данных, параметров запроса и фрагмента.',
      );
    }

    final isResponses = tool.apiType == Tool.apiResponses;
    final uri = Uri.tryParse(
      '$base/${isResponses ? 'responses' : 'chat/completions'}',
    );
    if (uri == null ||
        uri.scheme != baseUri.scheme ||
        uri.host != baseUri.host ||
        uri.port != baseUri.port) {
      return const ToolOutcome(
        false,
        'Ошибка: не удалось сформировать адрес модели-инструмента.',
      );
    }

    // Заголовки принадлежат самому инструменту, а не текущему подключению.
    // Не допускаем неоднозначных заголовков и подмены HTTP-адресата.
    final headers = <String, String>{};
    final headerNames = <String>{};
    for (final entry in tool.headers.entries) {
      final name = entry.key.trim().toLowerCase();
      if (name.isEmpty ||
          !headerNames.add(name) ||
          name == 'host' ||
          name == 'content-length' ||
          name == 'transfer-encoding') {
        return const ToolOutcome(
          false,
          'Ошибка: некорректные или дублирующиеся заголовки инструмента.',
        );
      }
      headers[entry.key.trim()] = entry.value;
    }

    if (!headerNames.contains('content-type')) {
      headers['Content-Type'] = 'application/json';
    }
    if (!headerNames.contains('authorization')) {
      final key = tool.apiKey
          .trim()
          .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
    }

    final client = http.Client();
    try {
      final body = isResponses
          ? <String, dynamic>{
              'model': tool.modelId.trim(),
              'input': prompt,
              'stream': false,
            }
          : <String, dynamic>{
              'model': tool.modelId.trim(),
              'messages': <Map<String, String>>[
                {'role': 'user', 'content': prompt},
              ],
              'stream': false,
            };
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll(headers)
        ..body = jsonEncode(body);
      final resp = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_timeout);
      final text = resp.body;
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return ToolOutcome(
          false,
          'Ошибка HTTP ${resp.statusCode} при вызове модели-инструмента.',
        );
      }
      try {
        final j = jsonDecode(text);
        if (j is Map) {
          final out = isResponses
              ? _fromResponses(Map<String, dynamic>.from(j))
              : _fromChatCompletions(Map<String, dynamic>.from(j));
          if (out.trim().isNotEmpty) {
            return ToolOutcome(true, _clip(out, 20000));
          }
        }
      } catch (_) {}
      // Формат не распознался — отдаём сырой текст ответа.
      return ToolOutcome(true, _clip(text, 20000));
    } on TimeoutException {
      return const ToolOutcome(
        false,
        'Ошибка: модель-инструмент не ответила за 60 секунд.',
      );
    } catch (_) {
      return const ToolOutcome(
        false,
        'Ошибка вызова модели-инструмента.',
      );
    } finally {
      client.close();
    }
  }

  /// Промпт из аргументов вызова: берём узнаваемое текстовое поле,
  /// иначе единственную строку-аргумент, иначе весь JSON.
  static String _promptFromArgs(Map<String, dynamic> args) {
    for (final key in const [
      'prompt',
      'input',
      'query',
      'text',
      'question',
      'message',
      'request',
    ]) {
      final v = args[key];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    if (args.isEmpty) return '';
    if (args.length == 1) {
      final only = args.values.first;
      if (only is String) return only;
    }
    try {
      return jsonEncode(args);
    } catch (_) {
      return args.toString();
    }
  }

  /// Ответ /chat/completions: текст первого выбора.
  static String _fromChatCompletions(Map<String, dynamic> j) {
    final choices = j['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final first = choices.first;
    if (first is! Map) return '';
    final msg = first['message'];
    if (msg is Map) {
      return ((msg['content'] as String?) ?? '').trim();
    }
    return ((first['text'] as String?) ?? '').trim();
  }

  /// Ответ /responses: output_text либо обход output -> content.
  static String _fromResponses(Map<String, dynamic> j) {
    final direct = j['output_text'];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    final out = j['output'] as List?;
    if (out == null) return '';
    final buf = StringBuffer();
    for (final item in out) {
      if (item is! Map) continue;
      final content = item['content'] as List?;
      if (content == null) continue;
      for (final part in content) {
        if (part is Map && part['type'] == 'output_text') {
          final t = part['text'];
          if (t is String) buf.write(t);
        }
      }
    }
    return buf.toString().trim();
  }

  static String _clip(String s, int max) {
    if (s.length <= max) return s;
    return s.substring(0, max);
  }
}
