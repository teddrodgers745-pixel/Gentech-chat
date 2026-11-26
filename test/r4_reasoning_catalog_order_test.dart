// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/core/catalog/parsing/openrouter_parser.dart';
import 'package:gentech_chat/core/catalog/parsing/polza_parser.dart';
import 'package:gentech_chat/core/catalog/parsing/reasoning_levels.dart';
import 'package:gentech_chat/core/catalog/parsing/routerai_parser.dart';
import 'package:gentech_chat/core/catalog/provider_catalog_service.dart';

void main() {
  test('T-R4-REASONING-LEVELS: порядок и идентификаторы сохраняются', () {
    expect(
      normalizeReasoningLevels(
        <String>['max', 'high', 'low', 'none', 'custom', 'none'],
      ),
      <String>['max', 'high', 'low', 'none', 'custom'],
    );
    expect(normalizeReasoningEffort(' none '), 'none');
  });

  test('T-R4-REASONING-NO-FALLBACK: пустой список не создаёт уровни', () {
    expect(normalizeReasoningLevels(<String>[]), isEmpty);
    expect(
      normalizeReasoningLevels(<String>[], mandatory: true),
      isEmpty,
    );
  });

  test('T-R4-REASONING-PARSERS: перечисленные уровни не нормализуются',
      () {
    final model = <String, dynamic>{
      'id': 'vendor/model',
      'type': 'chat',
      'reasoning': <String, dynamic>{
        'supported_efforts': <String>['max', 'high', 'low', 'none'],
        'default_effort': 'none',
      },
    };
    const connection = CatalogConnection(
      id: 'fixture',
      baseUrl: 'https://example.com/v1',
      apiKey: 'fixture',
    );

    final entries = <CatalogEntry?>[
      ProviderCatalogService.parseEntry(model, connection),
      PolzaParser.parseEntry(model, connection.id),
      RouterAiParser.parseEntry(model, connection.id),
      parseOpenRouterModel(model),
    ];

    for (final entry in entries) {
      expect(entry, isNotNull);
      expect(entry!.reasoning, isNotNull);
      expect(
        entry.reasoning!.levels,
        <String>['max', 'high', 'low', 'none'],
      );
      expect(entry.reasoning!.defaultEffort, 'none');
    }
  });
}
