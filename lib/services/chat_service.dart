// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_state.dart';
import '../core/auth/polza_auth_service.dart';
import '../core/generation/search_capability_resolver.dart';
import '../core/providers/heuristic_rules.dart';
import '../core/providers/model_catalog_adapter.dart';
import '../core/search/search_controller.dart';
import '../core/utils/reasoning_mapper.dart';
import '../core/utils/stream_pacer.dart';
import '../models/chat_message.dart';
import '../models/tool.dart';
import 'model_tool.dart';
import 'search_enhancer.dart';

class StreamChunk {
  final String content;
  final String reasoning;
  final String? toolName;
  final String? toolArgs;
  final String? toolStatus;
  final String? toolResult;
  final Map<String, dynamic>? usage;
  final List<String> sources;

  const StreamChunk(
    this.content,
    this.reasoning, {
    this.toolName,
    this.toolArgs,
    this.toolStatus,
    this.toolResult,
    this.usage,
    this.sources = const <String>[],
  });
}

class ChatResult {
  final String text;
  final Map<String, dynamic>? usage;

  const ChatResult({this.text = '', this.usage});
}

class PickedFileRef {
  final String name;
  final String path;
  const PickedFileRef(this.name, this.path);
}

const int kMaxAttachmentBytes = 8 * 1024 * 1024;

const String kFileBlockInstruction =
    'Если пользователь просит создать файл (HTML, Python, Markdown и т.д.), '
    'ты ДОЛЖЕН выдавать его в блоке кода с указанием имени файла, '
    'например: ```html name=index.html или ```python name=script.py.';

class ToolOutcome {
  final bool ok;
  final String text;
  const ToolOutcome(this.ok, this.text);
}

class ChatServiceException implements Exception {
  final String message;
  final int? statusCode;
  final String url;
  final String tokenPrefix;

  ChatServiceException(
    this.message, {
    this.statusCode,
    this.url = '',
    this.tokenPrefix = '',
  });

  @override
  String toString() => message;
}

class _ToolCall {
  final String id;
  final String name;
  final String arguments;
  const _ToolCall({required this.id, required this.name, required this.arguments});
}

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

class _RoundResult {
  final String content;
  final String reasoning;
  final List<_ToolCall> toolCalls;
  final Map<String, dynamic>? usage;
  final List<String> sources;

  const _RoundResult(
    this.content,
    this.reasoning,
    this.toolCalls, {
    this.usage,
    this.sources = const <String>[],
  });
}

class _RoundHolder {
  _RoundResult? result;
}

class ChatService {
  static const int _maxToolIterations = 4;

