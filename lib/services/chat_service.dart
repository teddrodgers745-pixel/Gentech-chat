// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../app_state.dart';
import '../core/utils/reasoning_mapper.dart';
import '../core/utils/stream_pacer.dart';
import '../models/chat_message.dart';
import '../models/tool.dart';
import 'model_tool.dart';
import 'search_enhancer.dart';

class StreamChunk {
  final String content;
  final String reasoning;

  /// Поля события вызова инструмента (заполняются только для таких событий).
  final String? toolName;
  final String? toolArgs;
  final String? toolStatus;
  final String? toolResult;

  /// Статистика токенов раунда (usage), когда провайдер её отдал
  /// (запрос со stream_options.include_usage). null — статистики нет.
  final Map<String, dynamic>? usage;

  /// Ссылки-источники из полей citations/annotations ответа провайдера.
  /// Пустой список — источников нет.
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

/// Итог непотокового запроса: текст ответа и статистика токенов (usage)
/// раунда, когда провайдер её вернул. Возвращается методом
/// [ChatService.sendMessageResult].
class ChatResult {
  final String text;
  final Map<String, dynamic>? usage;

  const ChatResult({this.text = '', this.usage});
}

/// Выбранный пользователем файл: понятное имя и путь на устройстве.
class PickedFileRef {
  final String name;
  final String path;
  const PickedFileRef(this.name, this.path);
}

/// Максимальный размер вложения, которое читаем целиком.
const int kMaxAttachmentBytes = 8 * 1024 * 1024;

/// Инструкция модели о выдаче файлов: добавляется к системному промпту,
/// чтобы файлы приходили блоками кода с именем файла.
const String kFileBlockInstruction =
    'Если пользователь просит создать файл (HTML, Python, Markdown и т.д.), '
    'ты ДОЛЖЕН выдавать его в блоке кода с указанием имени файла, '
    'например: ```html name=index.html или ```python name=script.py.';

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

  /// Статистика токенов раунда (usage), если провайдер её вернул.
  final Map<String, dynamic>? usage;

  /// Ссылки-источники из citations/annotations ответа провайдера.
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
  /// Максимум итераций вызова инструментов, чтобы не зациклиться.
  static const int _maxToolIterations = 4;

  /// Готовит content пользовательского сообщения с вложениями.
  /// Картинки (jpg/jpeg/png/webp/gif) читаются в байты, кодируются в base64
  /// и превращаются в data URL внутри массива content (Vision-формат);
  /// текстовые файлы (txt/md/json/dart/csv/log) добавляются к тексту промпта.
  /// Возвращает String либо List<Map<String, dynamic>>.
  /// Ошибки чтения не роняют отправку: файл пропускается с пометкой.
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

  /// Поиск (searchMode) применяется к первому раунду текущего вызова
  /// sendMessage/sendMessageResult; сбрасывается после применения.
  bool _searchPending = false;

