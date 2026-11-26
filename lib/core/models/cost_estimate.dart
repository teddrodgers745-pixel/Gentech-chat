// Copyright (c) 2026 Minkail. All rights reserved.

// ignore: unused_import
import '../providers/heuristic_rules.dart';
import 'model_info.dart';

/// Предварительная оценка стоимости одного запроса.
///
/// [estimatedUsd] сохраняет прежнее имя для совместимости. Сумма выражена
/// в [currency], а не обязательно в долларах.
class CostEstimate {
  final double? estimatedUsd;
  final String unitLabel;
  final bool isKnown;
  final String formatted;
  final String currency;

  const CostEstimate({
    required this.estimatedUsd,
    required this.unitLabel,
    required this.isKnown,
    required this.formatted,
    this.currency = 'USD',
  });

  static const CostEstimate unknown = CostEstimate(
    estimatedUsd: null,
    unitLabel: '',
    isKnown: false,
    formatted: '',
    currency: '',
  );
}

class _PriceTier {
  final double? amount;
  final String? currency;
  final String? unit;
  final String? resolution;
  final bool? hasVideo;
  final bool valid;

  const _PriceTier({
    required this.amount,
    required this.currency,
    required this.unit,
    required this.resolution,
    required this.hasVideo,
    required this.valid,
  });
}

/// Консервативный оценщик по сырым ценам каталога.
///
/// Условия, которых этот контракт не умеет проверить, делают оценку
/// недоступной. При наличии одновременно model и top-provider pricing
/// источник не выбирается автоматически: вызывающий код пока не передаёт
/// доказательство выбранного провайдера.
abstract final class CostEstimator {
  static CostEstimate estimate({
    required String modelId,
    String prompt = '',
    Pricing? pricing,
    Map<String, dynamic>? mediaParams,
    String? resolution,
    int? durationSeconds,
    bool? hasVideo,
  }) {
    final media = mediaParams;
    if (media == null) return CostEstimate.unknown;

    final modelPrices = media['model_pricing_raw'];
    final providerPrices = media['top_provider_pricing_raw'];
    if (modelPrices != null && providerPrices != null) {
      return CostEstimate.unknown;
    }

    final raw = modelPrices ?? providerPrices;
    if (raw == null) return CostEstimate.unknown;

    final tiers = <_PriceTier>[];
    if (!_collectTiers(raw, tiers) || tiers.isEmpty) {
      return CostEstimate.unknown;
    }

    final selectedResolution = _nonEmptyString(resolution);
    final applicable = <_PriceTier>[];

    for (final tier in tiers) {
      final tierResolution = tier.resolution;
      if (tierResolution != null && selectedResolution != null) {
        if (tierResolution.toLowerCase() !=
            selectedResolution.toLowerCase()) {
          continue;
        }
      }
      if (tier.hasVideo != null && hasVideo != null) {
        if (tier.hasVideo != hasVideo) continue;
      }

      // Неизвестное условие может менять выбранный тариф.
      if (!tier.valid ||
          (tierResolution != null && selectedResolution == null) ||
          (tier.hasVideo != null && hasVideo == null)) {
        return CostEstimate.unknown;
      }
      applicable.add(tier);
    }

    // Даже одинаковые значения не доказывают, что это один тариф.
    if (applicable.length != 1) return CostEstimate.unknown;

    final tier = applicable.single;
    final amount = tier.amount;
    final currency = tier.currency;
    final unit = tier.unit;
    if (amount == null ||
        !amount.isFinite ||
        amount < 0 ||
        currency == null ||
        unit == null) {
      return CostEstimate.unknown;
    }

    final double total;
    final String label;
    switch (unit) {
      case 'second':
        if (durationSeconds == null || durationSeconds <= 0) {
          return CostEstimate.unknown;
        }
        total = amount * durationSeconds;
        label = 'за запрос';
      case 'image':
        total = amount;
        label = 'за изображение';
      case 'request':
        total = amount;
        label = 'за запрос';
      default:
        return CostEstimate.unknown;
    }

    if (!total.isFinite) return CostEstimate.unknown;
    return CostEstimate(
      estimatedUsd: total,
      unitLabel: label,
      isKnown: true,
      formatted: '≈ ${_formatMoney(total, currency)} $label',
      currency: currency,
    );
  }

