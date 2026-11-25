// Copyright (c) 2026 Minkail. All rights reserved.

import '../providers/heuristic_rules.dart';
import 'model_info.dart';

/// Оценка стоимости одного запроса к модели.
///
/// [estimatedUsd] — предварительная цена в единицах каталога (null — оценить
/// не удалось); [unitLabel] — за что насчитана цена ('за изображение',
/// 'за секунду видео', 'за запрос'); [formatted] — готовая строка для UI.
class CostEstimate {
  final double? estimatedUsd;
  final String unitLabel;
  final bool isKnown;
  final String formatted;

  /// Валюта суммы [estimatedUsd] ('USD', 'RUB').
  final String currency;

  const CostEstimate({
    required this.estimatedUsd,
    required this.unitLabel,
    required this.isKnown,
    required this.formatted,
    this.currency = 'USD',
  });

  /// Оценка неизвестна: бейдж стоимости не показывается.
  static const CostEstimate unknown = CostEstimate(
    estimatedUsd: null,
    unitLabel: '',
    isKnown: false,
    formatted: '',
    currency: '',
  );
}

/// Один тир сырых цен каталога (например, {price, unit, resolution}).
class _PriceTier {
  final double amount;
  final String currency;
  final String unit;
  final String? resolution;
  final bool? hasVideo;
  final bool isSecond;

  const _PriceTier({
    required this.amount,
    required this.currency,
    required this.unit,
    required this.resolution,
    required this.hasVideo,
    required this.isSecond,
  });
}

/// Оценщик стоимости запроса по идентификатору модели.
///
/// Сначала используются сырые блоки цен из `mediaParams` модели
/// (`model_pricing_raw` / `top_provider_pricing_raw`): тиры с условиями
/// (`resolution`, `has_video`, `unitParam: duration`). Если сырых цен нет —
/// работает прежний fallback по семействам (без выдуманных чисел).
/// Для текстовых моделей — по токенам из [Pricing] каталога.
abstract final class CostEstimator {
  static const String _usd = r'$';

  static const double _fluxSchnellImage = 0.003;
  static const double _fluxDevImage = 0.025;

  /// flux-pro и dall-e-3 — одна ценовая категория.
  static const double _proImage = 0.04;

  static const double _wanVideoSecond = 0.04;
  static const double _klingVideoSecond = 0.07;
  static const double _soraVideoSecond = 0.10;

  /// Оценка стоимости запроса.
  ///
  /// [mediaParams] — карта `mediaParams` каталога (содержит
  /// `model_pricing_raw`/`top_provider_pricing_raw`, `resolutions`,
  /// `duration_default` и т.п.). [resolution] / [durationSeconds] /
  /// [hasVideo] — фактический выбор пользователя (необязательно).
  /// Если [mediaParams] не передан, а у [pricing] есть сырые цены — они
  /// тоже используются; иначе работают прежние fallback-цены.
  static CostEstimate estimate({
    required String modelId,
    String prompt = '',
    Pricing? pricing,
    Map<String, dynamic>? mediaParams,
    String? resolution,
    int? durationSeconds,
    bool? hasVideo,
  }) {
    final raw = mediaParams ?? _mediaParamsFromPricing(pricing);
    if (raw != null) {
      final fromRaw = _fromRawPrices(
        modelId: modelId,
        mediaParams: raw,
        resolution: resolution,
        durationSeconds: durationSeconds,
        hasVideo: hasVideo,
      );
      if (fromRaw != null) return fromRaw;
    }

    final id = HeuristicRules.normalize(modelId);
    if (id.isEmpty) return CostEstimate.unknown;

    final image = _imageEstimate(id);
    if (image != null) return image;

    final video = _videoEstimate(id);
    if (video != null) return video;

    return _textEstimate(prompt, pricing);
  }

  // ────────────────────────────────────────────────────────────────────────
  // Сырые цены каталога.
  // ────────────────────────────────────────────────────────────────────────

