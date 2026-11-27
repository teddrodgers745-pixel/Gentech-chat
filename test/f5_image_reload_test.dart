// Copyright (c) 2026 Minkail. All rights reserved.
//
// F5-image-load: повторная загрузка картинки не создаёт новую генерацию.
//
// F5-T-IMAGE-RELOAD-NO-REGEN: картинка из ImagePart.fromUrl, чей URL
// временно недоступен (как DNS-сбой 'polza.ai' в живом тесте), сначала
// показывает заглушку «Не удалось загрузить изображение» с кнопкой
// «Повторить загрузку» (виджет _RetryableNetworkImage из F1, без
// дублирования); после нажатия повторяет ЗАГРУЗКУ ТОГО ЖЕ URL —
// картинка появляется, ни одного POST (новой генерации) нет.
//
// F5-gallery-image-load-heal2: причина таймаута предыдущей версии фикстуры
// (TimeoutException после 2 минут, шаг Run tests CI-запуска 46013163126) —
// НЕ продакшн-код, а сама фикстура. Она поднимала живой HttpServer и ждала
// сеть окнами tester.runAsync внутри testWidgets. testWidgets работает в
// fake-async: фьючерсы, зависящие от реального ввода-вывода, не разрешаются
// между окнами runAsync — документированная ловушка (api.flutter.dev,
// WidgetTester.runAsync: «If your widget test hangs and you are using
// runAsync… Fake async environment is unable to resolve a future…»).
// По рекомендациям того же API («restructure your code so you do not need
// runAsync») HttpClient замокан через HttpOverrides-зону: ответы
// возвращаются мгновенно (microtask), весь путь загрузки детерминированно
// разрешается в fake-async обычными pump. Проверяемое поведение не меняется:
// первая загрузка 503 -> заглушка -> «Повторить загрузку» -> второй GET
// ТОГО ЖЕ URL -> заглушка уходит; POST = 0.
//
// F5-gallery-image-load-2: единственная ошибка анализатора после heal2 —
// prefer_const_constructors на ImagePart.fromUrl(url) ниже (flutter analyze
// в analysis_options.yaml включает этот lint, и CI падает на любом
// findings, включая info). ImagePart.fromUrl — const-конструктор,
// url — const-переменная: вызов const-оспособен. Добавлен const, сам вызов
// не изменён; ChatMessage без const — у него нет const-конструктора
// (мутабельные поля content/errorCode/...), подтверждено зелёным Analyze
// теста f5_gallery_media_test.dart с теми же не-const ChatMessage.
//
// F5-gallery-image-load-2-heal1: анализатор ругался
// «Undefined class 'StreamSubscription'» на переопределение listen в
// _MockHttpClientResponse. Причина — отсутствие импорта dart:async:
// StreamSubscription живёт в dart:async и НЕ экспортируется через
// dart:convert, dart:io или flutter/material, на которые опирался тест.
// Мок HttpClientResponse наследует Stream<List<int>> и обязан вернуть
// StreamSubscription в listen — тип нужен явно. Исправление минимальное:
// добавлен import 'dart:async'; логика теста не менялась.

import 'dart:async';
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

/// Валидный 1x1 PNG для успешной (повторной) загрузки.
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// Счётчики HTTP-вызовов фикстуры: GET — по URL (проверка «тот же URL»),
/// POST — любая новая генерация обязана дать ноль.
class _FixtureState {
  final List<String> gets = <String>[];
  final List<String> posts = <String>[];
}

/// HttpOverrides-зона теста: каждый HttpClient() (в том числе общий
/// NetworkImage._sharedHttpClient, создаваемый при первой сетевой картинке)
/// получает мок с мгновенными ответами — без реального ввода-вывода и
/// без runAsync.
class _MockHttpOverrides extends HttpOverrides {
  _MockHttpOverrides(this.state);

  final _FixtureState state;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _MockHttpClient(state);
}

/// Мок HttpClient: GET-загрузки считаются по URL; первая — 503 (как
/// DNS-сбой из живого теста), повторные — валидный PNG. Не-GET (POST) —
/// это новая генерация/создание задачи: фиксируется, проверка требует нуля.
class _MockHttpClient implements HttpClient {
  _MockHttpClient(this.state);