  /// Возвращает false, если структура цен не распознана полностью.
  static bool _collectTiers(Object? node, List<_PriceTier> out) {
    if (node is List) {
      if (node.isEmpty) return false;
      for (final item in node) {
        if (!_collectTiers(item, out)) return false;
      }
      return true;
    }

    final map = _asMap(node);
    if (map == null || map.isEmpty) return false;

    final priceKeys = <String>[
      for (final key in const <String>['price', 'amount', 'cost'])
        if (map.containsKey(key)) key,
    ];
    if (priceKeys.isNotEmpty) {
      if (priceKeys.length != 1) return false;
      out.add(_parseTier(map, priceKeys.single));
      return true;
    }

    // Поддерживаем только однозначные плоские карты unit -> price.
    const allowed = <String>{
      'currency',
      'image',
      'images',
      'per_image',
      'second',
      'seconds',
      'per_second',
      'request',
      'per_request',
    };
    if (map.keys.any((key) => !allowed.contains(key))) return false;

    final currency = _currency(map['currency']);
    var found = false;
    for (final entry in map.entries) {
      if (entry.key == 'currency') continue;
      found = true;
      out.add(_PriceTier(
        amount: _number(entry.value),
        currency: currency,
        unit: _unit(entry.key),
        resolution: null,
        hasVideo: null,
        valid: currency != null,
      ));
    }
    return found;
  }

