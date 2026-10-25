// Copyright (c) 2026 Minkail. All rights reserved.

/// Инструмент: внешний HTTP-эндпоинт, который модель сможет вызывать.
/// Все данные вводит пользователь; в коде нет никаких зашитых сервисов.
class Tool {
  final String id;
  String name;
  String description;

  /// Полный URL эндпоинта.
  String endpoint;

  /// HTTP-метод: GET или POST.
  String method;

  /// Дополнительные заголовки запроса.
  Map<String, String> headers;

  /// JSON-схема параметров (строка с JSON-объектом).
  String parametersSchema;

  Tool({
    required this.id,
    required this.name,
    this.description = '',
    this.endpoint = '',
    this.method = 'POST',
    Map<String, String>? headers,
    this.parametersSchema = '',
  }) : headers = headers ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'endpoint': endpoint,
        'method': method,
        'headers': headers,
        'parametersSchema': parametersSchema,
      };

  factory Tool.fromJson(Map<String, dynamic> j) => Tool(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? 'Инструмент',
        description: (j['description'] as String?) ?? '',
        endpoint: (j['endpoint'] as String?) ?? '',
        method: ((j['method'] as String?) ?? 'POST').toUpperCase(),
        headers: _headersFrom(j['headers']),
        parametersSchema: (j['parametersSchema'] as String?) ?? '',
      );

  static Map<String, String> _headersFrom(Object? raw) {
    if (raw is! Map) return {};
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (value != null) out[key.toString()] = value.toString();
    });
    return out;
  }
}

