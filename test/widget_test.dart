// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/main.dart';

void main() {
  testWidgets(
    'T-R4-HEAL1-APP-START: приложение показывает начальную заставку',
    (tester) async {
      await tester.pumpWidget(const GenTechChatApp());

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(SplashScreen), findsOneWidget);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
        'GenTech Chat',
      );

      // Дать таймеру заставки завершиться после удаления виджета.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 501));
      expect(tester.takeException(), isNull);
    },
  );
}
