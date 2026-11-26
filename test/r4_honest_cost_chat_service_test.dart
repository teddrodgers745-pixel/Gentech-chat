// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/app_state.dart';
import 'package:gentech_chat/models/tool.dart';
import 'package:gentech_chat/services/chat_service.dart';

void main() {
  late HttpServer server;
  late String previousSearchMode;
  var completionRequests = 0;
  var return402 = false;

  setUp(() async {
    previousSearchMode = settings.searchMode;
    settings.searchMode = 'off';
    completionRequests = 0;
    return402 = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    server.listen((request) async {
      if (request.uri.path == '/tool') {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"result":"ok"}');
        await request.response.close();
        return;
      }

      await utf8.decoder.bind(request).join();
      completionRequests++;
      request.response.headers.contentType = ContentType.json;

      if (return402) {
        request.response.statusCode = 402;
        request.response.write(jsonEncode(<String, dynamic>{
          'error': <String, dynamic>{
            'code': 'KEY_LIMIT_EXCEEDED',
            'message': 'Превышен лимит ключа.',
          },
        }));
        await request.response.close();
        return;
      }

      final firstRound = completionRequests == 1;
      request.response.write(jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': firstRound
                ? <String, dynamic>{
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'call_1',
                        'type': 'function',
                        'function': <String, dynamic>{
                          'name': 'fixture_tool',
                          'arguments': '{}',
                        },
                      },
                    ],
                  }
                : <String, dynamic>{'content': 'Готово'},
          },
        ],
        'usage': <String, dynamic>{
          'prompt_tokens': firstRound ? 10 : 20,
          'completion_tokens': firstRound ? 2 : 4,
          'cost_rub': firstRound ? 1.25 : 2.5,
        },
      }));
      await request.response.close();
    });
  });

  tearDown(() async {
    settings.searchMode = previousSearchMode;
    await server.close(force: true);
  });

  String baseUrl() => 'http://127.0.0.1:${server.port}';

  test('T2-UNIT-COST-NONSTREAM-ROUNDS: usage каждого раунда доходит до клиента',
      () async {
    final tool = Tool(
      id: 'fixture',
      name: 'fixture_tool',
      endpoint: '${baseUrl()}/tool',
    );
    final chunks = await ChatService()
        .sendMessage(
          baseUrl: baseUrl(),
          apiKey: 'fixture',
          model: 'example/model',
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Запрос'},
          ],
          stream: false,
          tools: <Tool>[tool],
        )
        .toList();

    expect(completionRequests, 2);
    expect(chunks.map((chunk) => chunk.content).join(), 'Готово');
    final usages = <Map<String, dynamic>>[
      for (final chunk in chunks)
        if (chunk.usage != null) chunk.usage!,
    ];
    expect(usages, hasLength(2));
    expect(
      usages.map((usage) => usage['cost_rub']).toList(),
      <Object?>[1.25, 2.5],
    );
  });

  test('T2-UNIT-COST-402: причина лимита ключа не заменяется балансом', () async {
    return402 = true;

    final response = ChatService()
        .sendMessage(
          baseUrl: baseUrl(),
          apiKey: 'fixture',
          model: 'example/model',
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Запрос'},
          ],
          stream: false,
        )
        .toList();

    await expectLater(
      response,
      throwsA(
        isA<ChatServiceException>()
            .having((error) => error.statusCode, 'statusCode', 402)
            .having(
              (error) => error.message.toLowerCase(),
              'message',
              contains('лимит'),
            ),
      ),
    );
  });
}