  static _PriceTier _parseTier(Map<String, dynamic> map, String priceKey) {
    const allowed = <String>{
      'price',
      'amount',
      'cost',
      'currency',
      'unit',
      'unit_type',
      'unitParam',
      'unit_param',
      'conditions',
      'when',
      'resolution',
      'image_resolution',
      'has_video',
    };
    var valid = map.keys.every(allowed.contains);
    if (map.containsKey('conditions') && map.containsKey('when')) {
      valid = false;
    }

    final rawConditions = map['conditions'] ?? map['when'];
    final conditions = rawConditions == null
        ? <String, dynamic>{}
        : _asMap(rawConditions);
    if (conditions == null) valid = false;

    const conditionKeys = <String>{
      'resolution',
      'image_resolution',
      'has_video',
    };
    if (conditions != null &&
        conditions.keys.any((key) => !conditionKeys.contains(key))) {
      valid = false;
    }

    final nested = conditions ?? <String, dynamic>{};
    final resolutionValues = <String>[];
    for (final value in <Object?>[
      map['resolution'],
      map['image_resolution'],
      nested['resolution'],
      nested['image_resolution'],
    ]) {
      if (value == null) continue;
      final parsed = _nonEmptyString(value);
      if (parsed == null) {
        valid = false;
      } else {
        resolutionValues.add(parsed);
      }
    }
    if (resolutionValues.isNotEmpty &&
        resolutionValues.any(
          (value) =>
              value.toLowerCase() != resolutionValues.first.toLowerCase(),
        )) {
      valid = false;
    }

    final videoValues = <bool>[];
    for (final value in <Object?>[map['has_video'], nested['has_video']]) {
      if (value == null) continue;
      final parsed = _boolean(value);
      if (parsed == null) {
        valid = false;
      } else {
        videoValues.add(parsed);
      }
    }
    if (videoValues.isNotEmpty &&
        videoValues.any((value) => value != videoValues.first)) {
      valid = false;
    }

    final price = map[priceKey];
    final priceMap = price is Map ? _asMap(price) : null;
    if (price is Map && priceMap == null) valid = false;
    if (priceMap != null) {
      const allowedPriceKeys = <String>{'amount', 'value', 'currency', 'unit'};
      if (priceMap.keys.any((key) => !allowedPriceKeys.contains(key)) ||
          (priceMap.containsKey('amount') && priceMap.containsKey('value'))) {
        valid = false;
      }
    }

    final amount = priceMap == null
        ? _number(price)
        : _number(priceMap['amount'] ?? priceMap['value']);

    final currencies = <String>[];
    for (final value in <Object?>[map['currency'], priceMap?['currency']]) {
      if (value == null) continue;
      final parsed = _currency(value);
      if (parsed == null) {
        valid = false;
      } else {
        currencies.add(parsed);
      }
    }
    if (currencies.isEmpty ||
        currencies.any((value) => value != currencies.first)) {
      valid = false;
    }

    final units = <String>[];
    for (final value in <Object?>[
      map['unit'],
      map['unit_type'],
      priceMap?['unit'],
    ]) {
      if (value == null) continue;
      final parsed = _unit(value);
      if (parsed == null) {
        valid = false;
      } else {
        units.add(parsed);
      }
    }

    final unitParams = <String>[];
    for (final value in <Object?>[map['unitParam'], map['unit_param']]) {
      if (value == null) continue;
      final parsed = _nonEmptyString(value)?.toLowerCase();
      if (parsed == 'duration' || parsed == 'duration_seconds') {
        unitParams.add('second');
      } else {
        valid = false;
      }
    }
    units.addAll(unitParams);
    if (units.isEmpty || units.any((value) => value != units.first)) {
      valid = false;
    }

    return _PriceTier(
      amount: amount,
      currency: currencies.isEmpty ? null : currencies.first,
      unit: units.isEmpty ? null : units.first,
      resolution: resolutionValues.isEmpty ? null : resolutionValues.first,
      hasVideo: videoValues.isEmpty ? null : videoValues.first,
      valid: valid,
    );
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is! Map) return null;
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) return null;
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final result = value.trim();
    return result.isEmpty ? null : result;
  }

  static String? _currency(Object? value) {
    final result = _nonEmptyString(value)?.toUpperCase();
    if (result == null || !RegExp(r'^[A-Z]{3}$').hasMatch(result)) {
      return null;
    }
    return result;
  }

  static String? _unit(Object? value) {
    final raw = _nonEmptyString(value)?.toLowerCase();
    switch (raw) {
      case 'image':
      case 'images':
      case 'per_image':
        return 'image';
      case 'second':
      case 'seconds':
      case 'per_second':
        return 'second';
      case 'request':
      case 'per_request':
        return 'request';
      default:
        return null;
    }
  }

  static double? _number(Object? value) {
    final double? number;
    if (value is num) {
      number = value.toDouble();
    } else if (value is String) {
      number = double.tryParse(value.trim().replaceAll(',', '.'));
    } else {
      number = null;
    }
    if (number == null || !number.isFinite || number < 0) return null;
    return number;
  }

  static bool? _boolean(Object? value) {
    if (value is bool) return value;
    if (value is num) {
      if (value == 0) return false;
      if (value == 1) return true;
      return null;
    }
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case '1':
          return true;
        case 'false':
        case '0':
          return false;
      }
    }
    return null;
  }

  static String _formatMoney(double value, String currency) {
    String text;
    if ((value != 0 && value.abs() < 0.00000001) || value.abs() >= 1e21) {
      text = value.toString();
    } else {
      text = value.toStringAsFixed(8);
      text = text.replaceFirst(RegExp(r'0+$'), '');
      text = text.replaceFirst(RegExp(r'\.$'), '');
    }
    text = text.replaceAll('.', ',');
    switch (currency) {
      case 'RUB':
        return '$text ₽';
      case 'USD':
        return '\$$text';
      default:
        return '$text $currency';
    }
  }
}
