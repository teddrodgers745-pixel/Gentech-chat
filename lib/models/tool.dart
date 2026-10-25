// Copyright (c) 2026 Minkail. All rights reserved.

/// Инструмент, который модель сможет вызывать. Два типа:
///  - http:  внешний HTTP-эндпоинт (GET/POST);
///  - model: другая модель по OpenAI-совместимому API
///           (chat/completions либо responses).
/// Все данные вводит пользователь; в коде нет зашитых сервисов.
class Tool {
  /// Типы инструментов.
  static const String typeHttp = 'http';
  static const String typeModel = 'model';

  /// Типы API для модели-инструмента.
  static const String apiChat = 'chat';
  static const String apiResponses = 'responses';

  final String id;
  String name;
  String description;

  /// 'http' либо 'model'. Старые записи (без поля) читаются как 'http'.
  String type;

  // --- Поля HTTP-инструмента ---
  String endpoint;
  String method;
  Map<String, String> headers;

  /// JSON-схема параметров (строка с JSON-объектом).
  String parametersSchema;

  // --- Поля модели-инструмента ---
  String baseUrl;
  String apiKey;
  String modelId;

  /// 'chat' (chat/completions) либо 'responses' (Responses API).
  String apiType;

  Tool({
    required this.id,
    required this.name,
    this.description = '',
    this.type = typeHttp,
    this.endpoint = '',
    this.method = 'POST',
    Map<String, String>? headers,
    this.parametersSchema = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.modelId = '',
    this.apiType = apiChat,
  }) : headers = headers ?? {};

  bool get isModel => type == typeModel;

  /// Человекочитаемая подпись типа.
  String get typeLabel => isModel ? 'Модель-инструмент' : 'HTTP-инструмент';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'type': type,
        'endpoint': endpoint,
        'method': method,
        'headers': headers,
        'parametersSchema': parametersSchema,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'modelId': modelId,
        'apiType': apiType,
      };

  factory Tool.fromJson(Map<String, dynamic> j) {
    final rawType = ((j['type'] as String?) ?? typeHttp).trim();
    final rawApi = ((j['apiType'] as String?) ?? apiChat).trim();
    return Tool(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? 'Инструмент',
      description: (j['description'] as String?) ?? '',
      type: rawType == typeModel ? typeModel : typeHttp,
      endpoint: (j['endpoint'] as String?) ?? '',
      method: ((j['method'] as String?) ?? 'POST').toUpperCase(),
      headers: _headersFrom(j['headers']),
      parametersSchema: (j['parametersSchema'] as String?) ?? '',
      baseUrl: (j['baseUrl'] as String?) ?? '',
      apiKey: (j['apiKey'] as String?) ?? '',
      modelId: (j['modelId'] as String?) ?? '',
      apiType: rawApi == apiResponses ? apiResponses : apiChat,
    );
  }

  static Map<String, String> _headersFrom(Object? raw) {
    if (raw is! Map) return {};
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (value != null) out[key.toString()] = value.toString();
    });
    return out;
  }
}
