// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import '../catalog_entry.dart';
import 'reasoning_levels.dart';

/// Терпимый парсер каталога моделей Polza (GET {baseUrl}/models).
///
/// Разбирает известные поля формата Polza:
///  - type, context_length, max_completion_tokens;
///  - reasoning: supported_efforts / default_effort / mandatory — из
///    записи модели (`reasoning`), из `top_provider.reasoning`, из
///    `parameters.reasoning`, а также из `capabilities.reasoning_effort`
///    (поле `values`) top_provider и каждого провайдера из `providers[]`;
///  - supported_parameters (наличие 'reasoning'/'reasoning_effort');
///  - top_provider.pricing — цены за миллион токенов (prompt_per_million,
///    completion_per_million ...);
///  - parameters — медиа-поля: aspect_ratio, image_resolution/resolution,
///    duration (строки вида '4' приводятся к int), quality, images.max.
///
/// Куда кладутся данные:
///  - прямые поля CatalogEntry: aspectRatios (parameters.aspect_ratio.values),
///    resolutions (parameters.image_resolution.values /
///    parameters.resolution.values), durations (parameters.duration.values),
///    qualities (parameters.quality.values), maxReferenceImages
///    (parameters.images.max);
///  - mediaParams (Stage 2c-1; ТОЛЬКО ненулевые значения — если поле
///    отсутствует либо null, ключ в карту НЕ добавляется):
///    'pricing_tiers' (Map<String, double> из top_provider.pricing.tiers),
///    'images_min' (int из parameters.images.min),
///    'images_max' (int из parameters.images.max),
///    'prompt_max_length' (int из parameters.prompt.max_length),
///    'output_formats' (List<String> из parameters.output_format).
///
/// Уровни размышлений НЕ подставляются «всем моделям одинаково»: если
/// провайдер не перечислил уровни, парсер возвращает unknown=true, чтобы
/// резолвер модели использовал собственные источники, а не выдуманный
/// набор ['off', 'high'].
///
/// Битые значения приводятся к null/пустым спискам, разбор одной записи
/// никогда не роняет остальные. Запись без идентификатора отбрасывается.
abstract final class PolzaParser {
  /// Типы моделей, известные каталогу.
  static const Set<String> knownTypes = <String>{
    'chat', 'image', 'video', 'tts', 'stt', 'embedding', 'music',
    'classification',
  };

