// Copyright (c) 2026 Minkail. All rights reserved.

import '../core/models/gen_error.dart';
import '../core/models/message_part.dart';

/// Статусы специального сообщения-вызова инструмента.
const String toolStatusRunning = 'running';
const String toolStatusDone = 'done';
const String toolStatusError = 'error';

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
        'parts': <Map<String, dynamic>>[
          for (final p in parts) _encodePart(p),
        ],
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
        createdAt:
            DateTime.tryParse((j['createdAt'] as String?) ?? '') ??
                DateTime.now(),
      );
}

/// Сериализация части сообщения (дискриминатор 'type').
Map<String, dynamic> _encodePart(MessagePart part) {
  final p = part;
  if (p is TextPart) {
    return <String, dynamic>{'type': 'text', 'text': p.text};
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
      if (p.debugSnippets != null) 'debugSnippets': p.debugSnippets,
      if (p.debugLogPath != null) 'debugLogPath': p.debugLogPath,
    };
  }
  if (p is ErrorPart) {
    return <String, dynamic>{
      'type': 'error',
      'message': p.error.message,
      'prompt': p.originalPrompt,
    };
  }
  return <String, dynamic>{'type': 'text', 'text': ''};
}

MessagePart? _decodePart(Object? raw) {
  if (raw is! Map) return null;
  final j = Map<String, dynamic>.from(raw);
  switch ((j['type'] ?? '').toString()) {
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
        debugSnippets: rawSnippets is List
            ? <String>[for (final e in rawSnippets) if (e != null) e.toString()]
            : null,
        debugLogPath: (j['debugLogPath'] as String?),
      );
    case 'error':
      return ErrorPart(
        error: UnknownGenError(details: (j['message'] as String?) ?? ''),
        originalPrompt: (j['prompt'] as String?) ?? '',
      );
    default:
      return TextPart((j['text'] as String?) ?? '');
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
