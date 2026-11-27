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
// F3-T-COST-LINE-SETTING-OFF: при выключенном показе стоимости в
// настройках (settings.showCost == false) строки нет вообще.

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

  testWidgets(
    'F3-T-COST-LINE-BOTH: сумма с полной точностью и токены — '
    'оба показаны («≈ 1,875 ₽ · 30 ток.»)',
    (tester) async {
      await tester.pumpWidget(host(replyWithCost(MessageCost(
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
    'F3-T-COST-LINE-TOKENS-ONLY: сумма неизвестна — только токены, '
    'ноль и «неизвестно» не подставляются',
    (tester) async {
      await tester.pumpWidget(host(replyWithCost(MessageCost(
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
    'F3-T-COST-LINE-SETTING-OFF: показ стоимости выключен — строки нет',
    (tester) async {
      final was = settings.showCost;
      addTearDown(() => settings.setShowCost(was));
      settings.setShowCost(false);

      await tester.pumpWidget(host(replyWithCost(MessageCost(
        cost: 1.875,
        currency: 'RUB',
        promptTokens: 10,
        completionTokens: 20,
      ))));

      expect(find.text('≈ 1,875 ₽ · 30 ток.'), findsNothing);
    },
  );
}
