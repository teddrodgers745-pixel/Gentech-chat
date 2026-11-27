// Copyright (c) 2026 Minkail. All rights reserved.
//
// F5-image-load: повторная загрузка картинки не создаёт новую генерацию.
//
// F5-T-IMAGE-RELOAD-NO-REGEN: картинка из ImagePart.fromUrl, чей URL
// временно недоступен (как DNS-сбой 'polza.ai' в живом тесте), сначала
// показывает заглушку «Не удалось загрузить изображение» с кнопкой
// «Повторить загрузку» (виджет _RetryableNetworkImage из F1, без
// дублирования); после нажатия повторяет ЗАГРУЗКУ ТОГО ЖЕ URL —
// картинка появляется, ни одного POST (новой генерации) на сервере нет.
//
// Сеть настоящая: зона с реальными HttpOverrides (тот же приём, что в
// f1_retry_resume_test.dart) — локальный HttpServer отвечает реальным
// HttpClient, а не заглушкой binding.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
// F5-gallery-image-load-heal1: импорт сохранён по правилам проекта
// (не удалять существующие импорты). Сервисы (MethodChannel/мок
// path_provider) в этом тесте не используются — он не мокает платформенные
// каналы, в отличие от f1_retry_resume_test.dart, откуда импорт был скопирован.
// ignore: unused_import
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/core/models/message_part.dart';
import 'package:gentech_chat/models/chat_message.dart';
import 'package:gentech_chat/widgets/message_view.dart';

/// Зона с живыми локальными HttpServer: каждый HttpClient() получает
/// собственный настоящий клиент через базовую реализацию dart:io.
class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}

void main() {
  testWidgets(
    'F5-T-IMAGE-RELOAD-NO-REGEN: «Повторить загрузку» перезапрашивает '
    'ТОТ ЖЕ URL — без новой генерации (ни одного POST)',
    (tester) async {
      // Валидный 1x1 PNG.
      const pngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
          'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

      await HttpOverrides.runWithHttpOverrides<Future<void>>(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var gets = 0;
        var posts = 0;
        server.listen((request) async {
          if (request.method == 'POST') {
            // Любая новая генерация ушла бы POST-ом на этот адрес.
            posts++;
            await utf8.decoder.bind(request).join();
            request.response.statusCode = 500;
            await request.response.close();
            return;
          }
          gets++;
          if (gets <= 1) {
            // Первая загрузка «падает» — как DNS-сбой из живого теста.
            request.response.statusCode = 503;
            await request.response.close();
            return;
          }
          request.response.headers.contentType =
              ContentType('image', 'png');
          request.response.add(base64Decode(pngBase64));
          await request.response.close();
        });

        final url = 'http://127.0.0.1:${server.port}/img.png';
        final msg = ChatMessage(
          id: 'f5-reload',
          role: 'assistant',
          parts: <MessagePart>[ImagePart.fromUrl(url)],
        );

        try {
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MessageView(message: msg),
              ),
            ),
          ));

          // Первая загрузка стартовала; даём сетевому стеку реальное
          // время и ждём появления заглушки ошибки.
          var errorShown = false;
          for (var i = 0; i < 40 && !errorShown; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump();
            errorShown = find
                .text('Не удалось загрузить изображение')
                .evaluate()
                .isNotEmpty;
          }

          await tester.tap(find.text('Повторить загрузку'));
          await tester.pump();

          // Повтор ТОГО ЖЕ URL: ждём появления картинки (заглушка уходит).
          var loaded = false;
          for (var i = 0; i < 40 && !loaded; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump();
            loaded = find
                .text('Не удалось загрузить изображение')
                .evaluate()
                .isEmpty;
          }

          expect(errorShown, isTrue,
              reason: 'первая загрузка URL не удалась — показана заглушка');
          expect(loaded, isTrue,
              reason: 'картинка должна появиться после повтора загрузки '
                  'без новой генерации');
        } finally {
          await server.close(force: true);
        }

        expect(posts, 0,
            reason: 'повторная загрузка не должна создавать новую '
                'задачу генерации');
        expect(gets, greaterThanOrEqualTo(2),
            reason: 'загрузка повторена для того же URL');
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