  /// Уровни размышлений по умолчанию — применяются ТОЛЬКО когда провайдер
  /// явно заявил поддержку reasoning, но не перечислил уровни НИГДЕ
  /// (ни reasoning.supported_efforts, ни capabilities.reasoning_effort).
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
    ])) ?? asInt(pick(topProvider ?? const <String, dynamic>{}, const <String>[
      'context_length', 'contextLength', 'context_window',
    ]));
    final maxOut = asInt(pick(m, const <String>[
      'max_completion_tokens', 'maxCompletionTokens', 'max_output_tokens',
    ])) ?? asInt(pick(topProvider ?? const <String, dynamic>{}, const <String>[
      'max_completion_tokens', 'maxCompletionTokens', 'max_output_tokens',
    ]));
    final supportedParams = asStrList(
      m['supported_parameters'] ?? topProvider?['supported_parameters'],
    );

    final (reasoning, reasoningUnknown) =
        parseReasoning(m, topProvider, supportedParams);

    final media = parseMediaParams(m, topProvider);

    bool? supportsTools;
    if (supportedParams.isNotEmpty) {
      supportsTools = supportedParams.contains('tools') ||
          supportedParams.contains('function_calling');
    }

    final (priceIn, priceOut, currency) = parsePrice(m, topProvider);

    // Цены по разрешению (top_provider.pricing.tiers) — опциональное поле
    // mediaParams: если tiers нет, карта пуста и поле не добавляется.
    final pricingTiers = parsePricingTiers(topProvider);
    // Stage 2c-1: images.min/max и prompt.max_length из
    // top_provider.parameters (фоллбэк — parameters самой записи, как
    // читает parseMediaParams). Значение null — ключ не добавляется.
    final paramsMap =
        asMap(topProvider?['parameters']) ?? asMap(m['parameters']);
    final imagesMap = paramsMap == null ? null : asMap(paramsMap['images']);
    final promptMap = paramsMap == null ? null : asMap(paramsMap['prompt']);
    final imagesMin = imagesMap == null ? null : asInt(imagesMap['min']);
    final imagesMax = imagesMap == null ? null : asInt(imagesMap['max']);
    final promptMaxLength =
        promptMap == null ? null : asInt(promptMap['max_length']);
    final outputFormats = paramsMap == null
        ? const <String>[]
        : constraintValues(paramsMap['output_format']);
    final mediaParams = <String, dynamic>{
      if (pricingTiers.isNotEmpty) 'pricing_tiers': pricingTiers,
      if (imagesMin != null) 'images_min': imagesMin,
      if (imagesMax != null) 'images_max': imagesMax,
      if (promptMaxLength != null) 'prompt_max_length': promptMaxLength,
      if (outputFormats.isNotEmpty) 'output_formats': outputFormats,
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
      maxReferenceImages: media.maxImages,
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

  /// Reasoning: m['reasoning'], m['top_provider']['reasoning'],
  /// m['parameters']['reasoning'], а также уровни из
  /// `capabilities.reasoning_effort.values` (top_provider и providers[]).
  ///
  /// Возвращает (reasoning, unknown):
  ///  - reasoning != null — уровни найдены (supported_efforts / capabilities
  ///    / default_effort);
  ///  - unknown = true — уровни у провайдера неизвестны: подставлять
  ///    одинаковый набор всем моделям нельзя, резолвер разберётся сам;
  ///  - unknown = false, reasoning = null — провайдер явно заявил, что
  ///    reasoning не поддерживается.
  static (CatalogReasoning?, bool) parseReasoning(
    Map<String, dynamic> m,
    Map<String, dynamic>? topProvider,
    List<String> supportedParams,
  ) {
    final tpRaw = topProvider?['reasoning'];
    final modelRaw = m['reasoning'];
    final paramsMap =
        asMap(topProvider?['parameters']) ?? asMap(m['parameters']);
    final paramReasoning =
        paramsMap == null ? null : asMap(paramsMap['reasoning']);

    final tpReasoning = asMap(tpRaw);
    final modelReasoning = asMap(modelRaw);
    final marker = tpRaw == true || modelRaw == true;

    // Уровни собираем из ВСЕХ источников сразу: модель, top_provider,
    // parameters, capabilities провайдера и плоские списки записи.
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

    // Уровней нет, но провайдер назвал уровень по умолчанию — используем его.
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
      // Провайдер заявил reasoning, но уровни не перечислил: данные
      // неизвестны — одинаковый набор уровней всем моделям не подставляем.
      return (null, true);
    }
    if (supportedParams.contains('reasoning') ||
        supportedParams.contains('reasoning_effort')) {
      // Reasoning в supported_parameters есть, конкретных уровней нет.
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
  static (double?, double?, String?) parsePrice(
    Map<String, dynamic> m,
    Map<String, dynamic>? topProvider,
  ) {
    final spots = <Map<String, dynamic>>[
      m,
      if (topProvider != null) topProvider,
    ];
    // 1) Явные цены за миллион токенов.
    for (final spot in spots) {
      final pricing = asMap(spot['pricing']);
      final inM = asDouble(pick(spot, const <String>[
        'prompt_per_million', 'input_per_million',
        'prompt_per_1m', 'input_per_1m',
      ])) ??
          (pricing == null
              ? null
              : asDouble(pick(pricing, const <String>[
                  'prompt_per_million', 'input_per_million',
                  'prompt_per_1m', 'input_per_1m',
                ])));
      final outM = asDouble(pick(spot, const <String>[
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
        final cur = asStr(pick(spot, const <String>['currency'])) ??
            (pricing == null ? null : asStr(pricing['currency']));
        return (inM, outM, cur);
      }
    }
    // 2) Цены за один токен — переводятся в цену за миллион.
    for (final spot in spots) {
      final pricing = asMap(spot['pricing']);
      if (pricing == null) continue;
      final inTok = asDouble(pricing['prompt'] ?? pricing['input']);
      final outTok = asDouble(pricing['completion'] ?? pricing['output']);
      if (inTok == null && outTok == null) continue;
      double? scale(double? v) =>
          v == null ? null : (v < 0.01 ? v * 1000000 : v);
      return (scale(inTok), scale(outTok), asStr(pricing['currency']) ?? 'USD');
    }
    return (null, null, null);
  }

  /// Цены по разрешению из top_provider.pricing.tiers:
  /// [{"conditions": ["image_resolution=1K"], "cost_rub": "0.05"}]
  /// -> {'1K': 0.05}. Пустая карта — tiers нет либо не разобрались.
  static Map<String, double> parsePricingTiers(
    Map<String, dynamic>? topProvider,
  ) {
    final out = <String, double>{};
    final pricing = asMap(topProvider?['pricing']);
    final tiers = pricing?['tiers'];
    if (tiers is! List) return out;
    for (final t in tiers) {
      if (t is! Map) continue;
      final cost = asDouble(t['cost_rub']);
      if (cost == null) continue;
      final conditions = t['conditions'];
      if (conditions is! List) continue;
      for (final c in conditions) {
        if (c == null) continue;
        final s = c.toString().trim();
        if (s.isEmpty) continue;
        final eq = s.indexOf('=');
        final key = eq >= 0 ? s.substring(eq + 1).trim() : s;
        if (key.isNotEmpty && !out.containsKey(key)) out[key] = cost;
      }
    }
    return out;
  }

  /// Медиа-параметры записи: пропорции, разрешения, длительности
  /// (строки Polza вида '4' приводятся к int), качества и лимит
  /// референсных изображений. Ищет как в top_provider.parameters,
  /// так и в m.parameters.
  static ({
    List<String> aspectRatios,
    List<String> resolutions,
    List<int> durations,
    List<String> qualities,
    int? maxImages,
  }) parseMediaParams(
    Map<String, dynamic> m, [
    Map<String, dynamic>? topProvider,
  ]) {
    var aspectRatios = const <String>[];
    var imageResolutions = const <String>[];
    var videoResolutions = const <String>[];
    var durations = const <int>[];
    var qualities = const <String>[];
    int? maxImages;
    try {
      final tpParams = asMap(topProvider?['parameters']);
      final mParams = asMap(m['parameters']);
      final paramsList = <Map<String, dynamic>>[
        if (tpParams != null) tpParams,
        if (mParams != null) mParams,
      ];
      for (final params in paramsList) {
        if (aspectRatios.isEmpty) {
          aspectRatios = constraintValues(params['aspect_ratio']);
        }
        if (imageResolutions.isEmpty) {
          imageResolutions = constraintValues(params['image_resolution']);
        }
        if (videoResolutions.isEmpty) {
          videoResolutions = constraintValues(params['resolution']);
        }
        if (durations.isEmpty) {
          durations = durationValues(params['duration']);
        }
        if (qualities.isEmpty) {
          qualities = constraintValues(params['quality']);
        }
        maxImages ??= asInt(asMap(params['images'])?['max']);
      }
      // Формат RouterAI: плоские списки на верхнем уровне записи,
      // если блок parameters не дал данных.
      if (aspectRatios.isEmpty) {
        aspectRatios = asStrList(
          m['supported_aspect_ratios'] ??
              topProvider?['supported_aspect_ratios'],
        );
      }
      if (imageResolutions.isEmpty && videoResolutions.isEmpty) {
        final flat = asStrList(
          m['supported_resolutions'] ??
              topProvider?['supported_resolutions'] ??
              m['supported_image_sizes'],
        );
        imageResolutions = flat;
        videoResolutions = flat;
      }
      if (durations.isEmpty) {
        durations = asIntList(
          m['supported_durations'] ?? topProvider?['supported_durations'],
        );
      }
      if (qualities.isEmpty) {
        qualities = asStrList(
          m['supported_qualities'] ?? topProvider?['supported_qualities'],
        );
      }
    } catch (_) {
      // Битые медиа-поля не роняют разбор записи.
    }

    // Разрешения: для видео приоритет у `resolution` (720p/1080p),
    // для картинок — у `image_resolution` (0.5K/1K/2K/4K).
    final type = (asStr(m['type']) ?? '').toLowerCase();
    final resolutions = <String>[];
    void addRes(String v) {
      final t = v.trim();
      if (t.isEmpty) return;
      if (!resolutions.contains(t)) resolutions.add(t);
    }
    if (type == 'video') {
      for (final v in videoResolutions) {
        addRes(v);
      }
      for (final v in imageResolutions) {
        addRes(v);
      }
    } else {
      for (final v in imageResolutions) {
        addRes(v);
      }
      for (final v in videoResolutions) {
        addRes(v);
      }
    }

    return (
      aspectRatios: aspectRatios,
      resolutions: resolutions,
      durations: durations,
      qualities: qualities,
      maxImages: maxImages,
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
