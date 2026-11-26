// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/core/models/gen_error.dart';
import 'package:gentech_chat/core/models/gen_error_mapper.dart';
import 'package:gentech_chat/features/chat/widgets/error_bubble.dart';
import 'package:gentech_chat/services/chat_service.dart';

void main() {
  test('T-R4-402-STATUS-MAPPER: HTTP-статус важнее цифр в тексте', () {
    final error = GenErrorMapper.fromException(
      ChatServiceException(
        'Провайдер упомянул 402 в описании ограничения.',
        statusCode: 429,
      ),
    );

    expect(error, isA<RateLimited>());
    expect(GenErrorMapper.detailsOf(error), contains('402'));
  });

  testWidgets(
    'T-R4-402-MAPPER-WIDGET: причина лимита видна без утверждения о балансе',
    (tester) async {
      final error = GenErrorMapper.fromException(
        ChatServiceException(
          'Превышен лимит ключа.',
          statusCode: 402,
        ),
      );

      expect(error, isA<InsufficientFunds>());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ErrorBubble(error: error)),
        ),
      );

      expect(find.text('Ошибка оплаты или лимита'), findsOneWidget);
      expect(find.text('Превышен лимит ключа.'), findsOneWidget);
      expect(find.text('Недостаточно средств'), findsNothing);
      expect(find.text('Настройки'), findsOneWidget);
    },
  );
}
