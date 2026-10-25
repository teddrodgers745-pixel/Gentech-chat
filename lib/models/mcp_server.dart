// Copyright (c) 2026 Minkail. All rights reserved.

/// MCP-сервер (Model Context Protocol), добавленный пользователем:
/// понятное название, адрес и необязательный токен доступа.
/// Все данные вводит пользователь; в коде нет зашитых серверов.
class McpServer {
  final String id;
  String name;
  String url;
  String token;

  McpServer({
    required this.id,
    required this.name,
    this.url = '',
    this.token = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'token': token,
      };

  factory McpServer.fromJson(Map<String, dynamic> j) => McpServer(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? 'Сервер',
        url: (j['url'] as String?) ?? '',
        token: (j['token'] as String?) ?? '',
      );
}
