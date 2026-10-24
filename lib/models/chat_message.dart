// Copyright (c) 2026 Minkail. All rights reserved.

class ChatMessage {
  final String id;
  final String role;
  String content;
  String reasoning;
  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.reasoning = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'reasoning': reasoning,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        role: j['role'] as String,
        content: (j['content'] as String?) ?? '',
        reasoning: (j['reasoning'] as String?) ?? '',
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
      );
}