  static CostEstimate? _fromRawPrices({
    required String modelId,
    required Map<String, dynamic> mediaParams,
    String? resolution,
    int? durationSeconds,
    bool? hasVideo,
  }) {
    final tiers = <_PriceTier>[];
    _collectTiers(mediaParams['model_pricing_raw'], tiers);
    _collectTiers(mediaParams['top_provider_pricing_raw'], tiers);
    if (tiers.isEmpty) return null;

    final isVideo = hasVideo ?? _modelIsVideo(modelId);
    final res = _resolveResolution(resolution, mediaParams, modelId);
    final dur = _resolveDuration(durationSeconds, mediaParams) ?? 1;

    final preferences = <bool?>[
      if (hasVideo != null) hasVideo,
      if (hasVideo == null) false,
      if (hasVideo == null) null,
      if (hasVideo == null) true,
    ];

    _PriceTier? chosen;
    final seen = <bool?>{};
    for (final p in preferences) {
      if (!seen.add(p)) continue;
      chosen = _pickTier(tiers, res, p);
      if (chosen != null) break;
    }
    if (chosen == null) return null;

    var amount = chosen.amount;
    if (chosen.isSecond) amount *= dur;

    return _knownCurrency(
      amount,
      chosen.currency,
      _unitLabel(chosen.unit, isVideo),
    );
  }

  static void _collectTiers(dynamic node, List<_PriceTier> out) {
    if (node == null) return;
    if (node is List) {
      for (final item in node) {
        _collectTiers(item, out);
      }
      return;
    }
    if (node is! Map) return;

    final m = <String, dynamic>{};
    for (final e in node.entries) {
      if (e.key != null) m[e.key.toString()] = e.value;
    }

    // Явный тир: есть price/amount/cost.
    final priceField = m['price'];
    final nestedPrice =
        priceField is Map ? _asDouble(priceField['amount'] ?? priceField['value']) : null;
    final amount = _asDouble(priceField) ??
        _asDouble(m['amount']) ??
        _asDouble(m['cost']) ??
        nestedPrice;

    if (amount != null) {
      final conditions = _asMap(m['conditions']) ?? _asMap(m['when']) ?? m;
      final currency = _asString(m['currency']) ??
          (priceField is Map ? _asString(priceField['currency']) : null) ??
          'USD';
      final unit = _asString(m['unit']) ??
          _asString(m['unit_type']) ??
          _asString(conditions['unit']) ??
          _asString(priceField is Map ? priceField['unit'] : null) ??
          '';
      final unitParam = _asString(m['unitParam']) ??
          _asString(m['unit_param']) ??
          _asString(conditions['unitParam']) ??
          _asString(conditions['unit_param']) ??
          '';
      final resolution = _asString(conditions['resolution']) ??
          _asString(conditions['image_resolution']) ??
          _asString(m['resolution']) ??
          _asString(m['image_resolution']);
      final hasVideo =
          _asBool(conditions['has_video']) ?? _asBool(m['has_video']);
      final isSecond = unit.toLowerCase() == 'second' ||
          unit.toLowerCase() == 'seconds' ||
          unit.toLowerCase() == 'per_second' ||
          unitParam.toLowerCase() == 'duration' ||
          unitParam.toLowerCase() == 'duration_seconds';

      out.add(_PriceTier(
        amount: amount,
        currency: currency,
        unit: unit,
        resolution: resolution,
        hasVideo: hasVideo,
        isSecond: isSecond,
      ));
      return;
    }

    // Плоская карта unit→price (например, {'image': '1.875', 'currency': 'RUB'}).
    // Цены текстовых моделей за токены (prompt/completion/input/output/
    // cache_* и т.п.) сюда не должны попадать как тир «за запрос».
    if (m.containsKey('currency')) {
      final currency = _asString(m['currency']) ?? 'USD';
      var added = false;
      for (final e in m.entries) {
        final key = e.key.toString().toLowerCase();
        if (key == 'currency' || _isTokenPriceKey(key)) continue;
        final v = _asDouble(e.value);
        if (v == null) continue;
        final isSecond = key == 'second' ||
            key == 'seconds' ||
            key == 'per_second' ||
            key.endsWith('_second') ||
            key.endsWith('_per_second');
        final isImage = key == 'image' ||
            key == 'images' ||
            key == 'per_image' ||
            key.endsWith('_image');
        out.add(_PriceTier(
          amount: v,
          currency: currency,
          unit: isImage ? 'image' : (isSecond ? 'second' : 'request'),
          resolution: null,
          hasVideo: null,
          isSecond: isSecond,
        ));
        added = true;
      }
      if (added) return;
    }

    // Рекурсивно обходим вложенные Map/List.
    for (final e in m.entries) {
      if (e.value is Map || e.value is List) {
        _collectTiers(e.value, out);
      }
    }
  }

