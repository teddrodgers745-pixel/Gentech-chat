// Copyright (c) 2026 Minkail. All rights reserved.
//
// F4-markdown: рендер Markdown в ответах модели.
//
// Живой тест 2026-11-27 (сборка e1364fb, deepseek, скриншоты 09:44/09:47):
// ответ модели показывал литеральные `**` («...с файлами** — могу
// читать...») и неровный жирный (первое слово обычным шрифтом,
// следующие — жирным). Симптом соответствует потере ОДНОГО маркера
// из пары `**`: непарный маркер парсер рисует звёздочками текстом.
//
// Проверяется:
// - F4-T-PAIR-*: корректные пары (в т.ч. разбитые переносом строки)
//   ремонтом не затрагиваются;
// - F4-T-STRAY-*: односторонние «потерянные» маркеры удаляются до
//   разбора — на экране нет литеральных `**`, соседние пары живут;
// - F4-T-MATH-KEPT: нейтральный контекст (`2**3`, `2 ** 3`) не искажается;
// - F4-T-INLINE-CODE-KEPT / F4-T-FENCE-KEPT: код не трогается;
// - виджет-тесты RichMarkdown: жирный ложится ровно по маркерам,
//   ссылки/списки/blockquote не ломаются.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/widgets/message_view.dart';

void main() {
  // ---------- юнит-проверки ремонта маркеров ----------

  test('F4-T-PAIR-INTACT: корректная пара ** не трогается', () {
    expect(
      repairUnpairedEmphasis('Ответ с **жирным** текстом'),
      'Ответ с **жирным** текстом',
    );
  });

  test('F4-T-PAIR-CROSS-LINE: пара, разбитая переносом строки, жива', () {
    const src = 'начало **жирного\nфрагмента** конец';
    expect(repairUnpairedEmphasis(src), src);
  });

  test('F4-T-STRAY-CLOSE: потерянный открывающий — звёздочки убраны', () {
    // Точный сценарий живого теста: закрывающий ** без пары.
    expect(
      repairUnpairedEmphasis(
          'Конечно! Я умею работать с файлами** — могу читать содержимое.'),
      'Конечно! Я умею работать с файлами — могу читать содержимое.',
    );
  });

  test('F4-T-STRAY-OPEN: потерянный закрывающий — звёздочки убраны', () {
    expect(
      repairUnpairedEmphasis('Теперь **могу читать содержимое'),
      'Теперь могу читать содержимое',
    );
  });

  test('F4-T-MATH-KEPT: нейтральный контекст без пары не искажается', () {
    const src = 'Возведение 2**3 и 2 ** 3';
    expect(repairUnpairedEmphasis(src), src);
  });

  test('F4-T-INLINE-CODE-KEPT: звёздочки внутри `код` не трогаются', () {
    expect(
      repairUnpairedEmphasis('Пишем `a ** b` и потом x**'),
      'Пишем `a ** b` и потом x',
    );
  });

  test('F4-T-FENCE-KEPT: звёздочки внутри ```-блока не трогаются', () {
    const src = 'Пример:\n```python\nx = a ** b\n```\nГотово **так**';
    expect(repairUnpairedEmphasis(src), src);
  });

  test('F4-T-TRIPLE-KEPT: ряд из трёх звёздочек не разбивается', () {
    const src = '***выделение***';
    expect(repairUnpairedEmphasis(src), src);
  });

  test('F4-T-STRAY-IN-LIST: непарный маркер в списке убран, пары соседей живы',
      () {
    expect(
      repairUnpairedEmphasis('- умею читать файлы**\n- умею **писать код**'),
      '- умею читать файлы\n- умею **писать код**',
    );
  });

  // ---------- виджет-проверки рендера RichMarkdown ----------

  Widget host(String markdown) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: RichMarkdown(markdown)),
        ),
      );

  /// Все текстовые спаны отрендеренного markdown.
  List<TextSpan> allSpans(WidgetTester tester) {
    final spans = <TextSpan>[];
    void walk(InlineSpan? span) {
      if (span == null) return;
      if (span is TextSpan) {
        spans.add(span);
        span.children?.forEach(walk);
      }
    }

    for (final rich
        in tester.widgetList<RichText>(find.byType(RichText))) {
      walk(rich.text);
    }
    return spans;
  }

  String plainOf(List<TextSpan> spans) =>
      spans.map((s) => s.toPlainText()).join();

  bool hasBoldSpan(List<TextSpan> spans, String text) => spans.any((s) =>
      s.style?.fontWeight == FontWeight.w700 && s.toPlainText() == text);

  testWidgets(
    'F4-T-BOLD-RENDER: **жирный** без звёздочек, границы ровные, '
    'список не ломается',
    (tester) async {
      await tester.pumpWidget(host(
          'Ответ с **жирным** текстом и списком:\n'
          '- **первый**\n'
          '- второй'));
      await tester.pump();

      final spans = allSpans(tester);
      expect(plainOf(spans).contains('**'), isFalse,
          reason: 'литеральные ** не должны попадать на экран');
      expect(hasBoldSpan(spans, 'жирным'), isTrue);
      expect(hasBoldSpan(spans, 'первый'), isTrue);
    },
  );

  testWidgets(
    'F4-T-LIVE-STRAY: точный сценарий живого теста — непарный ** '
    'не рисуется, соседняя пара рендерится жирным',
    (tester) async {
      const broken = 'Конечно! Я умею работать с файлами** — могу читать '
          'содержимое ваших файлов. Теперь **попробую**.';
      await tester.pumpWidget(host(broken));
      await tester.pump();

      final spans = allSpans(tester);
      final plain = plainOf(spans);
      expect(plain.contains('**'), isFalse,
          reason: 'непарные звёздочки не должны попадать на экран');
      expect(plain.contains('файлами — могу читать'), isTrue,
          reason: 'текст после убранного маркера сохраняется целиком');
      expect(hasBoldSpan(spans, 'попробую'), isTrue,
          reason: 'соседняя корректная пара рендерится жирным ровно '
              'по маркерам');
    },
  );

  testWidgets(
    'F4-T-NEIGHBORS: ссылки и blockquote не ломаются ремонтом '
    '(жирный внутри рендерится без звёздочек)',
    (tester) async {
      await tester.pumpWidget(host(
          'См. [**документацию**](https://polza.ai) и список:\n'
          '- **первый пункт**\n'
          '- второй пункт\n\n'
          '> **важно** запомнить'));
      await tester.pump();

      final spans = allSpans(tester);
      expect(plainOf(spans).contains('**'), isFalse);
      expect(hasBoldSpan(spans, 'документацию'), isTrue);
      expect(hasBoldSpan(spans, 'первый пункт'), isTrue);
      expect(hasBoldSpan(spans, 'важно'), isTrue,
          reason: 'flutter_markdown_plus >= 1.0.8: жирный внутри '
              'blockquote рендерится');
    },
  );
}
