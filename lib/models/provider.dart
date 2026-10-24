// Copyright (c) 2026 Minkail. All rights reserved.

class Provider {
  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;

  const Provider({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
      };

  factory Provider.fromJson(Map<String, dynamic> json) => Provider(
        id: json['id'] as String,
        name: json['name'] as String,
        baseUrl: json['baseUrl'] as String,
        apiKey: json['apiKey'] as String,
      );
}
