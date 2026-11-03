// Copyright (c) 2026 Minkail. All rights reserved.

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
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

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
        createdAt:
            DateTime.tryParse((j['createdAt'] as String?) ?? '') ??
                DateTime.now(),
      );
}
