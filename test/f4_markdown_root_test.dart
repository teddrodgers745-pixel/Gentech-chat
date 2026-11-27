// Copyright (c) 2026 Minkail. All rights reserved.
//
// F4-markdown-root: корень потери/дублирования пар `**` при стриминге —
// двойная запись reply.content в ChatScreen._runCompletion. Слушатель
// onPaced перезаписывал reply.content = pacer.shown из Ticker пейсера,
// а цикл `await for` одновременно конкатенировал reply.content +=
// ch.content (порция пейсера из StreamController доходила до цикла на
// следующем микротаске). Длина становилась больше pacer.shown, условие
// onPaced переставало срабатывать, и куски по 2-3 символа (половинки
// `**слово**`) дублировались на стыках.
//
// Исправление: слушатель onPaced удалён. Пейсер живёт ТОЛЬКО внутри
// ChatService._pacedStream: каждый chunk.content проходит через
// pacer.add(...), наружу выдаются порции pacer.onTick и остаток
// pacer.flush() в onDone — каждый символ потока доходит до потребителя
// РОВНО ОДИН РАЗ. Поэтому единственный корректный потребитель контента —
// последовательная конкатенация чанков (как reply.content += ch.content
// в ChatScreen._runCompletion): конкатенация обязана воспроизводить ответ
// провайдера символ в символ, без дублирования порций и без потерь.
//
// Тесты (живой локальный HttpServer, как в chat_service_reasoning_test):
// - F4-T-ROOT-STREAM-ASSEMBLY: стрим с парами ** маленькими кусками —
//   конкатенация чанков равна источнику побайтно, все пары ** целы
//   (инвариант приёмки F4-LIVE-MARKDOWN-ROOT для «Копировать»/TTS);
// - F4-T-ROOT-STREAM-BACKLOG: крупный ответ одним delta — flush пейсера
//   в onDone доставляет остаток целиком, ни один символ не теряется;
// - F4-T-ROOT-NONSTREAM: нестримовый путь возвращает ответ одним чанком
//   без изменений.
//
// Существующие F4-тесты рендера (test/f4_markdown_render_test.dart)
// остаются: repairUnpairedEmphasis в RichMarkdown сохранена как
// страховка рендера.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/services/chat_service.dart';

const String sourceText = '## План работ\n'
    '- **первый** пункт плана\n'
    '- **второй** пункт плана\n'
    '- **третий** пункт плана\n\n'
    'Итог: **всё готово** к запуску, **жирные** заголовки ровные.';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String baseUrl() => 'http://127.0.0.1:${server.port}';

  /// Стримит [text] SSE-дельтами по [piece] символа — как порции
  /// провайдера (и ровно как порции пейсера: половинки пар `**`).
  void streamTextInPieces(String text, {int piece = 3}) {
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      for (var i = 0; i < text.length; i += piece) {
        final end = (i + piece > text.length) ? text.length : i + piece;
        final part = text.substring(i, end);
        request.response.write(
          'data: {"choices":[{"delta":{"content":'
          '${jsonEncode(part)}}}]}\n\n',
        );
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
  }

  test(
    'F4-T-ROOT-STREAM-ASSEMBLY: конкатенация чанков воспроизводит ответ '
    'провайдера символ в символ — дубли порций и потери исключены, '
    'все пары ** целы',
    () async {
      streamTextInPieces(sourceText);
      final service = ChatService();

      // Потребитель ровно как ChatScreen._runCompletion после фикса:
      // единственный источник контента — цикл await for, только
      // последовательное `+= ch.content`, никаких перезаписей из пейсера.
      final assembled = StringBuffer();
      await for (final ch in service.sendMessage(
        baseUrl: baseUrl(),
        apiKey: 'fixture',
        model: 'example',
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'План'},
        ],
        stream: true,
      )) {
        assembled.write(ch.content);
      }

      // Точное совпадение исключает ОБЕ половины прежнего дефекта:
      // дублирование кусков (длина была бы больше) и потери кусков
      // (длина была бы меньше, «рваный» жирный на стыках).
      expect(
        assembled.toString(),
        sourceText,
        reason: 'reply.content обязан собираться строго из StreamChunk: '
            'двойная запись (onPaced + await for) запрещена',
      );
      expect(assembled.length, sourceText.length);

      // Инвариант приёмки F4-LIVE-MARKDOWN-ROOT: в сыром тексте
      // («Копировать», TTS) все пары ** целые.
      final markers = '**'.allMatches(assembled.toString()).length;
      expect(markers, '**'.allMatches(sourceText).length);
      expect(markers % 2, 0, reason: 'число маркеров ** чётное — пары целы');

      // Пейсер вычищен вместе со стримом: у UI нет контракта «дочитывать»
      // pacer.shown — такой контракт и создавал гонку.
      expect(service.activePacer, isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'F4-T-ROOT-STREAM-BACKLOG: крупный ответ одной delta — flush пейсера '
    'в onDone доставляет остаток целиком',
    () async {
      // Длинный текст (больше буфера одного тика): если бы потребитель
      // зависел от pacer.shown/порций, хвост терялся бы либо
      // дублировался. flush() в onDone гарантирует полный хвост.
      final long =
          'Ответ с **жирными** фрагментами и списком:\n${List.generate(
        120,
        (i) => '- **пункт ${i + 1}** описание пункта ${i + 1}',
      ).join('\n')}\n\nФинал: **готово**.';
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(
          'data: {"choices":[{"delta":{"content":'
          '${jsonEncode(long)}}}]}\n\n'
          'data: [DONE]\n\n',
        );
        await request.response.close();
      });

      final assembled = StringBuffer();
      await for (final ch in ChatService().sendMessage(
        baseUrl: baseUrl(),
        apiKey: 'fixture',
        model: 'example',
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'Список'},
        ],
        stream: true,
      )) {
        assembled.write(ch.content);
      }

      expect(assembled.toString(), long);
      expect('**'.allMatches(assembled.toString()).length % 2, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'F4-T-ROOT-NONSTREAM: нестримовый ответ приходит одним чанком '
    'без изменений, пары ** целы',
    () async {
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': sourceText},
              'finish_reason': 'stop',
            },
          ],
        }));
        await request.response.close();
      });

      final chunks = await ChatService()
          .sendMessage(
            baseUrl: baseUrl(),
            apiKey: 'fixture',
            model: 'example',
            messages: <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'План'},
            ],
            stream: false,
          )
          .toList();

      expect(chunks.single.content, sourceText);
      expect(
        '**'.allMatches(chunks.single.content).length % 2,
        0,
        reason: 'пары ** целы и в нестримовом пути',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
