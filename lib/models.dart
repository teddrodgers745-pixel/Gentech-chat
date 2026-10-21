class ChatMessage {
  final String id;
  final String role; // 'user' | 'assistant'
  String content;
  String reasoning;

  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.reasoning = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'reasoning': reasoning,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        role: j['role'] as String,
        content: (j['content'] as String?) ?? '',
        reasoning: (j['reasoning'] as String?) ?? '',
      );
}

class Chat {
  final String id;
  String title;
  DateTime updatedAt;
  final List<ChatMessage> messages;

  Chat({
    required this.id,
    this.title = 'Новый чат',
    DateTime? updatedAt,
    List<ChatMessage>? messages,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        messages = messages ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Chat.fromJson(Map<String, dynamic> j) => Chat(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? 'Новый чат',
        updatedAt: DateTime.tryParse((j['updatedAt'] as String?) ?? ''),
        messages: ((j['messages'] as List?) ?? [])
            .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}
