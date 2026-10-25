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

    final isResponses = tool.apiType == Tool.apiResponses;
    final uri = Uri.tryParse(
      '$base/${isResponses ? 'responses' : 'chat/completions'}',
    );
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const ToolOutcome(
        false,
        'Ошибка: Base URL должен начинаться с http:// или https://.',
      );
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
      final resp = await client
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${tool.apiKey}',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      final text = resp.body;
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return ToolOutcome(
          false,
          'Ошибка HTTP ${resp.statusCode}: ${_clip(text, 500)}',
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
    } catch (e) {
      return ToolOutcome(false, 'Ошибка вызова модели-инструмента: $e');
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
