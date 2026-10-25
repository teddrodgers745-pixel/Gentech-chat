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
        createdAt:
            DateTime.tryParse((j['createdAt'] as String?) ?? '') ??
                DateTime.now(),
      );
}