  /// Ключ плоской карты цен относится к токенной тарификации текстовой
  /// модели, а не к цене за изображение/секунду/запрос.
  static bool _isTokenPriceKey(String key) {
    final k = key.trim().toLowerCase();
    if (k.isEmpty) return false;
    final compact = k.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (compact.isEmpty) return false;

    const exact = <String>{
      'prompt',
      'completion',
      'input',
      'output',
      'cacheread',
      'cachewrite',
      'cachecreation',
      'cached',
      'inputtokens',
      'outputtokens',
      'prompttokens',
      'completiontokens',
      'cachedtokens',
      'cachecreationinputtokens',
      'cachereadinputtokens',
      'reasoning',
      'reasoningtokens',
      'audiotokens',
      'imagetokens',
      'texttokens',
    };
    if (exact.contains(compact)) return true;
    if (compact.contains('permillion') ||
        compact.contains('permtok') ||
        compact.contains('pertoken') ||
        compact.contains('token')) {
      return true;
    }
    return compact.startsWith('prompt') ||
        compact.startsWith('completion') ||
        compact.startsWith('input') ||
        compact.startsWith('output') ||
        compact.startsWith('cache');
  }

  static _PriceTier? _pickTier(
    List<_PriceTier> tiers,
    String? res,
    bool? hv,
  ) {
    _PriceTier? exact;
    _PriceTier? noRes;
    for (final t in tiers) {
      if (hv != null && t.hasVideo != null && t.hasVideo != hv) continue;
      if (res != null && t.resolution != null) {
        if (t.resolution!.toLowerCase() != res.toLowerCase()) continue;
        exact ??= t;
        continue;
      }
      if (t.resolution == null) noRes ??= t;
    }
    return exact ?? noRes;
  }

  static String? _resolveResolution(
    String? explicit,
    Map<String, dynamic> mediaParams,
    String modelId,
  ) {
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    final def = mediaParams['resolution_default'];
    if (def is String && def.trim().isNotEmpty) return def.trim();
    final fromModel = _resolutionFromModelId(modelId);
    if (fromModel != null) return fromModel;
    final list = mediaParams['resolutions'];
    if (list is List && list.isNotEmpty) {
      final first = list.first;
      if (first is String && first.trim().isNotEmpty) return first.trim();
    }
    return null;
  }

  static String? _resolutionFromModelId(String modelId) {
    final m = RegExp(r'(\d{3,4}[pP]|\d+[kK])', caseSensitive: false)
        .firstMatch(modelId);
    return m?.group(1);
  }

  static int? _resolveDuration(
    int? explicit,
    Map<String, dynamic> mediaParams,
  ) {
    if (explicit != null) return explicit;
    final def = mediaParams['duration_default'];
    if (def is int) return def;
    if (def is num) return def.round();
    if (def is String) {
      final v = int.tryParse(def);
      if (v != null) return v;
    }
    final durations = mediaParams['durations'];
    if (durations is List && durations.isNotEmpty) {
      final first = durations.first;
      if (first is int) return first;
      if (first is num) return first.round();
      if (first is String) return int.tryParse(first);
    }
    final min = mediaParams['duration_min'];
    if (min is int) return min;
    if (min is num) return min.round();
    return null;
  }

