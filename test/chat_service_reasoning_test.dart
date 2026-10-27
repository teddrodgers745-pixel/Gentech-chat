// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/models/tool.dart';
import 'package:gentech_chat/services/chat_service.dart';

void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> requests;
  var toolRounds = 0;

  setUp(() async {
    requests = <Map<String, dynamic>>[];
    toolRounds = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/tool') {
        request.response.write('{"result":"ok"}');
        await request.response.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final data = Map<String, dynamic>.from(jsonDecode(body) as Map);
      requests.add(data);
      if (data['stream'] == true) {
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(
          'data: {"choices":[{"delta":{"content":"Ответ"}}]}\n\n'
          'data: [DONE]\n\n',
        );
      } else {
        request.response.headers.contentType = ContentType.json;
        final message = requests.length <= toolRounds
            ? <String, dynamic>{
                'content': '',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_1',
                    'function': <String, dynamic>{
                      'name': 'test_tool',
                      'arguments': '{}',
                    },
                  },
                ],
              }
            : <String, dynamic>{'content': 'Ответ'};
        request.response.write(jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{'message': message},
          ],
        }));
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String baseUrl() => 'http://127.0.0.1:${server.port}';

  test('без режима размышлений поле не отправляется', () async {
    final chunks = await ChatService()
        .sendMessage(
          baseUrl: baseUrl(),
          apiKey: '',
          model: 'example',
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Привет'},
          ],
          stream: false,
        )
        .toList();

    expect(chunks.single.content, 'Ответ');
    expect(requests.single.containsKey('reasoning_effort'), isFalse);
  });

  test('потоковый запрос отправляет высокий уровень размышлений', () async {
    final chunks = await ChatService()
        .sendMessage(
          baseUrl: baseUrl(),
          apiKey: '',
          model: 'example',
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Привет'},
          ],
          reasoningEffort: 'high',
        )
        .toList();

    expect(chunks.single.content, 'Ответ');
    expect(requests.single['reasoning_effort'], 'high');
  });

  test('уровень размышлений сохраняется во всех раундах инструментов', () async {
    toolRounds = 4;
    final tool = Tool(
      id: 'test',
      name: 'test_tool',
      endpoint: '${baseUrl()}/tool',
    );
    final chunks = await ChatService()
        .sendMessage(
          baseUrl: baseUrl(),
          apiKey: '',
          model: 'example',
          messages: <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Привет'},
          ],
          stream: false,
          reasoningEffort: 'high',
          tools: <Tool>[tool],
        )
        .toList();

    expect(chunks.last.content, 'Ответ');
    expect(requests, hasLength(5));
    for (final request in requests) {
      expect(request['reasoning_effort'], 'high');
    }
  });
}