  /// Пейсер плавного вывода текста активной генерации; null — пейсинга нет.
  /// UI подписывается на [StreamPacer.displayed] (ValueNotifier<String>),
  /// чтобы получать полный показанный текст по мере «печатания».
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
    String? reasoningEffort,
    List<Tool> tools = const <Tool>[],
  }) async* {
    _wasCancelled = false;
    _searchPending = true;
    final history = <Map<String, dynamic>>[
      for (final m in messages) Map<String, dynamic>.of(m),
    ];
    // Пейсер плавного вывода (StreamPacer): создаётся один раз на вызов
    // и переиспользуется во всех раундах, чтобы [StreamPacer.displayed]
    // содержал полный показанный текст. Для непотокового запроса пейсинг
    // не нужен — ответ приходит одним куском.
    final StreamPacer? pacer = stream ? (_activePacer = StreamPacer()) : null;

    for (int iteration = 0; iteration < _maxToolIterations; iteration++) {
      if (_wasCancelled) return;
      final holder = _RoundHolder();
      yield* _pacedRound(
        pacer: pacer,
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
      final res = holder.result;
      if (res == null) return;

      if (res.toolCalls.isEmpty) {
        // Обычное завершение: без стрима отдаём ответ одним куском
        // (вместе со статистикой токенов, если она пришла).
        if (!stream) {
          yield StreamChunk(
            res.content,
            res.reasoning,
            usage: res.usage,
            sources: res.sources,
          );
        }
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
        } else if (tool.isModel) {
          outcome = await ModelToolRunner.run(tool, call.arguments);
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
    yield* _pacedRound(
      pacer: pacer,
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      history: history,
      stream: stream,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      tools: const <Tool>[],
      holder: holder,
    );
    final res = holder.result;
    if (res != null && !stream) {
      yield StreamChunk(
        res.content,
        res.reasoning,
        usage: res.usage,
        sources: res.sources,
      );
    }
  }

  /// Оборачивает раунд [_round] пейсером плавного вывода: куски контента
  /// буферизуются в [StreamPacer] и выдаются порциями по тикам (60 fps);
  /// события вызова инструментов и usage проходят без изменений.
  /// Для непотокового запроса (pacer == null) раунд отдаётся как есть.
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

  /// Поток с пейсингом: контент уходит в буфер пейсера, Ticker (60 fps)
  /// выдаёт порции; reasoning, события инструментов и usage проходят
  /// напрямую. При завершении источника остаток буфера выдаётся целиком
  /// через [StreamPacer.flush], чтобы финальный текст был полным.
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
        // События инструментов, usage и источники идут без пейсинга.
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

  /// Непотоковый запрос одним вызовом: возвращает [ChatResult] —
  /// текст ответа и статистику токенов (usage) раунда, если провайдер
  /// её отдал. Удобно, когда стриминг не нужен, но нужны токены.
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

  /// Один запрос к /chat/completions. Стримит куски контента,
  /// итог раунда (в т.ч. tool_calls) кладёт в holder.
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
      final builtin = _builtinToolsPayload();
      Map<String, dynamic> bodyMap = {
        'model': model,
        'messages': history,
        'stream': stream,
        // Просим статистику токенов: провайдер приложит usage к финальному
        // чанку стрима (у которого choices пуст).
        if (stream)
          'stream_options': <String, dynamic>{'include_usage': true},
        if (temperature != null) 'temperature': temperature,
        // Единый селектор Reasoning Effort: формат поля выбирает
        // ReasoningMapper.mapToApi — 'reasoning_effort' для прямых
        // провайдеров, 'reasoning: {effort: ...}' для идентификаторов
        // с префиксом владельца ('vendor/model'); off — поле не уходит.
        ...ReasoningMapper.mapToApi(
          ReasoningMapper.fromId(reasoningEffort ?? ''),
          model,
        ),
        if (tools.isNotEmpty || builtin.isNotEmpty)
          'tools': <Map<String, dynamic>>[
            ...builtin,
            if (tools.isNotEmpty) ..._toolsPayload(tools),
          ],
      };
      // Поиск (searchMode 'provider'/'modelAsTool') применяется один раз
      // за вызов sendMessage — в первом раунде обращения к модели. Сбой
      // поиска не ломает отправку основного запроса.
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
      req.body = jsonEncode(bodyMap);

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
        Map<String, dynamic>? usage;
        final sources = <String>[];
        try {
          final j = jsonDecode(body) as Map<String, dynamic>;
          final choices = j['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final msg = (choices[0] as Map)['message'] as Map?;
            content = (msg?['content'] as String?) ?? '';
            reasoning = (msg?['reasoning_content'] as String?) ?? '';
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

      // --- Стриминг ---
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
          // Статистика токенов раунда (stream_options.include_usage):
          // приходит в финальном чанке, у которого choices пуст. Сохраняем
          // в usage раунда и пробрасываем наружу пустым чанком.
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

  /// Встроенный (серверный) инструмент базового поиска: добавляется в запрос,
  /// когда активный пресет относится к провайдеру с поддержкой поиска
  /// и тумблер «Базовый поиск в интернете» включён в настройках.
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

  /// Приводит поле usage ответа к Map<String, dynamic>; null — это не карта
  /// либо ключи не строки. Битые данные не роняют разбор ответа.
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
      // Подстановка плейсхолдеров {query}/{ключ} в URL значениями аргументов
      // (например, srsearch={query} у поиска по энциклопедии).
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

  /// Текст последнего пользовательского сообщения (для поискового запроса).
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

  /// Ссылки-источники из полей citations/annotations ответа провайдера:
  /// строки-URL либо объекты с полем url/uri/link. Дубликаты убираются.
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
