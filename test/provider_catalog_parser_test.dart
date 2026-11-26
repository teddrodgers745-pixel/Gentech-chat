// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// Типы каталога экспортируются вместе с provider_catalog_service.dart.
import 'package:gentech_chat/core/catalog/provider_catalog_service.dart';

void main() {
  const connection = CatalogConnection(
    id: 'test-conn',
    baseUrl: 'https://example.com/v1',
    apiKey: 'test-key',
  );

  test('Polza chat: reasoning в top_provider, цена за 1M', () {
    final entry = ProviderCatalogService.parseEntry(
      <String, dynamic>{
        'id': 'vendor/deepseek-r1',
        'name': 'DeepSeek R1',
        'type': 'chat',
        'context_length': 128000,
        'top_provider': <String, dynamic>{
          'reasoning': <String, dynamic>{
            'mandatory': false,
            'default_enabled': true,
            'supported_efforts': <String>['max', 'high', 'low', 'none'],
            'default_effort': 'high',
          },
          'supported_parameters': <String>['tools', 'reasoning'],
          'pricing': <String, dynamic>{
            'prompt_per_million': '11.74',
            'completion_per_million': '17.43',
            'currency': 'RUB',
          },
        },
      },
      connection,
    );

    expect(entry.id, 'vendor/deepseek-r1');
    expect(entry.name, 'DeepSeek R1');
    expect(entry.type, 'chat');
    expect(entry.contextLength, 128000);
    expect(entry.capabilitiesSource, CatalogSources.connection);

    final r = entry.reasoning;
    expect(r, isNotNull);
    expect(r!.levels, <String>['max', 'high', 'low', 'none']);
    expect(r.defaultEffort, 'high');
    expect(r.mandatory, isFalse);
    expect(entry.reasoningUnknown, isFalse);
    expect(entry.supportsTools, isTrue);

    expect(entry.priceIn, closeTo(11.74, 0.0001));
    expect(entry.priceOut, closeTo(17.43, 0.0001));
    expect(entry.currency, 'RUB');
    expect(entry.priceSource, CatalogSources.connection);
  });

  test('Polza video: duration строками -> List<int>, референсы', () {
    final entry = ProviderCatalogService.parseEntry(
      <String, dynamic>{
        'id': 'vendor/kling-v2',
        'type': 'video',
        'parameters': <String, dynamic>{
          'aspect_ratio': <String, dynamic>{
            'values': <String>['16:9', '9:16'],
            'default': '16:9',
          },
          'resolution': <String, dynamic>{
            'values': <String>['720p', '1080p'],
          },
          'duration': <String, dynamic>{
            'values': <String>['4', '6'],
          },
          'quality': <String, dynamic>{
            'values': <String>['standard', 'hd'],
          },
          'images': <String, dynamic>{'max': 7},
        },
      },
      connection,
    );

    expect(entry.type, 'video');
    expect(entry.aspectRatios, <String>['16:9', '9:16']);
    expect(entry.resolutions, <String>['720p', '1080p']);
    expect(entry.durations, <int>[4, 6]);
    expect(entry.qualities, <String>['standard', 'hd']);
    expect(entry.maxReferenceImages, 7);
    // Цен у этой записи нет — не показываем 0.
    expect(entry.priceIn, isNull);
    expect(entry.priceOut, isNull);
    expect(entry.priceSource, isNull);
  });

  test('OpenRouter chat: цена за токен -> за 1M в USD', () {
    final entry = ProviderCatalogService.parseEntry(
      <String, dynamic>{
        'id': 'vendor/gpt-x',
        'name': 'GPT X',
        'context_length': 128000,
        'reasoning': <String, dynamic>{
          'supported_efforts': <String>['medium', 'high'],
          'default_effort': 'medium',
        },
        'supported_parameters': <String>['tools', 'reasoning'],
        'pricing': <String, dynamic>{
          'prompt': '0.0000015',
          'completion': '0.000002',
        },
        'architecture': <String, dynamic>{'modality': 'text->text'},
      },
      connection,
    );

    expect(entry.priceIn, closeTo(1.5, 0.0001));
    expect(entry.priceOut, closeTo(2.0, 0.0001));
    expect(entry.currency, 'USD');
    expect(entry.priceSource, CatalogSources.connection);
    expect(entry.reasoning!.levels, <String>['medium', 'high']);
    expect(entry.reasoning!.defaultEffort, 'medium');
    expect(entry.supportsTools, isTrue);
    expect(entry.capabilitiesSource, CatalogSources.connection);
  });

  test('запись только с id и owned_by: reasoning неизвестен, цены нет', () {
    final entry = ProviderCatalogService.parseEntry(
      <String, dynamic>{
        'id': 'vendor/mystery',
        'owned_by': 'vendor',
      },
      connection,
    );

    expect(entry.id, 'vendor/mystery');
    expect(entry.type, '');
    expect(entry.reasoning, isNull);
    // Формат В: reasoning считается НЕИЗВЕСТНЫМ (добирается из справочников).
    expect(entry.reasoningUnknown, isTrue);
    expect(entry.priceIn, isNull);
    expect(entry.priceOut, isNull);
    expect(entry.priceSource, isNull);
    expect(entry.supportsTools, isNull);
    expect(entry.capabilitiesSource, CatalogSources.connection);
  });

  test(
    'T-R4-REASONING-CATALOG-NO-LEVELS: каталог без списка уровней '
    'не создаёт уровней',
    () {
      // reasoning: true без списка: размышления заявлены, уровней нет.
      final marker = ProviderCatalogService.parseEntry(
        <String, dynamic>{
          'id': 'vendor/flag-only',
          'reasoning': true,
        },
        connection,
      );
      expect(marker.reasoning, isNotNull);
      expect(marker.reasoning!.levels, isEmpty);
      expect(marker.reasoningUnknown, isFalse);

      // reasoning-карта без supported_efforts: уровней тоже нет.
      final emptyMap = ProviderCatalogService.parseEntry(
        <String, dynamic>{
          'id': 'vendor/map-no-efforts',
          'reasoning': <String, dynamic>{'mandatory': false},
        },
        connection,
      );
      expect(emptyMap.reasoning, isNotNull);
      expect(emptyMap.reasoning!.levels, isEmpty);
      expect(emptyMap.reasoningUnknown, isFalse);

      // Имя параметра в supported_parameters — не перечень уровней.
      final paramsOnly = ProviderCatalogService.parseEntry(
        <String, dynamic>{
          'id': 'vendor/params-only',
          'supported_parameters': <String>['reasoning'],
        },
        connection,
      );
      expect(paramsOnly.reasoning, isNotNull);
      expect(paramsOnly.reasoning!.levels, isEmpty);
      expect(paramsOnly.reasoningUnknown, isFalse);
    },
  );

  test('неожиданные типы значений не роняют разбор', () {
    final entry = ProviderCatalogService.parseEntry(
      <String, dynamic>{
        'id': 'vendor/weird',
        'context_length': '128000',
        'reasoning': true,
        'pricing': 'oops',
        'top_provider': 'not-a-map',
        'parameters': true,
      },
      connection,
    );

    expect(entry.contextLength, 128000);
    // reasoning: true без списка: размышления заявлены, уровней нет —
    // дефолтный список больше не подставляется.
    expect(entry.reasoning, isNotNull);
    expect(entry.reasoning!.levels, isEmpty);
    expect(entry.priceIn, isNull);
    expect(entry.priceSource, isNull);
  });

  test('битая запись не роняет разбор остальных (parseCatalogResponse)', () {
    final body = '{"data": ['
        '{"id": "a/one"},'
        '42,'
        '{"no_id": true},'
        '{"id": "b/two", "type": "image"}'
        ']}';
    final entries = ProviderCatalogService.parseCatalogResponse(
      body,
      connection,
    );
    expect(entries.length, 2);
    expect(entries[0].id, 'a/one');
    expect(entries[1].id, 'b/two');
    expect(entries[1].type, 'image');
  });

  test(
    'T-R4-HEAL2-LIVE-CATALOG-STRING: общий каталог принимает строковый id '
    'и пропускает битые записи',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final service = ProviderCatalogService();

      server.listen((request) async {
        paths.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, dynamic>{
          'data': <Object?>[
            <String, dynamic>{'id': 'a/one'},
            'not-a-map',
            42,
            <String, dynamic>{'no_id': true},
            <String, dynamic>{'id': 'b/two', 'type': 'image'},
          ],
        }));
        await request.response.close();
      });

      try {
        final result = await service.sync(
          CatalogConnection(
            id: 'heal2-live-catalog',
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            apiKey: 'fixture',
          ),
          force: true,
        );

        expect(result.error, isNull);
        expect(paths, <String>['/v1/models']);
        expect(
          result.entries.map((entry) => entry.id).toList(),
          <String>['a/one', 'not-a-map', 'b/two'],
        );
        expect(result.entries.last.type, 'image');
      } finally {
        service.dispose();
        await server.close(force: true);
      }
    },
  );
}