  final _FixtureState state;

  Future<HttpClientRequest> _open(String method, Uri url) {
    final String m = method.toUpperCase();
    if (m == 'GET') {
      state.gets.add(url.toString());
      if (state.gets.length <= 1) {
        return Future<HttpClientRequest>.value(
          _MockHttpClientRequest(
            _MockHttpClientResponse(503, const <int>[]),
          ),
        );
      }
      return Future<HttpClientRequest>.value(
        _MockHttpClientRequest(
          _MockHttpClientResponse(200, base64Decode(_pngBase64)),
        ),
      );
    }
    state.posts.add('$m $url');
    return Future<HttpClientRequest>.value(
      _MockHttpClientRequest(
        _MockHttpClientResponse(500, const <int>[]),
      ),
    );
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _open(method, url);

  // NetworkImage задаёт autoUncompress; остальные незадействованные члены
  // HttpClient закрываются noSuchMethod'ом (пустое поведение).
  @override
  bool get autoUncompress => false;

  @override
  set autoUncompress(bool value) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MockHttpClientRequest implements HttpClientRequest {
  _MockHttpClientRequest(this.response);

  final _MockHttpClientResponse response;

  @override
  Future<HttpClientResponse> close() =>
      Future<HttpClientResponse>.value(response);

  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MockHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _MockHttpClientResponse(this.statusCode, this.bytes)
      : contentLength = bytes.length,
        _inner = Stream<List<int>>.fromIterable(<List<int>>[bytes]);

  @override
  final int statusCode;

  @override
  final int contentLength;

  final List<int> bytes;

  final Stream<List<int>> _inner;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _inner.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError ?? false,
    );
  }

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  HttpHeaders get headers => _MockHttpHeaders();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MockHttpHeaders implements HttpHeaders {
  @override
  String? value(String name) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets(
    'F5-T-IMAGE-RELOAD-NO-REGEN: «Повторить загрузку» перезапрашивает '
    'ТОТ ЖЕ URL — без новой генерации (ни одного POST)',
    (tester) async {
      final state = _FixtureState();
      const url = 'http://fixture.invalid/img.png';
      final msg = ChatMessage(
        id: 'f5-reload',
        role: 'assistant',
        // const обязателен: ImagePart.fromUrl — const-конструктор, url —
        // const-переменная; иначе prefer_const_constructors валит Analyze.
        parts: <MessagePart>[const ImagePart.fromUrl(url)],
      );

      await HttpOverrides.runWithHttpOverrides<Future<void>>(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageView(message: msg),
            ),
          ),
        ));

        // Первая загрузка «падает» (503): ждём появления заглушки ошибки.
        // Бюджет fake-времени до тапа — 1 с (< 2 с авто-повтора фикстуры):
        // проверяется именно РУЧНАЯ кнопка «Повторить загрузку».
        var errorShown = false;
        for (var i = 0; i < 10 && !errorShown; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          errorShown = find
              .text('Не удалось загрузить изображение')
              .evaluate()
              .isNotEmpty;
        }
        expect(errorShown, isTrue,
            reason: 'первая загрузка URL не удалась — показана заглушка');
        expect(find.text('Повторить загрузку'), findsOneWidget);

        await tester.tap(find.text('Повторить загрузку'));
        await tester.pump();

        // Повтор ТОГО ЖЕ URL: заглушка уходит — загрузка пошла заново,
        // картинка появляется без какой-либо новой генерации.
        var stubGone = false;
        for (var i = 0; i < 10 && !stubGone; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          stubGone = find
              .text('Не удалось загрузить изображение')
              .evaluate()
              .isEmpty;
        }
        expect(stubGone, isTrue,
            reason: 'картинка появляется после повтора загрузки '
                'без новой генерации');

        expect(state.posts, isEmpty,
            reason: 'повторная загрузка не должна создавать новую '
                'задачу генерации');
        expect(state.gets, hasLength(2),
            reason: 'загрузка выполнена дважды: исходная + повтор');
        expect(state.gets.toSet().length, 1,
            reason: 'повторяется ТОТ ЖЕ URL, а не другой источник');
      }, _MockHttpOverrides(state));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
