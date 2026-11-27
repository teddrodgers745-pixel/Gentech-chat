```dart
// Copyright (c) 2026 Minkail. All rights reserved.

import '../core/models/gen_error.dart';
import '../core/models/gen_error_mapper.dart';
import '../core/models/message_part.dart';

/// Статусы специального сообщения-вызова инструмента.
const String toolStatusRunning = 'running';
const String toolStatusDone = 'done';
const String toolStatusError = 'error';

/// Версия схемы сериализации частей сообщения (R6-audio-robustness-2,
/// п.7). Рост версии означает изменение формата parts: старые записи
/// читаются терпимо, файлы будущих версий — не угадываются.
const int partSchemaVersion = 2;

/// Снимок запроса, необходимый для повторной генерации.
///
/// [route] содержит исходный маршрут: text, image или video.
/// [connectionId] идентифицирует исходное подключение; секреты в снимке
/// не хранятся. [connectionBaseUrl] позволяет обнаружить изменение адреса
/// подключения. [typeOverride] равен null, если был выбран автоматический
/// тип модели.
///
/// Некорректный снимок не следует считать отсутствующим: при повторе
/// его необходимо отклонить с понятной ошибкой, а не выбирать маршрут
/// заново.
class GenerationSnapshot {
  final String route;
  final String modelId;
  final String connectionId;
  final String connectionBaseUrl;
  final String prompt;
  final String? typeOverride;
  final Map<String, dynamic> parameters;

  /// Идентификатор созданной асинхронной задачи (видео/изображение).
  /// Пустая строка — задача ещё не создана. Сохраняется, чтобы повтор
  /// возобновлял существующую задачу, а не создавал новую.
  String jobId;

  GenerationSnapshot({
    required this.route,
    required this.modelId,
    required this.connectionId,
    required this.connectionBaseUrl,
    required this.prompt,
    this.typeOverride,
    Map<String, dynamic> parameters = const <String, dynamic>{},
    this.jobId = '',
  }) : parameters = Map<String, dynamic>.unmodifiable(parameters);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'route': route,
        'modelId': modelId,
        'connectionId': connectionId,
        'connectionBaseUrl': connectionBaseUrl,
        'prompt': prompt,
        if (typeOverride != null) 'typeOverride': typeOverride,
        'parameters': parameters,
        if (jobId.isNotEmpty) 'jobId': jobId,
      };

  factory GenerationSnapshot.fromJson(Object? raw) {
    final j = raw is Map ? raw : const <String, dynamic>{};
    final rawParams = j['parameters'];
    final params = <String, dynamic>{};
    if (rawParams is Map) {
      for (final entry in rawParams.entries) {
        if (entry.key is String) {
          params[entry.key as String] = entry.value;
        }
      }
    }

    String stringValue(String key) {
      final value = j[key];
      return value is String ? value : '';
    }

    final rawOverride = j['typeOverride'];
    return GenerationSnapshot(
      route: stringValue('route'),
      modelId: stringValue('modelId'),
      connectionId: stringValue('connectionId'),
      connectionBaseUrl: stringValue('connectionBaseUrl'),
      prompt: stringValue('prompt'),
      typeOverride: rawOverride is String ? rawOverride : null,
      parameters: params,
      jobId: stringValue('jobId'),
    );
  }
}

class ChatMessage {
  final String id;
  final String role;

  /// Текст сообщения (для role 'tool_call' обычно пустой).
  String content;
  String reasoning;

  /// Поля специального сообщения-вызова инструмента (role == 'tool_call'):
  /// имя инструмента, аргументы JSON-строкой, результат и статус.
  String toolName;
  String toolArgs;
  String toolResult;
  String toolStatus;

  /// Ошибка генерации для отображения через ErrorPart/ErrorBubble:
  /// код [GenError.code] и сырые детали провайдера ('' — ошибки нет).
  /// Сообщение с ошибкой имеет пустой content и не отправляется модели.
  String errorCode;
  String errorText;

  /// Части составного сообщения: изображения, видео, ожидающие задачи.
  /// Для обычных текстовых сообщений список пуст.
  final List<MessagePart> parts;

  /// Исходный запрос для повтора. В старой истории отсутствует.
  final GenerationSnapshot? generationSnapshot;

  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.reasoning = '',
    this.toolName = '',
    this.toolArgs = '',
    this.toolResult = '',
    this.toolStatus = toolStatusDone,
    this.errorCode = '',
    this.errorText = '',
    List<MessagePart>? parts,
    this.generationSnapshot,
    DateTime? createdAt,
  })  : parts = parts ?? <MessagePart>[],
        createdAt = createdAt ?? DateTime.now();

  bool get isToolCall => role == 'tool_call';

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'reasoning': reasoning,
        'toolName': toolName,
        'toolArgs': toolArgs,
        'toolResult': toolResult,
        'toolStatus': toolStatus,
        'errorCode': errorCode,
        'errorText': errorText,
        'partSchemaVersion': partSchemaVersion,
        'parts': <Map<String, dynamic>>[
          for (final p in parts) _encodePart(p),
        ],
        if (generationSnapshot != null)
          'generationSnapshot': generationSnapshot!.toJson(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        role: j['role'] as String,
        content: (j['content'] as String?) ?? '',
        reasoning: (j['reasoning'] as String?) ?? '',
        toolName: (j['toolName'] as String?) ?? '',
        toolArgs: (j['toolArgs'] as String?) ?? '',
        toolResult: (j['toolResult'] as String?) ?? '',
        toolStatus: (j['toolStatus'] as String?) ?? toolStatusDone,
        errorCode: (j['errorCode'] as String?) ?? '',
        errorText: (j['errorText'] as String?) ?? '',
        parts: _decodeParts(j['parts']),
        generationSnapshot: j.containsKey('generationSnapshot')
            ? GenerationSnapshot.fromJson(j['generationSnapshot'])
            : null,
        createdAt:
            DateTime.tryParse((j['createdAt'] as String?) ?? '') ??
                DateTime.now(),
      );
}

/// Сериализация части сообщения (дискриминатор 'type').
///
/// Версионирование: каждая запись сообщения несёт partSchemaVersion
/// (см. [ChatMessage.toJson]). Неизвестная часть сохраняется как
/// {'type': 'unknown', ...} и НЕ превращается в пустой текст.
///
/// UnknownPart — отдельный лист sealed-иерархии, поэтому его ветка
/// стоит первой лишь для единообразия: подтипом TextPart он больше
/// не является и в текстовую ветку попасть не может.
Map<String, dynamic> _encodePart(MessagePart part) {
  final p = part;
  if (p is UnknownPart) {
    return <String, dynamic>{
      'type': 'unknown',
      'kind': p.kind,
      'raw': p.raw,
    };
  }
  if (p is TextPart) {
    return <String, dynamic>{
      'type': 'text',
      'text': p.text,
      if (p.cost != null) 'cost': p.cost!.toJson(),
      if (p.sources.isNotEmpty) 'sources': p.sources,
    };
  }
  if (p is ImagePart) {
    return <String, dynamic>{
      'type': 'image',
      'localPath': p.localPath,
      'remoteUrl': p.remoteUrl,
    };
  }
  if (p is VideoPart) {
    return <String, dynamic>{
      'type': 'video',
      'localPath': p.localPath,
      'remoteUrl': p.remoteUrl,
    };
  }
  if (p is PendingPart) {
    return <String, dynamic>{
      'type': 'pending',
      'name': p.name,
      'localPath': p.localPath,
      'jobId': p.jobId,
      'progress': p.progress,
      'indeterminate': p.indeterminate,
      if (p.debugSnippets != null) 'debugSnippets': p.debugSnippets,
      if (p.debugLogPath != null) 'debugLogPath': p.debugLogPath,
    };
  }
  if (p is ErrorPart) {
    // Тип ошибки и параметры повтора сохраняются (R6, п.7): после
    // перезапуска ошибка восстанавливается по коду, а не заглушкой.
    return <String, dynamic>{
      'type': 'error',
      'code': p.error.code,
      'details': GenErrorMapper.detailsOf(p.error),
      'prompt': p.originalPrompt,
      if (p.retryParams.isNotEmpty) 'retryParams': p.retryParams,
    };
  }
  // Любая новая часть, незнакомая этой версии сериализации, сохраняется
  // как «неизвестная» с фактическим типом — данные не теряются.
  return <String, dynamic>{
    'type': 'unknown',
    'kind': p.runtimeType.toString(),
    'raw': <String, dynamic>{},
  };
}

MessagePart? _decodePart(Object? raw) {
  if (raw is! Map) return null;
  final j = Map<String, dynamic>.from(raw);
  switch ((j['type'] ?? '').toString()) {
    case 'text':
      // Восстановление текстовой части со стоимостью и источниками:
      // без этой ветки TextPart после перезапуска терял бы cost/sources
      // (стоимость ответа и ссылки пропадали бы из истории).
      final rawCost = j['cost'];
      final rawSources = j['sources'];
      return TextPart(
        (j['text'] as String?) ?? '',
        cost: rawCost is Map
            ? MessageCost.fromJson(Map<String, dynamic>.from(rawCost))
            : null,
        sources: rawSources is List
            ? <String>[
                for (final e in rawSources) if (e != null) e.toString(),
              ]
            : const <String>[],
      );
    case 'image':
      return ImagePart(
        localPath: (j['localPath'] as String?) ?? '',
        remoteUrl: (j['remoteUrl'] as String?) ?? '',
      );
    case 'video':
      return VideoPart(
        localPath: (j['localPath'] as String?) ?? '',
        remoteUrl: (j['remoteUrl'] as String?) ?? '',
      );
    case 'pending':
      final rawSnippets = j['debugSnippets'];
      return PendingPart(
        name: (j['name'] as String?) ?? '',
        localPath: (j['localPath'] as String?) ?? '',
        jobId: (j['jobId'] as String?) ?? '',
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        indeterminate: j['indeterminate'] == true,
        debugSnippets: rawSnippets is List
            ? <String>[for (final e in rawSnippets) if (e != null) e.toString()]
            : null,
        debugLogPath: (j['debugLogPath'] as String?),
      );
    case 'error':
      // Восстановление типизированной ошибки: код и детали сохранены
      // при записи. Формат v1 ('message') тоже читается.
      final code = ((j['code'] ?? '') as String?)?.trim() ?? '';
      final details = ((j['details'] ?? '') as String?)?.trim() ??
          ((j['message'] ?? '') as String?)?.trim() ??
          '';
      final rawRetry = j['retryParams'];
      final retry = <String, dynamic>{};
      if (rawRetry is Map) {
        for (final entry in rawRetry.entries) {
          if (entry.key is String) {
            retry[entry.key as String] = entry.value;
          }
        }
      }
      return ErrorPart(
        error: code.isNotEmpty
            ? GenErrorMapper.fromCode(code, details: details)
            : UnknownGenError(details: details),
        originalPrompt: (j['prompt'] as String?) ?? '',
        retryParams: retry,
      );
    case 'unknown':
      final rawMap = j['raw'];
      return UnknownPart(
        kind: (j['kind'] as String?) ?? '',
        raw: rawMap is Map
            ? Map<String, dynamic>.from(rawMap)
            : const <String, dynamic>{},
      );
    default:
      // Неизвестный тип части: данные сохраняются, пустым текстом
      // больше не подменяются (R6, п.7).
      return UnknownPart(kind: (j['type'] ?? '').toString(), raw: j);
  }
}

/// Безопасный разбор списка частей: битые элементы пропускаются.
List<MessagePart> _decodeParts(Object? raw) {
  if (raw is! List) return <MessagePart>[];
  final out = <MessagePart>[];
  for (final e in raw) {
    final p = _decodePart(e);
    if (p != null) out.add(p);
  }
  return out;
}
```
