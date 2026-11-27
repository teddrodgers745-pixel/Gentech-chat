// Copyright (c) 2026 Minkail. All rights reserved.
//
// F2-settings-probe: виджет-тесты секции «ПОИСК» в настройках.
//
// Контракт F2: режим «Провайдер» = серверный инструмент polza:web_search,
// НЕ зависит от нативного поиска модели и НИКОГДА не показывает красный
// баннер «Текущая модель не поддерживает поиск». Режим «Нативный» у
// модели без нативного поиска — спокойная информационная подпись, а не
// ошибка. Настройки и чат используют ОДНО правило:
// ChatService.effectiveSearchMode (в тестах подменяется тем же
// nativeSearchProbe, что читает чат).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gentech_chat/app_state.dart';
import 'package:gentech_chat/services/chat_service.dart';
import 'package:gentech_chat/widgets/search_settings_section.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatService.nativeSearchProbe = null;
  });

  tearDown(() {
    ChatService.nativeSearchProbe = null;
  });

  Widget host() => const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SearchSettingsSection(),
          ),
        ),
      );

  testWidgets(
    'F2-T-SETTINGS-PROVIDER-NO-BANNER: режим «Провайдер» + модель без '
    'нативного поиска — баннера нет, спокойное пояснение',
    (tester) async {
      settings.baseUrl = 'https://api.polza.ai/v1';
      settings.model = 'nvidia/nemotron-3-nano-30b-a3b';
      settings.searchMode = 'provider';
      // Модель без нативного поиска — как nemotron nano 30b в живом тесте.
      ChatService.nativeSearchProbe = (_) => false;

      await tester.pumpWidget(host());
      await tester.pump();

      // Красного баннера и мёртвой кнопки «Повторить» нет.
      expect(
        find.textContaining('не поддерживает поиск'),
        findsNothing,
      );
      expect(find.text('Повторить'), findsNothing);
      // Проба не запускается: ни спиннера, ни зелёного баннера.
      expect(find.text('Проверка поддержки...'), findsNothing);
      expect(
        find.textContaining('поддерживает веб-поиск'),
        findsNothing,
      );
      // Режим описан спокойно, серверным инструментом Polza.
      expect(find.textContaining('polza:web_search'), findsOneWidget);
    },
  );

  testWidgets(
    'F2-T-SETTINGS-NATIVE-CALM: режим «Нативный» + модель без нативного '
    'поиска — спокойная подпись, а не ошибка',
    (tester) async {
      settings.baseUrl = 'https://api.polza.ai/v1';
      settings.model = 'nvidia/nemotron-3-nano-30b-a3b';
      settings.searchMode = 'native';
      ChatService.nativeSearchProbe = (_) => false;

      await tester.pumpWidget(host());
      await tester.pump();

      expect(
        find.text('У модели нет нативного поиска — будет использован поиск '
            'провайдера Polza.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('не поддерживает поиск'),
        findsNothing,
      );
      expect(find.text('Повторить'), findsNothing);
    },
  );

  testWidgets(
    'F2-T-SETTINGS-NATIVE-OK: режим «Нативный» + модель С нативным '
    'поиском — прежнее пояснение, без предупреждений',
    (tester) async {
      settings.baseUrl = 'https://api.polza.ai/v1';
      settings.model = 'native-search-model';
      settings.searchMode = 'native';
      ChatService.nativeSearchProbe = (_) => true;

      await tester.pumpWidget(host());
      await tester.pump();

      expect(
        find.text('Поиск выполняется самой моделью. Настройки не требуются.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('не поддерживает поиск'),
        findsNothing,
      );
      expect(find.text('Повторить'), findsNothing);
    },
  );
}
