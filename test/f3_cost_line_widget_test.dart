// Copyright (c) 2026 Minkail. All rights reserved.
//
// F3-cost-line-3: строка стоимости/токенов под ответом модели.
//
// F3-T-COST-LINE-BOTH: MessageCost с суммой и токенами рендерит ОБА —
// стоимость с ПОЛНОЙ точностью ('1,875 ₽', а не '1,88 ₽') и токены,
// формат «≈ X ₽ · N ток.» (приёмка F3-LIVE-COST-LINE).
//
// F3-T-COST-LINE-TOKENS-ONLY: MessageCost без суммы (null cost) рендерит
// ТОЛЬКО токены — ни «≈ 0,00 ₽», ни «$0,00», ни «Стоимость неизвестна»
// (приёмка F3-LIVE-COST-TOKENS-ONLY, контракт R4/R6 тест 2).
//
// F3-COST-TOGGLE (обновление, 2026-11-27; прецедент — обновление теста
// парсера reasoning в R4): старый тест F3-T-COST-LINE-SETTING-OFF
// зацементировал БАГ — ранний return в MessageView._costWidgets гасил
// ВСЮ строку (и стоимость, и токены) при выключенном тумблере showCost.
// Живой тест: «при выключении стоимости токены тоже уходят». Новое
// эталонное поведение (контракт R4/F3: токены — когда известны;
// стоимость — когда известна И включена):
//  - стоимость вкл + токены известны -> «≈ X ₽ · N ток.»;
//  - стоимость вкл + токенов нет -> «≈ X ₽»;
//  - стоимость выкл + токены известны -> «N ток.», без «≈ X ₽»;
//  - стоимость выкл + токенов нет -> строки нет вообще.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/app_state.dart';
import 'package:gentech_chat/core/models/message_part.dart';
import 'package:gentech_chat/models/chat_message.dart';
import 'package:gentech_chat/widgets/message_view.dart';

void main() {
  ChatMessage replyWithCost(MessageCost? cost) => ChatMessage(
        id: 'f3-cost-msg',
        role: 'assistant',
        content: 'Ответ модели',
        parts: cost == null
            ? const <MessagePart>[]
            : <MessagePart>[TextPart('', cost: cost)],
      );

  Widget host(ChatMessage msg) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageView(message: msg),
          ),
        ),
      );

  /// Переключает showCost на [value] и возвращает прежнее значение
  /// в tearDown: тесты не должны зависеть от порядка в файле.
  void setShowCost(bool value) {
    final was = settings.showCost;
    addTearDown(() => settings.setShowCost(was));
    settings.setShowCost(value);
  }

  testWidgets(
    'F3-T-COST-LINE-BOTH: сумма с полной точностью и токены — '
    'оба показаны («≈ 1,875 ₽ · 30 ток.»)',
    (tester) async {
      setShowCost(true);

      await tester.pumpWidget(host(replyWithCost(const MessageCost(
        cost: 1.875,
        currency: 'RUB',
        promptTokens: 10,
        completionTokens: 20,
      ))));

      expect(find.text('≈ 1,875 ₽ · 30 ток.'), findsOneWidget);
      // Полная точность: дробные копейки не отбрасываются.
      expect(find.text('≈ 1,88 ₽ · 30 ток.'), findsNothing);
    },
  );

  testWidgets(
    'F3-T-COST-LINE-AMOUNT-ONLY: стоимость включена, токенов нет — '
    'только сумма, без счётчиков',
    (tester) async {
      setShowCost(true);

      await tester.pumpWidget(host(replyWithCost(const MessageCost(
        cost: 1.875,
        currency: 'RUB',
      ))));

      expect(find.text('≈ 1,875 ₽'), findsOneWidget);
      expect(find.textContaining('ток.'), findsNothing);
    },
  );

  testWidgets(
    'F3-T-COST-LINE-TOKENS-ONLY: сумма неизвестна — только токены, '
    'ноль и «неизвестно» не подставляются',
    (tester) async {
      setShowCost(true);

      await tester.pumpWidget(host(replyWithCost(const MessageCost(
        promptTokens: 10,
        completionTokens: 20,
      ))));

      expect(find.text('30 ток.'), findsOneWidget);
      expect(find.text('≈ 0,00 ₽'), findsNothing);
      expect(find.text(r'$0,00'), findsNothing);
      expect(find.text('Стоимость неизвестна'), findsNothing);
    },
  );

  testWidgets(
    'F3-T-COST-TOGGLE-OFF-TOKENS-STAY: показ стоимости выключен, '
    'токены известны — показывается «30 ток.», суммы «≈ X ₽» нет',
    (tester) async {
      setShowCost(false);

      await tester.pumpWidget(host(replyWithCost(const MessageCost(
        cost: 1.875,
        currency: 'RUB',
        promptTokens: 10,
        completionTokens: 20,
      ))));

      // НОВОЕ поведение: токены остаются, стоимость скрыта.
      expect(find.text('30 ток.'), findsOneWidget);
      expect(find.textContaining('≈'), findsNothing);
      expect(find.text('≈ 1,875 ₽ · 30 ток.'), findsNothing);
      // Строка не исчезает целиком: именно это чинит живой дефект
      // «при выключении стоимости токены тоже уходят».
      expect(find.textContaining('ток.'), findsOneWidget);
    },
  );

  testWidgets(
    'F3-T-COST-TOGGLE-OFF-NO-TOKENS: показ стоимости выключен, '
    'токенов нет — строки нет вовсе',
    (tester) async {
      setShowCost(false);

      // Сумма известна, но скрыта тумблером, токенов нет: показывать
      // нечего — строка не рендерится (приёмка F3-LIVE-COST-TOGGLE).
      await tester.pumpWidget(host(replyWithCost(const MessageCost(
        cost: 1.875,
        currency: 'RUB',
      ))));

      expect(find.textContaining('ток.'), findsNothing);
      expect(find.textContaining('≈'), findsNothing);
    },
  );

  testWidgets(
    'F3-T-COST-TOGGLE-OFF-EMPTY-COST: выключенный тумблер и пустой '
    'MessageCost (ни суммы, ни токенов) — строки нет',
    (tester) async {
      setShowCost(false);

      await tester.pumpWidget(host(replyWithCost(const MessageCost())));

      expect(find.textContaining('ток.'), findsNothing);
      expect(find.textContaining('≈'), findsNothing);
    },
  );
}
