// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/tool.dart';

class StreamChunk {
  final String content;
  final String reasoning;

  /// Поля события вызова инструмента (заполняются только для таких событий).
  final String? toolName;
  final String? toolArgs;
  final String? toolStatus;
  final String? toolResult;

  const StreamChunk(
    this.content,
    this.reasoning, {
    this.toolName,
    this.toolArgs,
    this.toolStatus,
    this.toolResult,
  });
}

/// Итог выполнения инструмента: признак успеха и текст для модели и интерфейса.
class ToolOutcome {
  final bool ok;
  final String text;
  const ToolOutcome(this.ok, this.text);
}

class ChatServiceException implements Exception {
  final String message;
  ChatServiceException(this.message);

  @override
  String toString() => message;
}

/// Один вызов инструмента, распознанный из ответа модели.
class _ToolCall {
  final String id;
  final String name;
  final String arguments;
  const _ToolCall({required this.id, required this.name, required this.arguments});
}

/// Накопитель частей tool_call из стрима (приходят по индексу кусками).
class _ToolCallBuilder {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  bool get isMeaningful => name.isNotEmpty;

  _ToolCall build() => _ToolCall(
        id: id,
        name: name,
        arguments: arguments.toString().trim(),
      );
}

/// Итог одного раунда обращения к модели.
class _RoundResult {
  final String content;
  final String reasoning;
  final List<_ToolCall> toolCalls;
  const _RoundResult(this.content, this.reasoning, this.toolCalls);
}

class _RoundHolder {
  _RoundResult? result;
}

class ChatService {
  /// Максимум итераций вызова инструментов, чтобы не зациклиться.
  static const int _maxToolIterations = 4;

  static const Duration _apiTimeout = Duration(seconds: 60);
  static const Duration _toolTimeout = Duration(seconds: 30);

  http.Client? _client;
  bool _wasCancelled = false;

  bool get wasCancelled => _wasCancelled;

  void cancel() {
    if (_client != null) {
      _wasCancelled = true;
      _client!.close();
      _client = null;
    }
  }

