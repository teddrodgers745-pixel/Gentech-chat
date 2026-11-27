// Copyright (c) 2026 Minkail. All rights reserved.
//
// F2-search-provider: режим поиска «провайдер» (polza:web_search,
// серверный инструмент Polza, 0,50 ₽ за вызов) НЕ зависит от нативного
// поиска модели; режим «нативный» включается ТОЛЬКО у моделей с
// нативным поиском. Проверяется уровень payload-логики ChatService:
// builtinSearchTools (инструменты тела запроса), effectiveSearchMode
// (приведение режима к возможностям модели) и nativeSearchBodyPayload
// (web_search_options). TEMP-DIAG и фикс F1 не затрагиваются.

import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/core/search/search_strategy.dart';
import 'package:gentech_chat/services/chat_service.dart';

void main() {
  const polza = 'https://api.polza.ai/v1';

  setUp(() {
    ChatService.nativeSearchProbe = null;
    ChatService.toolSupportProbe = null;
  });

  tearDown(() {
    ChatService.nativeSearchProbe = null;
    ChatService.toolSupportProbe = null;
  });

  test(
    'F2-T-PROVIDER-TOOL: режим «провайдер» отправляет polza:web_search '
    'независимо от нативного поиска модели',
    () {
      // Модель БЕЗ нативного поиска (как nemotron nano 30b) —
      // серверный инструмент провайдера всё равно прикрепляется.
      ChatService.nativeSearchProbe = (_) => false;

      expect(
        ChatService.effectiveSearchMode(
          baseUrl: polza,
          model: 'nemotron-nano-30b',
          mode: SearchMode.provider,
        ),
        SearchMode.provider,
      );

      final tools = ChatService.builtinSearchTools(
        baseUrl: polza,
        model: 'nemotron-nano-30b',
        searchEnabled: true,
        mode: SearchMode.provider,
        webSearchSupported: false,
      );
      expect(
        tools.any((t) => t['type'] == 'polza:web_search'),
        isTrue,
        reason: 'режим «провайдер» не должен блокироваться '
            'отсутствием нативного поиска модели',
      );
    },
  );

  test(
    'F2-T-NATIVE-GATE: «нативный» у модели без нативного поиска '
    'не имитирует поиск — режим приведён к «провайдер», '
    'web_search_options не отправляется',
    () {
      ChatService.nativeSearchProbe = (_) => false;

      // Эффективный режим — «провайдер»: реальный поиск, а не молчаливый
      // ответ без поиска и не выдуманные ссылки.
      expect(
        ChatService.effectiveSearchMode(
          baseUrl: polza,
          model: 'nemotron-nano-30b',
          mode: SearchMode.native,
        ),
        SearchMode.provider,
      );

      final tools = ChatService.builtinSearchTools(
        baseUrl: polza,
        model: 'nemotron-nano-30b',
        searchEnabled: true,
        mode: SearchMode.native,
        webSearchSupported: false,
      );
      expect(
        tools.any((t) => t['type'] == 'polza:web_search'),
        isTrue,
        reason: 'фоллбэк «нативный» -> «провайдер»: поиск выполняется '
            'серверным инструментом, а не выдуманными ссылками',
      );
    },
  );

  test(
    'F2-T-NATIVE-OK: «нативный» у модели С нативным поиском — '
    'web_search_options без серверного инструмента',
    () {
      ChatService.nativeSearchProbe = (_) => true;

      expect(
        ChatService.effectiveSearchMode(
          baseUrl: polza,
          model: 'native-search-model',
          mode: SearchMode.native,
        ),
        SearchMode.native,
      );

      final tools = ChatService.builtinSearchTools(
        baseUrl: polza,
        model: 'native-search-model',
        searchEnabled: true,
        mode: SearchMode.native,
        webSearchSupported: false,
      );
      expect(tools, isEmpty);

      // Параметр нативного поиска уходит в тело запроса.
      expect(
        ChatService.nativeSearchBodyPayload(polza),
        isNotEmpty,
      );
    },
  );

  test(
    'F2-T-PROVIDER-NO-TOOLS: модель без вызова инструментов — '
    'серверный инструмент не прикрепляется, поиск уходит в предзапрос '
    '«модель-инструмент»',
    () {
      ChatService.nativeSearchProbe = (_) => false;
      ChatService.toolSupportProbe = (_) => false;

      final tools = ChatService.builtinSearchTools(
        baseUrl: polza,
        model: 'plain-chat',
        searchEnabled: true,
        mode: SearchMode.provider,
        webSearchSupported: false,
        toolsSupported: false,
      );
      expect(tools, isEmpty);
    },
  );

  test(
    'F2-T-SEARCH-OFF: поиск выключен — инструменты поиска не добавляются',
    () {
      ChatService.nativeSearchProbe = (_) => true;

      final tools = ChatService.builtinSearchTools(
        baseUrl: polza,
        model: 'native-search-model',
        searchEnabled: false,
        mode: SearchMode.provider,
        webSearchSupported: true,
      );
      expect(tools, isEmpty);
    },
  );

  test(
    'F2-T-NATIVE-POLZA-ONLY: не-Polza провайдерам web_search_options '
    'не выдумывается',
    () {
      expect(
        ChatService.nativeSearchBodyPayload('https://example.com/v1'),
        isEmpty,
      );
    },
  );
}
