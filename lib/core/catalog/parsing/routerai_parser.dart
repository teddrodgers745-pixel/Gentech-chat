// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import '../catalog_entry.dart';
import 'reasoning_levels.dart';

/// Терпимый парсер каталога моделей RouterAI (GET {baseUrl}/models).
///
/// Разбирает известные поля формата RouterAI:
///  - type, context_length, max_completion_tokens;
///  - reasoning (словарь supported_efforts/default_effort/mandatory
///    либо флаг true), плоские списки уровней (supported_efforts,
///    supported_reasoning_efforts, reasoning_efforts) и
///    capabilities.reasoning_effort.values провайдеров;
///  - supported_parameters (в том числе 'reasoning');
///  - плоские списки на верхнем уровне записи:
///    supported_aspect_ratios, supported_image_sizes/supported_resolutions,
///    supported_durations (строки вида '4' приводятся к int),
///    supported_qualities;
///  - цены за миллион токенов (prompt_per_million,
///    completion_per_million ...) либо объект pricing.
///
/// Куда кладутся данные:
///  - прямые поля CatalogEntry: aspectRatios (supported_aspect_ratios /
///    parameters.aspect_ratio.values), resolutions (supported_image_sizes /
///    supported_resolutions / parameters.resolution.values), durations
///    (supported_durations / parameters.duration.values), qualities
///    (supported_qualities / parameters.quality.values);
///  - mediaParams (Stage 2c-1; ТОЛЬКО ненулевые значения — если поле
///    отсутствует либо null, ключ в карту НЕ добавляется):
///    'pricing_variants' (Map<String, double> из image_pricing),
///    'output_formats' (List<String> из supported_output_formats),
///    'backgrounds' (List<String> из supported_backgrounds),
///    'max_image_count' (int из max_image_count),
///    'max_image_references' (int из max_image_references),
///    'supports_image_references' (bool из supported_image_references),
///    'image_seed' (bool из image_seed),
///    'supports_negative_prompt' (bool из supports_negative_prompt).
///
/// Уровни размышлений извлекаются из всех доступных источников; если
/// провайдер их не перечислил, парсер возвращает unknown=true, чтобы не
/// подставлять всем моделям одинаковый набор ['off', 'high'].
///
/// Битые значения приводятся к null/пустым спискам, разбор одной записи
/// никогда не роняет остальные. Запись без идентификатора отбрасывается.
abstract final class RouterAiParser {
  /// Типы моделей, известные каталогу.
  static const Set<String> knownTypes = <String>{
    'chat', 'image', 'video', 'tts', 'stt', 'embedding', 'music',
    'classification',
  };

  /// Уровни размышлений по умолчанию — применяются ТОЛЬКО когда провайдер
  /// явно заявил поддержку reasoning, но не перечислил уровни.
  static const List<String> defaultReasoningLevels = <String>[
    'off', 'low', 'medium', 'high',
  ];

  /// Базовые уровни, когда reasoning заявлен только в supported_parameters.
  static const List<String> supportedParamsReasoningLevels = <String>[
    'off', 'low', 'medium', 'high',
  ];