  /// Полный цикл чата с поддержкой Function Calling.
  /// Стримит контент наружу; если модель просит инструменты — выполняет их
  /// и продолжает генерацию (не более [_maxToolIterations] итераций).
  Stream<StreamChunk> sendMessage({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    bool stream = true,
    double? temperature,
    List<Tool> tools = const <Tool>[],
  }) async* {
    _wasCancelled = false;
    final history = <Map<String, dynamic>>[
      for (final m in messages) Map<String, dynamic>.of(m),
    ];

    for (int iteration = 0; iteration < _maxToolIterations; iteration++) {
      if (_wasCancelled) return;
      final holder = _RoundHolder();
      yield* _round(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        history: history,
        stream: stream,
        temperature: temperature,
        tools: tools,
        holder: holder,
      );
      final res = holder.result;
      if (res == null) return;

      if (res.toolCalls.isEmpty) {
        // Обычное завершение: без стрима отдаём ответ одним куском.
        if (!stream) yield StreamChunk(res.content, res.reasoning);
        return;
      }

      // --- Раунд с вызовами инструментов ---
      final callsPayload = <Map<String, dynamic>>[];
      final resolved = <_ToolCall>[];
      for (int i = 0; i < res.toolCalls.length; i++) {
        final c = res.toolCalls[i];
        final id = c.id.trim().isEmpty ? 'call_${iteration}_$i' : c.id.trim();
        resolved.add(_ToolCall(id: id, name: c.name, arguments: c.arguments));
        callsPayload.add({
          'id': id,
          'type': 'function',
          'function': {
            'name': c.name,
            'arguments': c.arguments.trim().isEmpty ? '{}' : c.arguments.trim(),
          },
        });
      }
      history.add({
        'role': 'assistant',
        'content': res.content,
        'tool_calls': callsPayload,
      });

      for (final call in resolved) {
        if (_wasCancelled) return;
        final args =
            call.arguments.trim().isEmpty ? '{}' : call.arguments.trim();
        // Сообщаем интерфейсу о начале вызова: появится карточка «выполняется».
        yield StreamChunk(
          '',
          '',
          toolName: call.name,
          toolArgs: args,
          toolStatus: toolStatusRunning,
        );
        final tool = _findTool(tools, call.name);
        final ToolOutcome outcome;
        if (tool == null) {
          outcome = const ToolOutcome(
            false,
            'Ошибка: инструмент не найден среди доступных.',
          );
        } else {
          outcome = await _executeTool(tool, call.arguments);
        }
        // Сообщаем интерфейсу итог: карточка переключается на готово/ошибка.
        yield StreamChunk(
          '',
          '',
          toolName: call.name,
          toolStatus: outcome.ok ? toolStatusDone : toolStatusError,
          toolResult: outcome.text,
        );
        history.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': outcome.text,
        });
      }
    }

    // Лимит итераций исчерпан: последний раунд без инструментов,
    // чтобы модель могла дать финальный ответ и не зациклиться.
    if (_wasCancelled) return;
    final holder = _RoundHolder();
    yield* _round(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      history: history,
      stream: stream,
      temperature: temperature,
      tools: const <Tool>[],
      holder: holder,
    );
    final res = holder.result;
    if (res != null && !stream) {
      yield StreamChunk(res.content, res.reasoning);
    }
  }

  Tool? _findTool(List<Tool> tools, String name) {
    for (final t in tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  /// Один запрос к /chat/completions. Стримит куски контента,
  /// итог раунда (в т.ч. tool_calls) кладёт в holder.
  Stream<StreamChunk> _round({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> history,
    required bool stream,
    double? temperature,
    required List<Tool> tools,
    required _RoundHolder holder,
  }) async* {
    final client = http.Client();
    _client = client;
    try {
      final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$base/chat/completions');
      final req = http.Request('POST', uri);
      req.headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
        'Accept': 'text/event-stream',
      });
      req.body = jsonEncode({
        'model': model,
        'messages': history,
        'stream': stream,
        if (temperature != null) 'temperature': temperature,
        if (tools.isNotEmpty) 'tools': _toolsPayload(tools),
      });

      final resp = await client.send(req).timeout(_apiTimeout);
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        throw ChatServiceException(_describeError(resp.statusCode, body));
      }

      if (!stream) {
        final body = await resp.stream.bytesToString();
        String content = '';
        String reasoning = '';
        List<_ToolCall> calls = const <_ToolCall>[];
        try {
          final j = jsonDecode(body) as Map<String, dynamic>;
          final choices = j['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final msg = (choices[0] as Map)['message'] as Map?;
            content = (msg?['content'] as String?) ?? '';
            reasoning = (msg?['reasoning_content'] as String?) ?? '';
            calls = _parseToolCalls(msg?['tool_calls'] as List?);
          }
        } catch (_) {}
        holder.result = _RoundResult(content, reasoning, calls);
        return;
      }

      // --- Стриминг ---
      final lines =
          resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      var content = '';
      var reasoning = '';
      final builders = <int, _ToolCallBuilder>{};
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final delta = (choices[0] as Map)['delta'] as Map?;
          if (delta == null) continue;

          final c = (delta['content'] as String?) ?? '';
          final r = (delta['reasoning_content'] as String?) ?? '';
          if (c.isNotEmpty || r.isNotEmpty) {
            content += c;
            reasoning += r;
            yield StreamChunk(c, r);
          }

          final rawCalls = delta['tool_calls'] as List?;
          if (rawCalls != null) {
            for (final raw in rawCalls) {
              if (raw is! Map) continue;
              final idx = (raw['index'] as int?) ?? 0;
              final b =
                  builders.putIfAbsent(idx, () => _ToolCallBuilder());
              final id = raw['id'] as String?;
              if (id != null && id.trim().isNotEmpty) b.id = id;
              final fn = raw['function'];
              if (fn is Map) {
                final n = fn['name'] as String?;
                if (n != null && n.trim().isNotEmpty) b.name = n;
                final a = fn['arguments'];
                if (a is String) b.arguments.write(a);
              }
            }
          }
        } catch (_) {
          // Битая строка потока: пропускаем.
        }
      }
      holder.result = _RoundResult(
        content,
        reasoning,
        [
          for (final b in builders.values)
            if (b.isMeaningful) b.build(),
        ],
      );
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  List<Map<String, dynamic>> _toolsPayload(List<Tool> tools) {
    return [
      for (final t in tools)
        {
          'type': 'function',
          'function': {
            'name': t.name,
            'description': t.description,
            'parameters': _decodeSchema(t.parametersSchema),
          },
        },
    ];
  }

  dynamic _decodeSchema(String raw) {
    final s = raw.trim();
    if (s.isNotEmpty) {
      try {
        final d = jsonDecode(s);
        if (d is Map<String, dynamic>) return d;
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}};
  }

  List<_ToolCall> _parseToolCalls(List? raw) {
    final out = <_ToolCall>[];
    if (raw == null) return out;
    for (final item in raw) {
      if (item is! Map) continue;
      final fn = item['function'];
      if (fn is! Map) continue;
      final name = ((fn['name'] as String?) ?? '').trim();
      if (name.isEmpty) continue;
      out.add(_ToolCall(
        id: ((item['id'] as String?) ?? '').trim(),
        name: name,
        arguments: ((fn['arguments'] as String?) ?? '').trim(),
      ));
    }
    return out;
  }

  /// Выполнение инструмента: GET (аргументы в query) или POST (JSON-тело).
  /// Любая ошибка возвращается текстом — приложение не падает.
  Future<ToolOutcome> _executeTool(Tool tool, String argumentsRaw) async {
    Map<String, dynamic> args = <String, dynamic>{};
    final raw = argumentsRaw.trim();
    if (raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) args = Map<String, dynamic>.from(d);
      } catch (_) {
        return const ToolOutcome(
          false,
          'Ошибка: модель передала некорректные аргументы (не JSON-объект).',
        );
      }
    }

    final client = http.Client();
    _client = client;
    try {
      final uri = Uri.parse(tool.endpoint.trim());
      final headers = <String, String>{...tool.headers};
      http.Response resp;
      if (tool.method.toUpperCase() == 'GET') {
        final query = <String, String>{
          for (final e in uri.queryParameters.entries) e.key: e.value,
          for (final e in args.entries) e.key: _scalar(e.value),
        };
        resp = await client
            .get(uri.replace(queryParameters: query), headers: headers)
            .timeout(_toolTimeout);
      } else {
        if (!headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
          headers['Content-Type'] = 'application/json';
        }
        resp = await client
            .post(uri, headers: headers, body: jsonEncode(args))
            .timeout(_toolTimeout);
      }
      final body = resp.body;
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return ToolOutcome(
          true,
          body.length > 20000 ? body.substring(0, 20000) : body,
        );
      }
      return ToolOutcome(
        false,
        'Ошибка HTTP ${resp.statusCode}: '
            '${body.length > 500 ? body.substring(0, 500) : body}',
      );
    } on TimeoutException {
      return const ToolOutcome(
        false,
        'Ошибка: инструмент не ответил за 30 секунд.',
      );
    } catch (e) {
      return ToolOutcome(false, 'Ошибка вызова инструмента: $e');
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  String _scalar(Object? v) => v?.toString() ?? '';

  String _describeError(int code, String body) {
    switch (code) {
      case 401:
        return 'Неверный API-ключ (401). Проверьте его в настройках.';
      case 402:
        return 'Недостаточно средств на балансе (402).';
      case 429:
        return 'Слишком много запросов (429). Подождите немного.';
    }
    return 'Ошибка $code: ${_extractError(body)}';
  }

  String _extractError(String body) {
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
}
