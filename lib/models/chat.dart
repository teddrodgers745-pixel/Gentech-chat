// Copyright (c) 2026 Minkail. All rights reserved.

import 'chat_message.dart';

class Chat {
  final String id;
  String title;
  DateTime updatedAt;
  final DateTime createdAt;
  final List<ChatMessage> messages;

  Chat({
    required this.id,
    this.title = 'Новый чат',
    DateTime? updatedAt,
    DateTime? createdAt,
    List<ChatMessage>? messages,
  })  : updatedAt = updatedAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now(),
        messages = messages ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Chat.fromJson(Map<String, dynamic> j) => Chat(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? 'Новый чат',
        updatedAt: DateTime.tryParse((j['updatedAt'] as String?) ?? '') ?? DateTime.now(),
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
        messages: ((j['messages'] as List?) ?? [])
            .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}