  /// Разбирает полный ответ каталога. Записи без идентификатора
  /// и битые записи пропускаются.
  static List<CatalogEntry> parseCatalogResponse(
    String body,
    String connectionId,
  ) {
    final out = <CatalogEntry>[];
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return out;
    }
    if (decoded is! Map) return out;
    final data = decoded['data'] ?? decoded['models'];
    if (data is! List) return out;
    for (final e in data) {
      if (e is! Map) continue;
      try {
        final entry = parseEntry(
          Map<String, dynamic>.from(e),
          connectionId,
        );
        if (entry != null) out.add(entry);
      } catch (_) {
        // Одна битая запись не роняет разбор остальных.
      }
    }
    return out;
  }

  /// Разбор одной записи /models; null — запись без идентификатора.
  static CatalogEntry? parseEntry(
    Map<String, dynamic> m,
    String connectionId,
  ) {
    final id = (asStr(m['id']) ?? asStr(m['name']) ?? asStr(m['model']) ?? '')
        .trim();
    if (id.isEmpty) return null;
    final name = (asStr(m['name']) ?? '').trim();
    final topProvider = asMap(m['top_provider']);

    final typeRaw = (asStr(m['type']) ?? '').toLowerCase();
    final type = knownTypes.contains(typeRaw) ? typeRaw : '';

    final contextLength = asInt(pick(m, const <String>[
      'context_length', 'contextLength', 'context_window',
    ]));
    final maxOut = asInt(pick(m, const <String>[
      'max_completion_tokens', 'maxCompletionTokens', 'max_output_tokens',
    ]));
    final supportedParams = asStrList(
      m['supported_parameters'] ?? topProvider?['supported_parameters'],
    );

    final (reasoning, reasoningUnknown) =
        parseReasoning(m, supportedParams);

    final media = parseMediaParams(m);

    bool? supportsTools;
    if (supportedParams.isNotEmpty) {
      supportsTools = supportedParams.contains('tools') ||
          supportedParams.contains('function_calling');
    }

    final (priceIn, priceOut, currency) = parsePrice(m);

    // Цены по вариантам изображения (image_pricing) — опциональное поле
    // mediaParams: если поля нет, карта пуста и поле не добавляется.
    final pricingVariants = parseImagePricing(m);
    // Stage 2c-1: дополнительные медиа-поля API. Значение null (или
    // отсутствующее поле) — ключ в mediaParams не добавляется.
    final outputFormats = asStrList(m['supported_output_formats']);
    final backgrounds = asStrList(m['supported_backgrounds']);
    final maxImageCount = asInt(m['max_image_count']);
    final maxImageRefs = asInt(m['max_image_references']);
    final imageRefs = m['supported_image_references'];
    final imageSeed = m['image_seed'];
    final negativePrompt = m['supports_negative_prompt'];
    final mediaParams = <String, dynamic>{
      if (pricingVariants.isNotEmpty) 'pricing_variants': pricingVariants,
      if (outputFormats.isNotEmpty) 'output_formats': outputFormats,
      if (backgrounds.isNotEmpty) 'backgrounds': backgrounds,
      if (maxImageCount != null) 'max_image_count': maxImageCount,
      if (maxImageRefs != null) 'max_image_references': maxImageRefs,
      if (imageRefs is bool) 'supports_image_references': imageRefs,
      if (imageSeed is bool) 'image_seed': imageSeed,
      if (negativePrompt is bool) 'supports_negative_prompt': negativePrompt,
    };

    return CatalogEntry(
      connectionId: connectionId,
      id: id,
      name: name,
      type: type,
      contextLength: contextLength,
      maxCompletionTokens: maxOut,
      reasoning: reasoning,
      reasoningUnknown: reasoningUnknown,
      supportedParams: supportedParams,
      supportsTools: supportsTools,
      aspectRatios: media.aspectRatios,
      resolutions: media.resolutions,
      durations: media.durations,
      qualities: media.qualities,
      mediaParams: mediaParams,
      priceIn: priceIn,
      priceOut: priceOut,
      currency: currency,
      capabilitiesSource: CatalogSources.connection,
      priceSource: (priceIn != null || priceOut != null)
          ? CatalogSources.connection
          : null,
    );
  }

  /// Reasoning: m['reasoning'] / top_provider['reasoning'] (словарь либо
  /// true), плоские списки уровней и capabilities провайдеров.
  /// Возвращает (reasoning, unknown); unknown=true — уровни у провайдера
  /// неизвестны (одинаковый набор всем моделям не подставляем).
  static (CatalogReasoning?, bool) parseReasoning(
    Map<String, dynamic> m,
    List<String> supportedParams,
  ) {
    final topProvider = asMap(m['top_provider']);
    final tpRaw = topProvider?['reasoning'];
    final modelRaw = m['reasoning'];
    final paramsMap =
        asMap(m['parameters']) ?? asMap(topProvider?['parameters']);
    final paramReasoning =
        paramsMap == null ? null : asMap(paramsMap['reasoning']);

    final tpReasoning = asMap(tpRaw);
    final modelReasoning = asMap(modelRaw);
    final marker = modelRaw == true || tpRaw == true;

    final efforts = <String>[];
    void addAll(List<String> values) {
      for (final v in values) {
        final t = v.trim();
        if (t.isEmpty) continue;
        if (!efforts.contains(t)) efforts.add(t);
      }
    }

    for (final c in <Map<String, dynamic>?>[
      modelReasoning,
      tpReasoning,
      paramReasoning,
    ]) {
      if (c == null) continue;
      addAll(effortValues(c));
    }
    addAll(capabilityEfforts(topProvider));
    addAll(providerEfforts(m));
    addAll(asStrList(
      m['supported_reasoning_efforts'] ??
          m['supported_efforts'] ??
          m['reasoning_efforts'],
    ));

    final def = asStr(
          modelReasoning?['default_effort'] ??
              modelReasoning?['defaultEffort'] ??
              tpReasoning?['default_effort'] ??
              tpReasoning?['defaultEffort'] ??
              paramReasoning?['default_effort'] ??
              paramReasoning?['defaultEffort'] ??
              m['default_reasoning_effort'],
        ) ??
        '';
    final mandatory = modelReasoning?['mandatory'] == true ||
        modelReasoning?['required'] == true ||
        tpReasoning?['mandatory'] == true ||
        tpReasoning?['required'] == true ||
        paramReasoning?['mandatory'] == true ||
        paramReasoning?['required'] == true;

    if (efforts.isNotEmpty) {
      return (
        CatalogReasoning(
          levels: normalizeReasoningLevels(efforts, mandatory: mandatory),
          defaultEffort: normalizeReasoningEffort(def),
          mandatory: mandatory,
        ),
        false,
      );
    }

    if (def.isNotEmpty) {
      return (
        CatalogReasoning(
          levels: normalizeReasoningLevels(
            <String>[def],
            mandatory: mandatory,
          ),
          defaultEffort: normalizeReasoningEffort(def),
          mandatory: mandatory,
        ),
        false,
      );
    }

    final declared = modelReasoning != null ||
        tpReasoning != null ||
        paramReasoning != null ||
        marker;
    if (declared) {
      // Reasoning заявлен, но уровни не перечислены: данные неизвестны.
      return (null, true);
    }
    if (supportedParams.contains('reasoning') ||
        supportedParams.contains('reasoning_effort')) {
      return (null, true);
    }
    if (supportedParams.isNotEmpty) {
      // supported_parameters есть, reasoning не заявлен: провайдер явно
      // не заявил (не неизвестно).
      return (null, false);
    }
    // Ни reasoning, ни supported_parameters — неизвестно.
    return (null, true);
  }

  /// Уровни из объекта reasoning (supported_efforts / values / levels).
  static List<String> effortValues(Map<String, dynamic> c) => asStrList(
        c['supported_efforts'] ??
            c['supportedEfforts'] ??
            c['values'] ??
            c['efforts'] ??
            c['levels'],
      );

  /// Уровни из capabilities.reasoning_effort.values провайдера.
  static List<String> capabilityEfforts(Map<String, dynamic>? provider) {
    final caps = asMap(provider?['capabilities']);
    if (caps == null) return const <String>[];
    final re = asMap(caps['reasoning_effort']);
    if (re == null) return const <String>[];
    return asStrList(re['values']);
  }

  /// Уровни из всех провайдеров записи (providers[]).
  static List<String> providerEfforts(Map<String, dynamic> m) {
    final out = <String>[];
    final providers = m['providers'];
    if (providers is! List) return out;
    for (final p in providers) {
      if (p is! Map) continue;
      final pm = Map<String, dynamic>.from(p);
      final r = asMap(pm['reasoning']);
      if (r != null) out.addAll(effortValues(r));
      out.addAll(capabilityEfforts(pm));
    }
    return out;
  }

  /// Цены ТОЛЬКО в известных формах. Возвращает (in, out, currency).
  static (double?, double?, String?) parsePrice(Map<String, dynamic> m) {
    // 1) Явные цены за миллион токенов.
    final pricing = asMap(m['pricing']);
    final inM = asDouble(pick(m, const <String>[
      'prompt_per_million', 'input_per_million',
      'prompt_per_1m', 'input_per_1m',
    ])) ??
        (pricing == null
            ? null
            : asDouble(pick(pricing, const <String>[
                'prompt_per_million', 'input_per_million',
                'prompt_per_1m', 'input_per_1m',
              ])));
    final outM = asDouble(pick(m, const <String>[
      'completion_per_million', 'output_per_million',
      'completion_per_1m', 'output_per_1m',
    ])) ??
        (pricing == null
            ? null
            : asDouble(pick(pricing, const <String>[
                'completion_per_million', 'output_per_million',
                'completion_per_1m', 'output_per_1m',
              ])));
    if (inM != null || outM != null) {
      final cur = asStr(pick(m, const <String>['currency'])) ??
          (pricing == null ? null : asStr(pricing['currency']));
      return (inM, outM, cur);
    }
    // 2) Цены за один токен — переводятся в цену за миллион.
    if (pricing != null) {
      final inTok = asDouble(pricing['prompt'] ?? pricing['input']);
      final outTok = asDouble(pricing['completion'] ?? pricing['output']);
      if (inTok != null || outTok != null) {
        double? scale(double? v) =>
            v == null ? null : (v < 0.01 ? v * 1000000 : v);
        return (scale(inTok), scale(outTok),
            asStr(pricing['currency']) ?? 'USD');
      }
    }
    return (null, null, null);
  }

  /// Цены по вариантам изображения из m['image_pricing']:
  /// [{"unit": "image", "variant": "1k", "price": 0.02}] -> {'1k': 0.02}.
  /// Пустая карта — поля нет либо не разобрались.
  static Map<String, double> parseImagePricing(Map<String, dynamic> m) {
    final out = <String, double>{};
    final raw = m['image_pricing'];
    if (raw is! List) return out;
    for (final e in raw) {
      if (e is! Map) continue;
      final price = asDouble(e['price']);
      final variant = asStr(e['variant']) ?? '';
      if (price == null || variant.isEmpty) continue;
      if (!out.containsKey(variant)) out[variant] = price;
    }
    return out;
  }

  /// Медиа-параметры записи формата RouterAI: плоские списки
  /// на верхнем уровне (пропорции, разрешения, длительности, качества).
  static ({
    List<String> aspectRatios,
    List<String> resolutions,
    List<int> durations,
    List<String> qualities,
  }) parseMediaParams(Map<String, dynamic> m) {
    var aspectRatios = const <String>[];
    var resolutions = const <String>[];
    var durations = const <int>[];
    var qualities = const <String>[];
    try {
      // Основной формат RouterAI: плоские списки на верхнем уровне.
      aspectRatios = asStrList(m['supported_aspect_ratios']);
      resolutions = asStrList(
        asStrList(m['supported_image_sizes']).isNotEmpty
            ? m['supported_image_sizes']
            : m['supported_resolutions'],
      );
      durations = asIntList(m['supported_durations']);
      qualities = asStrList(m['supported_qualities']);
      // Дополнительно принимаем блок parameters (как у Polza), если
      // плоские списки не дали данных.
      if (aspectRatios.isEmpty ||
          resolutions.isEmpty ||
          durations.isEmpty ||
          qualities.isEmpty) {
        final topProvider = asMap(m['top_provider']);
        final params =
            asMap(m['parameters']) ?? asMap(topProvider?['parameters']);
        if (params != null) {
          if (aspectRatios.isEmpty) {
            aspectRatios = constraintValues(params['aspect_ratio']);
          }
          if (resolutions.isEmpty) {
            final imageRes = constraintValues(params['image_resolution']);
            final videoRes = constraintValues(params['resolution']);
            resolutions = imageRes.isNotEmpty ? imageRes : videoRes;
          }
          if (durations.isEmpty) {
            durations = durationValues(params['duration']);
          }
          if (qualities.isEmpty) {
            qualities = constraintValues(params['quality']);
          }
        }
      }
    } catch (_) {
      // Битые медиа-поля не роняют разбор записи.
    }
    return (
      aspectRatios: aspectRatios,
      resolutions: resolutions,
      durations: durations,
      qualities: qualities,
    );
  }

  // ---------- терпимые помощники приведения типов ----------

  static Map<String, dynamic>? asMap(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static String? asStr(Object? v) => v is String ? v.trim() : null;

  static double? asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
    return null;
  }

  static int? asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) {
      final clean = v.trim();
      final direct = int.tryParse(clean);
      if (direct != null) return direct;
      final m = RegExp(r'(\d+)').firstMatch(clean);
      if (m != null) return int.tryParse(m.group(1)!);
    }
    return null;
  }

  static List<String> asStrList(Object? v) {
    if (v is! List) return const <String>[];
    return <String>[
      for (final e in v)
        if (e != null) e.toString().trim(),
    ]..removeWhere((s) => s.isEmpty);
  }

  static List<int> asIntList(Object? v) {
    if (v is! List) return const <int>[];
    final out = <int>[];
    for (final e in v) {
      final i = asInt(e);
      if (i != null) out.add(i);
    }
    return out;
  }

  /// Значения ограничения параметра: values / enum / value_labels /
  /// плоский список. Пустой список — данных нет.
  static List<String> constraintValues(Object? raw) {
    final map = asMap(raw);
    if (map != null) {
      final values = asStrList(map['values'] ?? map['enum']);
      if (values.isNotEmpty) return values;
      final labels = asMap(map['value_labels']);
      if (labels != null) {
        final out = <String>[];
        labels.forEach((k, v) {
          final s = (v ?? k).toString().trim();
          if (s.isNotEmpty) out.add(s);
        });
        if (out.isNotEmpty) return out;
      }
      return const <String>[];
    }
    return asStrList(raw);
  }

  /// Длительности: список значений (строки '4' -> int) либо диапазон
  /// min..max с шагом step, если значения не перечислены.
  static List<int> durationValues(Object? raw) {
    final map = asMap(raw);
    if (map == null) return asIntList(raw);
    final values = asIntList(map['values'] ?? map['enum']);
    if (values.isNotEmpty) return values;
    final min = asInt(map['min']);
    final max = asInt(map['max']);
    if (min == null || max == null || max < min) return const <int>[];
    final stepRaw = asInt(map['step']);
    final step = (stepRaw == null || stepRaw <= 0) ? 1 : stepRaw;
    final out = <int>[];
    for (int v = min; v <= max && out.length < 20; v += step) {
      out.add(v);
    }
    return out;
  }

  /// Первое ненулевое значение по списку ключей.
  static Object? pick(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v != null) return v;
    }
    return null;
  }
}
