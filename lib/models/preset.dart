// Copyright (c) 2026 Minkail. All rights reserved.

/// Пресет: готовая конфигурация подключения к провайдеру.
/// Провайдер, ключ и модель вводит пользователь; в коде их нет.
class Preset {
  final String id;
  String name;
  String providerId;
  String baseUrl;
  String apiKey;
  String model;
  bool stream;
  double temperature;
  String systemPrompt;

  Preset({
    required this.id,
    required this.name,
    this.providerId = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.stream = true,
    this.temperature = 1.0,
    this.systemPrompt = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'providerId': providerId,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'stream': stream,
        'temperature': temperature,
        'systemPrompt': systemPrompt,
      };

  factory Preset.fromJson(Map<String, dynamic> j) => Preset(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? 'Пресет',
        providerId: (j['providerId'] as String?) ?? '',
        baseUrl: (j['baseUrl'] as String?) ?? '',
        apiKey: (j['apiKey'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        stream: (j['stream'] as bool?) ?? true,
        temperature: (j['temperature'] as num?)?.toDouble() ?? 1.0,
        systemPrompt: (j['systemPrompt'] as String?) ?? '',
      );
}