  static bool _modelIsVideo(String modelId) {
    try {
      return HeuristicRules.inferRoute(modelId) ==
          GenerationRoute.asyncJob;
    } catch (_) {
      return false;
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // Fallback по семействам (задачи 1-3 / v7-v9 не затронуты).
  // ────────────────────────────────────────────────────────────────────────

  static CostEstimate? _imageEstimate(String id) {
    if (HeuristicRules.inferRoute(id) != GenerationRoute.imageGeneration) {
      return null;
    }
    final double price;
    if (id.contains('flux-schnell')) {
      price = _fluxSchnellImage;
    } else if (id.contains('flux-dev')) {
      price = _fluxDevImage;
    } else if (id.contains('flux-pro') ||
        id.contains('dall-e-3') ||
        id.contains('dalle-3')) {
      price = _proImage;
    } else {
      return null;
    }
    return _known(price, 'за изображение');
  }

  static CostEstimate? _videoEstimate(String id) {
    final isVideo = id.contains('wan') ||
        id.contains('kling') ||
        id.contains('sora') ||
        id.contains('veo') ||
        id.contains('video');
    if (!isVideo) return null;
    final double price;
    if (id.contains('kling')) {
      price = _klingVideoSecond;
    } else if (id.contains('sora')) {
      price = _soraVideoSecond;
    } else if (id.contains('wan')) {
      price = _wanVideoSecond;
    } else {
      return null;
    }
    return _known(price, 'за секунду видео');
  }

  static CostEstimate _textEstimate(String prompt, Pricing? pricing) {
    final pr = pricing;
    if (pr == null || !pr.hasAny) return CostEstimate.unknown;
    final text = prompt.trim();
    var tokens = (text.length / 4).ceil();
    if (tokens < 1) tokens = 1;
    final inPrice = pr.inputPerMillion ?? 0.0;
    final outPrice = pr.outputPerMillion ?? inPrice;
    final usd = (tokens * (inPrice + outPrice)) / 1000000;
    if (usd <= 0) return CostEstimate.unknown;
    final isRub = pr.currency.trim().toUpperCase() == 'RUB';
    final symbol = isRub ? '₽' : _usd;
    return CostEstimate(
      estimatedUsd: usd,
      unitLabel: 'за запрос',
      isKnown: true,
      formatted: '≈ ${_fmtMoney(usd, symbol)} за запрос',
      currency: isRub ? 'RUB' : 'USD',
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // Форматирование.
  // ────────────────────────────────────────────────────────────────────────

  static CostEstimate _known(double price, String unitLabel) {
    return _knownCurrency(price, 'USD', unitLabel);
  }

  static CostEstimate _knownCurrency(
    double amount,
    String currency,
    String unitLabel,
  ) {
    final normalized = currency.trim().toUpperCase();
    final c = normalized.isEmpty ? 'USD' : normalized;
    return CostEstimate(
      estimatedUsd: amount,
      unitLabel: unitLabel,
      isKnown: true,
      formatted: '≈ ${_formatMoney(amount, c)} $unitLabel',
      currency: c,
    );
  }

  static String _formatMoney(double v, String currency) {
    if (currency.trim().toUpperCase() == 'RUB') {
      return _fmtMoneyRub(v);
    }
    return _fmtMoney(v, _usd);
  }

  /// Прежний формат USD: '$0.0030', '$0.025', '$1.50'.
  static String _fmtMoney(double v, String symbol) {
    if (v < 0.01) return '$symbol${v.toStringAsFixed(4)}';
    if (v < 1) return '$symbol${v.toStringAsFixed(3)}';
    return '$symbol${v.toStringAsFixed(2)}';
  }

  /// Рублёвый формат: '1,875 ₽', '2,565 ₽' (3 знака после запятой без
  /// лишних нулей, десятичный разделитель — запятая, символ в конце).
  static String _fmtMoneyRub(double v) {
    if (v <= 0) return '0 ₽';
    String s;
    if (v >= 0.01) {
      s = v.toStringAsFixed(3);
    } else {
      s = v.toStringAsFixed(4);
    }
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return '${s.replaceAll('.', ',')} ₽';
  }

  static String _unitLabel(String unit, bool isVideo) {
    final u = unit.toLowerCase().trim();
    if (u == 'second' || u == 'seconds' || u == 'per_second') {
      return 'за секунду видео';
    }
    if (u == 'image' || u == 'images' || u == 'per_image') {
      return 'за изображение';
    }
    if (u == 'request' || u == 'per_request') return 'за запрос';
    if (u.isEmpty) return isVideo ? 'за секунду видео' : 'за запрос';
    return isVideo ? 'за секунду видео' : 'за запрос';
  }

  // ────────────────────────────────────────────────────────────────────────
  // Утилиты.
  // ────────────────────────────────────────────────────────────────────────

  static double? _asDouble(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
    return null;
  }

  static String? _asString(Object? v) {
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return null;
  }

  static bool? _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s == 'true' || s == '1' || s == 'yes') return true;
      if (s == 'false' || s == '0' || s == 'no') return false;
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is! Map) return null;
    return <String, dynamic>{
      for (final e in v.entries)
        if (e.key != null) e.key.toString(): e.value,
    };
  }

  /// Пытается достать сырые цены из [Pricing] (если они там оказались).
  /// Используется динамический доступ, чтобы не завязываться на поля
  /// `Pricing`; при отсутствии — возвращает null.
  static Map<String, dynamic>? _mediaParamsFromPricing(Pricing? pricing) {
    if (pricing == null) return null;
    try {
      final dynamic p = pricing;
      final dynamic raw = p.raw;
      if (raw is Map) return _asMap(raw);
    } catch (_) {}
    try {
      final dynamic p = pricing;
      final dynamic mp = p.mediaParams;
      if (mp is Map) return _asMap(mp);
    } catch (_) {}
    return null;
  }
}