  static Future<dynamic> buildUserContent(
    String text,
    List<PickedFileRef> files,
  ) async {
    const mime = <String, String>{
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'gif': 'image/gif',
    };
    const textExt = <String>{'txt', 'md', 'json', 'dart', 'csv', 'log'};

    final images = <Map<String, dynamic>>[];
    final extra = <String>[];
    for (final f in files) {
      try {
        final ext = f.name.contains('.')
            ? f.name.substring(f.name.lastIndexOf('.') + 1).toLowerCase()
            : '';
        final file = File(f.path);
        if (mime.containsKey(ext)) {
          final len = await file.length();
          if (len > kMaxAttachmentBytes) {
            extra.add('(файл ${f.name} пропущен: больше 8 МБ)');
            continue;
          }
          final bytes = await file.readAsBytes();
          images.add(<String, dynamic>{
            'type': 'image_url',
            'image_url': <String, dynamic>{
              'url': 'data:${mime[ext]};base64,${base64Encode(bytes)}',
            },
          });
        } else if (textExt.contains(ext)) {
          final content = await file.readAsString();
          extra.add('Содержимое файла ${f.name}:\n$content');
        }
      } catch (_) {
        extra.add('(файл ${f.name} не удалось прочитать)');
      }
    }

    final parts = <String>[
      if (text.trim().isNotEmpty) text,
      ...extra,
    ];
    final full = parts.join('\n\n');
    if (images.isEmpty) return full;
    return <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': full},
      ...images,
    ];
  }

  static const Duration _apiTimeout = Duration(seconds: 60);
  static const Duration _toolTimeout = Duration(seconds: 30);

  http.Client? _client;
  bool _wasCancelled = false;
  bool _searchPending = false;
  StreamPacer? _activePacer;
  StreamPacer? get activePacer => _activePacer;

  bool get wasCancelled => _wasCancelled;

  void cancel() {
    if (_client != null) {
      _wasCancelled = true;
      _client!.close();
      _client = null;
    }
  }

  Stream<StreamChunk> sendMessage({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    bool stream = true,
    double? temperature,
    String? reasoningEffort,
    List<Tool> tools = const <Tool>[],
  }) async* {
    _wasCancelled = false;
    _searchPending = true;
    final effectiveStream = stream &&
        HeuristicRules.inferRoute(HeuristicRules.normalize(model)).isChat;
    final history = <Map<String, dynamic>>[
      for (final m in messages) Map<String, dynamic>.of(m),
    ];
    final StreamPacer? pacer =
        effectiveStream ? (_activePacer = StreamPacer()) : null;

    for (int iteration = 0; iteration < _maxToolIterations; iteration++) {
      if (_wasCancelled) return;
      final holder = _RoundHolder();
      yield* _pacedRound(
        pacer: pacer,
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        history: history,
        stream: effectiveStream,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
        tools: tools,
        holder: holder,
      );
      final res = holder.result;
      if (res == null) return;

      if (res.toolCalls.isEmpty) {
        if (!effectiveStream) {
          yield StreamChunk(
            res.content,
            res.reasoning,
            usage: res.usage,
            sources: res.sources,
          );
        }
        return;
      }

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
        } else if (tool.isModel) {
          outcome = await ModelToolRunner.run(tool, call.arguments);
        } else {
          outcome = await _executeTool(tool, call.arguments);
        }
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

    if (_wasCancelled) return;
    final holder = _RoundHolder();
    yield* _pacedRound(
      pacer: pacer,
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      history: history,
      stream: effectiveStream,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      tools: const <Tool>[],
      holder: holder,
    );
    final res = holder.result;
    if (res != null && !effectiveStream) {
      yield StreamChunk(
        res.content,
        res.reasoning,
        usage: res.usage,
        sources: res.sources,
      );
    }
  }

  Stream<StreamChunk> _pacedRound({
    required StreamPacer? pacer,
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> history,
    required bool stream,
    double? temperature,
    String? reasoningEffort,
    required List<Tool> tools,
    required _RoundHolder holder,
  }) {
    final src = _round(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      history: history,
      stream: stream,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      tools: tools,
      holder: holder,
    );
    final p = pacer;
    if (p == null) return src;
    return _pacedStream(p, src);
  }

  Stream<StreamChunk> _pacedStream(StreamPacer pacer, Stream<StreamChunk> src) {
    final out = StreamController<StreamChunk>();
    StreamSubscription<StreamChunk>? sub;

    void cleanup() {
      sub?.cancel();
      sub = null;
      pacer.onTick = null;
      pacer.stop();
      if (identical(_activePacer, pacer)) _activePacer = null;
    }

    pacer.onTick = (portion) {
      if (!out.isClosed) out.add(StreamChunk(portion, ''));
    };
    _activePacer = pacer;
    pacer.start();

    sub = src.listen(
      (chunk) {
        if (out.isClosed) return;
        if (chunk.toolName != null ||
            chunk.usage != null ||
            chunk.sources.isNotEmpty) {
          out.add(chunk);
        }
        if (chunk.reasoning.isNotEmpty) {
          out.add(StreamChunk('', chunk.reasoning));
        }
        if (chunk.content.isNotEmpty) pacer.add(chunk.content);
      },
      onError: (Object e) {
        if (out.isClosed) return;
        out.addError(e);
        cleanup();
        out.close();
      },
      onDone: () {
        if (out.isClosed) return;
        final rest = pacer.flush();
        if (rest.isNotEmpty) out.add(StreamChunk(rest, ''));
        cleanup();
        out.close();
      },
      cancelOnError: false,
    );

    out.onCancel = () {
      cleanup();
    };
    return out.stream;
  }

  Future<ChatResult> sendMessageResult({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    String? reasoningEffort,
    List<Tool> tools = const <Tool>[],
  }) async {
    _searchPending = true;
    final holder = _RoundHolder();
    await _round(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      history: <Map<String, dynamic>>[
        for (final m in messages) Map<String, dynamic>.of(m),
      ],
      stream: false,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      tools: tools,
      holder: holder,
    ).toList();
    final res = holder.result;
    return ChatResult(text: res?.content ?? '', usage: res?.usage);
  }

  Tool? _findTool(List<Tool> tools, String name) {
    for (final t in tools) {
      if (t.name == name) return t;
    }
    return null;
  }

  static bool _isRouterAI(String baseUrl) =>
      ModelCatalogAdapter.providerIdFromBaseUrl(baseUrl) == 'routerai' ||
      baseUrl.trim().toLowerCase().contains('routerai');

  static bool _isPolza(String baseUrl) =>
      ModelCatalogAdapter.providerIdFromBaseUrl(baseUrl) == 'polza' ||
      baseUrl.trim().toLowerCase().contains('polza.ai');

  /// Признак «reasoning обязателен» (mandatory: true) из каталога Polza.
  ///
  /// Задача 2б прокидывает сюда поле из ActiveModelCapabilities
  /// (reasoningNoneAllowed). Пока каталог не подключён, блок reasoning
  /// отправляется как обычно.
  static bool Function(String model)? reasoningMandatoryProbe;

  static bool _reasoningMandatoryFor(String model) {
    try {
      return reasoningMandatoryProbe?.call(model) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> _buildReasoningPayload({
    required String baseUrl,
    required String model,
    required String? reasoningEffort,
  }) {
    final effort = (reasoningEffort ?? '').trim().toLowerCase();
    if (effort.isEmpty) return const <String, dynamic>{};

    if (_isPolza(baseUrl)) {
      // Polza принимает reasoning.effort как есть, без ремаппинга:
      // low остаётся low, xhigh/max — как есть, неизвестное значение
      // тоже не подменяется и не блокируется (провайдер решает сам).
      // Верхнеуровневый reasoning_effort Polza игнорирует — отправляем
      // объект {"reasoning": {"effort": ...}}.
      if (effort == 'off' || effort == 'none') {
        // Если каталог объявил reasoning обязательным (mandatory: true),
        // отключить его нельзя — блок не отправляется вовсе.
        if (_reasoningMandatoryFor(model)) {
          return const <String, dynamic>{};
        }
        // none — легальное значение: «рассуждения отключены».
        return <String, dynamic>{
          'reasoning': <String, dynamic>{'effort': 'none'},
        };
      }
      return <String, dynamic>{
        'reasoning': <String, dynamic>{'effort': effort},
      };
    }

    if (effort == 'off' || effort == 'none') {
      return const <String, dynamic>{};
    }

    if (_isRouterAI(baseUrl)) {
      var routerEffort = effort;
      if (effort == 'max' || effort == 'xhigh') routerEffort = 'high';
      if (effort == 'minimal' || effort == 'min') routerEffort = 'low';
      return <String, dynamic>{
        'reasoning_effort': routerEffort,
      };
    }
    final mapped = ReasoningMapper.mapToApi(
      ReasoningMapper.fromId(effort),
      model,
    );
    return mapped.isNotEmpty
        ? mapped
        : <String, dynamic>{'reasoning_effort': effort};
  }

  Stream<StreamChunk> _round({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> history,
    required bool stream,
    double? temperature,
    String? reasoningEffort,
    required List<Tool> tools,
    required _RoundHolder holder,
  }) async* {
    final normalizedEffort = (reasoningEffort ?? '').trim().toLowerCase();
    final canRetry = _isRouterAI(baseUrl) &&
        (normalizedEffort == 'high' || normalizedEffort == 'max');
    try {
      await for (final chunk in _roundOnce(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        history: history,
        stream: stream,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
        tools: tools,
        holder: holder,
      )) {
        yield chunk;
      }
    } on ChatServiceException catch (e) {
      if (canRetry && e.statusCode == 400 && !_wasCancelled) {
        yield* _roundOnce(
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
          history: history,
          stream: stream,
          temperature: temperature,
          reasoningEffort: 'high',
          tools: tools,
          holder: holder,
        );
        return;
      }
      if (e.statusCode == 401 &&
          !_wasCancelled &&
          baseUrl.trim().toLowerCase().contains('polza.ai')) {
        debugPrint('[auth] polza 401: logout, нужен повторный вход');
        try {
          await polzaAuth.logout();
        } catch (_) {}
      }
      rethrow;
    }
    if (!canRetry || _wasCancelled) return;
    final res = holder.result;
    if (res == null) return;
    final isEmpty = res.content.trim().isEmpty &&
        res.reasoning.trim().isEmpty &&
        res.toolCalls.isEmpty;
    if (!isEmpty) return;
    yield* _roundOnce(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      history: history,
      stream: stream,
      temperature: temperature,
      reasoningEffort: 'high',
      tools: tools,
      holder: holder,
    );
  }

  Stream<StreamChunk> _roundOnce({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> history,
    required bool stream,
    double? temperature,
    String? reasoningEffort,
    required List<Tool> tools,
    required _RoundHolder holder,
  }) async* {
    final client = http.Client();
    _client = client;
    try {
      final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$base/chat/completions');
      final builtin = _builtinToolsPayload();
      final reasoningPayload = _buildReasoningPayload(
        baseUrl: base,
        model: model,
        reasoningEffort: reasoningEffort,
      );
      Map<String, dynamic> bodyMap = {
        'model': model,
        'messages': history,
        'stream': stream,
        if (stream)
          'stream_options': <String, dynamic>{'include_usage': true},
        if (temperature != null) 'temperature': temperature,
        ...reasoningPayload,
        if (tools.isNotEmpty || builtin.isNotEmpty)
          'tools': <Map<String, dynamic>>[
            ...builtin,
            if (tools.isNotEmpty) ..._toolsPayload(tools),
          ],
      };
      if (_searchPending) {
        _searchPending = false;
        try {
          bodyMap = await enhanceRequestWithSearch(
            bodyMap,
            _lastUserText(history),
            settings.searchMode,
            settings.searchToolModel,
          );
        } catch (_) {}
      }
      final nativeSearchActive = chatSearch.enabled &&
          SearchCapabilityResolver.supportsNativeSearch(model);
      if (settings.webSearchSupported || nativeSearchActive) {
        final existing = bodyMap['tools'];
        final list = <Map<String, dynamic>>[
          if (existing is List)
            for (final t in existing)
              if (t is Map) Map<String, dynamic>.from(t),
        ];
        var hasSearch = false;
        for (final t in list) {
          if ((t['type'] ?? '').toString() == 'web_search') hasSearch = true;
        }
        if (!hasSearch) list.add(<String, dynamic>{'type': 'web_search'});
        bodyMap['tools'] = list;
      }
      final droppedParams = <String>{};
      final cleanKey = apiKey
          .trim()
          .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
      final requestHeaders = <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $cleanKey',
        'Accept': stream ? 'text/event-stream' : 'application/json',
      };
      final firstReq = http.Request('POST', uri)
        ..headers.addAll(requestHeaders);
      firstReq.body = jsonEncode(bodyMap);
      var resp = await client.send(firstReq).timeout(_apiTimeout);
      String? resp400Body;
      if (resp.statusCode == 400) {
        final errBody = await resp.stream.bytesToString();
        final param = _invalidParamFrom400(errBody);
        if (param != null && droppedParams.add(param)) {
          debugPrint("[retry] dropped param '$param' after 400");
          bodyMap.remove(param);
          final retryReq = http.Request('POST', uri)
            ..headers.addAll(requestHeaders);
          retryReq.body = jsonEncode(bodyMap);
          resp = await client.send(retryReq).timeout(_apiTimeout);
        } else {
          resp400Body = errBody;
        }
      }
      if (resp.statusCode != 200) {
        final body = resp400Body ??
            await resp.stream.bytesToString();
        final cond = cleanKey.length > 8;
        final tokenPrefix = cond
            ? '${cleanKey.substring(0, 8)}'
                '...${cleanKey.substring(cleanKey.length - 8)}'
            : 'SHORT...';
        throw ChatServiceException(
          _describeError(
            resp.statusCode,
            body,
            baseUrl: base,
            tokenPrefix: tokenPrefix,
          ),
          statusCode: resp.statusCode,
          url: '$base/chat/completions',
          tokenPrefix: tokenPrefix,
        );
      }

      if (!stream) {
        final body = await resp.stream.bytesToString();
        String content = '';
        String reasoning = '';
        List<_ToolCall> calls = const <_ToolCall>[];
        Map<String, dynamic>? usage;
        final sources = <String>[];
        try {
          final j = jsonDecode(body) as Map<String, dynamic>;
          final choices = j['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final msg = (choices[0] as Map)['message'] as Map?;
            content = (msg?['content'] as String?) ?? '';
            final rc = (msg?['reasoning_content'] as String?) ?? '';
            var rs = '';
            final rawReasoning = msg?['reasoning'];
            if (rawReasoning is String) {
              rs = rawReasoning;
            } else if (rawReasoning is Map) {
              final t = rawReasoning['content'] ?? rawReasoning['text'];
              if (t is String) rs = t;
            }
            reasoning = rc.isNotEmpty ? rc : rs;
            calls = _parseToolCalls(msg?['tool_calls'] as List?);
          }
          usage = _usageOf(j['usage']);
          sources.addAll(_sourcesFrom(j['citations']));
          sources.addAll(_sourcesFrom(j['annotations']));
        } catch (_) {}
        holder.result = _RoundResult(
          content,
          reasoning,
          calls,
          usage: usage,
          sources: sources,
        );
        return;
      }

      final lines =
          resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      var content = '';
      var reasoning = '';
      Map<String, dynamic>? usage;
      final sources = <String>[];
      final builders = <int, _ToolCallBuilder>{};
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final rawUsage = json['usage'];
          if (rawUsage is Map) {
            usage = _usageOf(rawUsage);
            yield StreamChunk('', '', usage: usage);
          }
          if (json['citations'] != null || json['annotations'] != null) {
            sources.addAll(_sourcesFrom(json['citations']));
            sources.addAll(_sourcesFrom(json['annotations']));
          }
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final delta = (choices[0] as Map)['delta'] as Map?;
          if (delta == null) continue;

          final c = (delta['content'] as String?) ?? '';
          final rc = (delta['reasoning_content'] as String?) ?? '';
          var rs = '';
          final rawReasoning = delta['reasoning'];
          if (rawReasoning is String) {
            rs = rawReasoning;
          } else if (rawReasoning is Map) {
            final t = rawReasoning['content'] ?? rawReasoning['text'];
            if (t is String) rs = t;
          }
          final r = rc.isNotEmpty ? rc : rs;
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
        usage: usage,
        sources: sources,
      );
      if (sources.isNotEmpty) {
        yield StreamChunk('', '', sources: sources);
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  List<Map<String, dynamic>> _builtinToolsPayload() {
    try {
      final pr = presets.active;
      if (pr == null) return const <Map<String, dynamic>>[];
      if (pr.providerId.trim().toLowerCase() != 'polza') {
        return const <Map<String, dynamic>>[];
      }
      if (!settings.webSearchEnabled) return const <Map<String, dynamic>>[];
      return const <Map<String, dynamic>>[
        <String, dynamic>{'type': 'polza:web_search'},
      ];
    } catch (_) {
      return const <Map<String, dynamic>>[];
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

  static Map<String, dynamic>? _usageOf(Object? raw) {
    if (raw is! Map) return null;
    try {
      return Map<String, dynamic>.from(raw);
    } catch (_) {
      return null;
    }
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
      var endpoint = tool.endpoint.trim();
      if (endpoint.contains('{') && args.isNotEmpty) {
        args.forEach((key, value) {
          endpoint = endpoint.replaceAll(
            '{$key}',
            Uri.encodeQueryComponent(_scalar(value)),
          );
        });
      }
      final uri = Uri.parse(endpoint);
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

  static String _lastUserText(List<Map<String, dynamic>> history) {
    for (final m in history.reversed) {
      if (m['role'] != 'user') continue;
      final c = m['content'];
      if (c is String && c.trim().isNotEmpty) return c.trim();
      if (c is List) {
        final buf = StringBuffer();
        for (final p in c) {
          if (p is Map && p['type'] == 'text') {
            final t = p['text'];
            if (t is String) buf.write(t);
          }
        }
        final t = buf.toString().trim();
        if (t.isNotEmpty) return t;
      }
    }
    return '';
  }

  static List<String> _sourcesFrom(Object? raw) {
    final out = <String>[];
    if (raw is! List) return out;
    for (final e in raw) {
      String? url;
      if (e is String) {
        url = e;
      } else if (e is Map) {
        final v = e['url'] ?? e['uri'] ?? e['link'];
        if (v is String) url = v;
      }
      final t = (url ?? '').trim();
      if (t.startsWith('http://') || t.startsWith('https://')) {
        if (!out.contains(t)) out.add(t);
      }
    }
    return out;
  }

  String _scalar(Object? v) => v?.toString() ?? '';

  static String? _invalidParamFrom400(String body) {
    var raw = body;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final err = j['error'];
        if (err is Map) {
          final md = err['metadata'];
          final mdRaw = md is Map ? md['raw'] : null;
          if (mdRaw is String && mdRaw.trim().isNotEmpty) {
            raw = mdRaw;
          } else if (err['message'] is String) {
            raw = err['message'] as String;
          }
        } else if (j['message'] is String) {
          raw = j['message'] as String;
        }
      }
    } catch (_) {}
    final s = raw.trim();
    if (s.isEmpty) return null;
    final patterns = <RegExp>[
      RegExp(r'The parameter `(\w+)` specified'),
      RegExp(r'''invalid.*parameter.*['"](\w+)['"]''', caseSensitive: false),
      RegExp(r'''Unknown.*parameter:?\s*['"]?(\w+)''', caseSensitive: false),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(s);
      final name = m?.group(1);
      if (name != null && name.isNotEmpty) return name;
    }
    return null;
  }

  String _describeError(
    int code,
    String body, {
    String baseUrl = '',
    String tokenPrefix = '',
  }) {
    if (code == 401) {
      return 'Ошибка авторизации (401). URL: $baseUrl/chat/completions. '
          'Токен: $tokenPrefix';
    }
    switch (code) {
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
