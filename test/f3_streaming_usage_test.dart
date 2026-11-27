// Copyright (c) 2026 Minkail. All rights reserved.
//
// F3-cost-line-3: доставка usage в СТРИМИНГОВОМ режиме. Ранее этот путь
// не был покрыт ни одним тестом: T2-UNIT-COST-NONSTREAM-ROUNDS проверял
// только нестримовый ответ, а живой тест 2026-11-27 (стриминговый чат
// deepseek) не показал ни стоимости, ни токенов.
//
// Формат usage Polza (docs: osobennosti/usage.md, Streaming режим):
// usage приходит в последнем SSE-сообщении перед [DONE], у чанка
// пустой choices; поля cost_rub и cost (рублёвый алиас).
//
// Тесты проверяют: запрос явно просит stream_options.include_usage,
// usage доходит до потребителя StreamChunk, MessageCost резолвит
// валюту RUB для cost_rub и НЕ выдумывает сумму для токен-only usage.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/core/models/message_part.dart';
import 'package:gentech_chat/services/chat_service.dart';

void main() {
  late HttpServer server;
  late Map<String, dynamic> lastRequest;

  setUp(() async {
    lastRequest = <String, dynamic>{};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String baseUrl() => 'http://127.0.0.1:${server.port}';

  /// Фикстура Polza-формата: стрим с usage-чанком перед [DONE]
  /// (usage == null — ответ вовсе без usage). Для нестримового запроса
  /// (когда сервис решает не стримить) отвечает JSON с тем же usage.
  void startFixture(Map<String, dynamic>? usage) {
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      lastRequest = Map<String, dynamic>.from(jsonDecode(body) as Map);
      if (lastRequest['stream'] == true) {
        final buffer = StringBuffer(
          'data: {"choices":[{"delta":{"content":"Привет"}}]}\n\n',
        );
        if (usage != null) {
          buffer.write(
            'data: {"choices":[],"usage":${jsonEncode(usage)}}\n\n',
          );
        }
        buffer.write('data: [DONE]\n\n');
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(buffer.toString());
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': 'Привет'},
              'finish_reason': 'stop',
            },
          ],
          if (usage != null) 'usage': usage,
        }));
      }
      await request.response.close();
    });
  }

  List<Map<String, dynamic>> usagesOf(List<StreamChunk> chunks) => [
        for (final c in chunks)
          if (c.usage != null) c.usage!,
      ];

  test(
    'F3-T-STREAM-USAGE-COST-RUB: стрим с cost_rub — запрос просит '
    'include_usage, usage доходит до потребителя, валюта резолвится в RUB',
    () async {
      startFixture(<String, dynamic>{
        'prompt_tokens': 10,
        'completion_tokens': 20,
        'total_tokens': 30,
        'cost_rub': 0.015,
        'cost': 0.015,
      });

      final chunks = await ChatService()
          .sendMessage(
            baseUrl: baseUrl(),
            apiKey: 'fixture',
            model: 'example',
            messages: <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'Привет'},
            ],
            stream: true,
          )
          .toList();

      // Запрос ЯВНО просит usage в потоке — без этого Polza его не пришлёт.
      expect(
        lastRequest['stream_options'],
        <String, dynamic>{'include_usage': true},
      );

      final usages = usagesOf(chunks);
      expect(usages, hasLength(1));
      expect(usages.first['cost_rub'], 0.015);

      // Строка стоимости: cost_rub -> валюта RUB -> «≈ … ₽».
      final cost = MessageCost.fromUsage(usages.first);
      expect(cost, isNotNull);
      expect(cost!.currency, 'RUB');
      expect(cost.cost, closeTo(0.015, 0.0000001));
      expect(cost.promptTokens, 10);
      expect(cost.completionTokens, 20);
      expect(cost.formatted, '0,015 ₽');
      expect(cost.totalTokens, 30);
    },
  );

  test(
    'F3-T-STREAM-USAGE-TOKENS-ONLY: стрим без стоимости — usage '
    'только с токенами доходит, сумма не выдумывается',
    () async {
      startFixture(<String, dynamic>{
        'prompt_tokens': 7,
        'completion_tokens': 3,
        'total_tokens': 10,
      });

      final chunks = await ChatService()
          .sendMessage(
            baseUrl: baseUrl(),
            apiKey: 'fixture',
            model: 'example',
            messages: <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'Привет'},
            ],
            stream: true,
          )
          .toList();

      expect(
        lastRequest['stream_options'],
        <String, dynamic>{'include_usage': true},
      );

      final usages = usagesOf(chunks);
      expect(usages, hasLength(1));
      expect(usages.first.containsKey('cost_rub'), isFalse);

      final cost = MessageCost.fromUsage(usages.first);
      expect(cost, isNotNull);
      // Контракт R4/R6 (тест 2): сумма неизвестна — null, а не ноль.
      expect(cost!.cost, isNull);
      expect(cost.totalTokens, 10);
    },
  );

  test(
    'F3-T-STREAM-USAGE-ABSENT: провайдер не прислал usage в стриме — '
    'потребитель не получает ни одного usage-чанка',
    () async {
      startFixture(null);

      final chunks = await ChatService()
          .sendMessage(
            baseUrl: baseUrl(),
            apiKey: 'fixture',
            model: 'example',
            messages: <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'Привет'},
            ],
            stream: true,
          )
          .toList();

      // Именно этот сценарий даёт «строки нет вообще» в живом тесте,
      // если провайдер не вернул usage: лог диагностики печатается.
      expect(usagesOf(chunks), isEmpty);
    },
  );
}
