// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter_test/flutter_test.dart';
import 'package:gentech_chat/core/models/cost_estimate.dart';
import 'package:gentech_chat/core/models/message_part.dart';

Map<String, dynamic> prices(List<Map<String, dynamic>> tiers) =>
    <String, dynamic>{'model_pricing_raw': tiers};

void main() {
  group('R4 — оценка по каталогу', () {
    test('T2-UNIT-COST-NO-FAMILY-FALLBACK: цена семейства не заменяет каталог',
        () {
      final estimate = CostEstimator.estimate(
        modelId: 'black-forest-labs/flux-schnell',
      );

      expect(estimate.isKnown, isFalse);
      expect(estimate.estimatedUsd, isNull);
    });

    test('T2-UNIT-COST-FLUX-2K: выбранный тир сохраняет точность 1,875 ₽',
        () {
      final estimate = CostEstimator.estimate(
        modelId: 'example/flux-klein',
        resolution: '2K',
        mediaParams: prices(<Map<String, dynamic>>[
          <String, dynamic>{
            'price': 1.875,
            'currency': 'RUB',
            'unit': 'image',
            'conditions': <String, dynamic>{'resolution': '2K'},
          },
        ]),
      );

      expect(estimate.isKnown, isTrue);
      expect(estimate.currency, 'RUB');
      expect(estimate.estimatedUsd, closeTo(1.875, 0.0000001));
      expect(estimate.formatted, contains('1,875'));
    });

    test('T2-UNIT-COST-UNKNOWN-DURATION: неизвестная длительность не равна 1',
        () {
      final estimate = CostEstimator.estimate(
        modelId: 'example/video',
        mediaParams: prices(<Map<String, dynamic>>[
          <String, dynamic>{
            'price': 2.565,
            'currency': 'RUB',
            'unit': 'second',
          },
        ]),
      );

      expect(estimate.isKnown, isFalse);
      expect(estimate.estimatedUsd, isNull);
    });

    test('T2-UNIT-COST-TOTAL-DURATION: итог не подписывается ценой за секунду',
        () {
      final estimate = CostEstimator.estimate(
        modelId: 'example/video',
        durationSeconds: 5,
        mediaParams: prices(<Map<String, dynamic>>[
          <String, dynamic>{
            'price': 2.565,
            'currency': 'RUB',
            'unit': 'second',
          },
        ]),
      );

      expect(estimate.isKnown, isTrue);
      expect(estimate.estimatedUsd, closeTo(12.825, 0.0000001));
      expect(estimate.formatted.toLowerCase(), isNot(contains('за секунду')));
    });

    test('T2-UNIT-COST-UNKNOWN-HAS-VIDEO: неизвестное условие не угадывается',
        () {
      final estimate = CostEstimator.estimate(
        modelId: 'example/video',
        resolution: '720p',
        durationSeconds: 5,
        mediaParams: prices(<Map<String, dynamic>>[
          <String, dynamic>{
            'price': 1.0,
            'currency': 'RUB',
            'unit': 'second',
            'conditions': <String, dynamic>{
              'resolution': '720p',
              'has_video': false,
            },
          },
          <String, dynamic>{
            'price': 2.0,
            'currency': 'RUB',
            'unit': 'second',
            'conditions': <String, dynamic>{
              'resolution': '720p',
              'has_video': true,
            },
          },
        ]),
      );

      expect(estimate.isKnown, isFalse);
      expect(estimate.estimatedUsd, isNull);
    });

    test('T2-UNIT-COST-UNKNOWN-CONDITION: неизвестное условие не игнорируется',
        () {
      final estimate = CostEstimator.estimate(
        modelId: 'example/image',
        mediaParams: prices(<Map<String, dynamic>>[
          <String, dynamic>{
            'price': 1.0,
            'currency': 'RUB',
            'unit': 'image',
            'conditions': <String, dynamic>{'quality': 'high'},
          },
        ]),
      );

      expect(estimate.isKnown, isFalse);
      expect(estimate.estimatedUsd, isNull);
    });

    test('T2-UNIT-COST-AMBIGUOUS-TIER: первый тир не побеждает автоматически',
        () {
      final estimate = CostEstimator.estimate(
        modelId: 'example/image',
        mediaParams: prices(<Map<String, dynamic>>[
          <String, dynamic>{
            'price': 1.0,
            'currency': 'RUB',
            'unit': 'image',
          },
          <String, dynamic>{
            'price': 2.0,
            'currency': 'RUB',
            'unit': 'image',
          },
        ]),
      );

      expect(estimate.isKnown, isFalse);
      expect(estimate.estimatedUsd, isNull);
    });

    test('T2-UNIT-COST-UNKNOWN-CURRENCY: валюта тарифа не угадывается', () {
      final estimate = CostEstimator.estimate(
        modelId: 'example/image',
        mediaParams: prices(<Map<String, dynamic>>[
          <String, dynamic>{'price': 1.0, 'unit': 'image'},
        ]),
      );

      expect(estimate.isKnown, isFalse);
      expect(estimate.estimatedUsd, isNull);
    });
  });

  group('R4 — фактический usage', () {
    test('T2-UNIT-COST-TOKENS-ONLY: отсутствие суммы не становится нулём', () {
      final cost = MessageCost.fromUsage(<String, dynamic>{
        'prompt_tokens': 42,
        'completion_tokens': 10,
      });

      expect(cost, isNotNull);
      expect(cost!.promptTokens, 42);
      expect(cost.completionTokens, 10);
      expect(cost.cost, isNull);
    });

    test('T2-UNIT-COST-UNSCOPED-ALIAS: cost без провайдера не означает USD',
        () {
      final cost = MessageCost.fromUsage(<String, dynamic>{'cost': 1.875});

      expect(cost, isNotNull);
      expect(cost!.currency.trim().toUpperCase(), isNot('USD'));
    });

    test('T2-UNIT-COST-PRECISION: дробная рублёвая сумма не округляется до копеек',
        () {
      const cost = MessageCost(cost: 1.875, currency: 'RUB');

      expect(cost.formatted, '1,875 ₽');
    });
  });
}
