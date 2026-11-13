// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import '../catalog_entry.dart';

/// Терпимый парсер каталога моделей Polza (GET {baseUrl}/models).
///
/// Разбирает известные поля формата Polza:
///  - type, context_length, max_completion_tokens;
///  - top_provider.reasoning (supported_efforts, default_effort,
///    mandatory) и supported_parameters;
///  - top_provider.pricing — цены за миллион токенов (prompt_per_million,
///    completion_per_million ...);
///  - parameters — медиа-поля: aspect_ratio, resolution, duration
///    (строки вида '4' приводятся к int), quality, images.max.
///
/// Битые значения приводятся к null/пустым спискам, разбор одной записи
/// никогда не роняет остальные. Запись без идентификатора отбрасывается.
abstract final class PolzaParser {
  /// Типы моделей, известные каталогу.
  static const Set<String> knownTypes = <String>{
    'chat', 'image', 'video', 'tts', 'stt', 'embedding', 'music',
    'classification',
  };

  /// Уровни размышлений по умолчанию, когда провайдер заявил reasoning,
  /// но не перечислил уровни.
  static const List<String> defaultReasoningLevels = <String>[
    'none', 'low', 'medium', 'high',
  ];

  /// Базовые уровни, когда reasoning заявлен только в supported_parameters.
  static const List<String> supportedParamsReasoningLevels = <String>[
    'off', 'high',
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
        parseReasoning(m, topProvider, supportedParams);

    final media = parseMediaParams(m);

    bool? supportsTools;
    if (supportedParams.isNotEmpty) {
      supportsTools = supportedParams.contains('tools') ||
          supportedParams.contains('function_calling');
    }

    final (priceIn, priceOut, currency) = parsePrice(m, topProvider);

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
      priceIn: priceIn,
      priceOut: priceOut,
      currency: currency,
      capabilitiesSource: CatalogSources.connection,
      priceSource: (priceIn != null || priceOut != null)
          ? CatalogSources.connection
          : null,
    );
  }

  /// Reasoning: m['reasoning'] и/или m['top_provider']['reasoning'].
  /// Возвращает (reasoning, unknown); unknown=true — провайдер не отдал
  /// ни reasoning, ни supported_parameters (данные неизвестны).
  static (CatalogReasoning?, bool) parseReasoning(
    Map<String, dynamic> m,
    Map<String, dynamic>? topProvider,
    List<String> supportedParams,
  ) {
    var candidate = asMap(m['reasoning']);
    var marker = identical(m['reasoning'], true);
    final tpRaw = topProvider?['reasoning'];
    if (candidate == null && !marker) {
      candidate = asMap(tpRaw);
      marker = identical(tpRaw, true);
    }
    if (candidate != null) {
      final efforts = asStrList(
        candidate['supported_efforts'] ?? candidate['supportedEfforts'],
      );
      final def = asStr(
            candidate['default_effort'] ?? candidate['defaultEffort'],
          ) ??
          '';
      if (efforts.isNotEmpty) {
        return (
          CatalogReasoning(
            levels: efforts,
            defaultEffort: def,
            mandatory: candidate['mandatory'] == true,
          ),
          false,
        );
      }
      // Словарь без списка усилий: базовые уровни.
      return (
        CatalogReasoning(
          levels: List<String>.of(defaultReasoningLevels),
          defaultEffort: def,
          mandatory: candidate['mandatory'] == true,
        ),
        false,
      );
    }
    if (marker) {
      // reasoning: true — уровни не перечислены.
      return (
        CatalogReasoning(levels: List<String>.of(defaultReasoningLevels)),
        false,
      );
    }
    if (supportedParams.contains('reasoning') ||
        supportedParams.contains('reasoning_effort')) {
      return (
        CatalogReasoning(
          levels: List<String>.of(supportedParamsReasoningLevels),
        ),
        false,
      );
    }
    if (supportedParams.isNotEmpty) {
      // supported_parameters есть, reasoning не заявлен: провайдер явно
      // не заявил (не неизвестно).
      return (null, false);
    }
    // Ни reasoning, ни supported_parameters — неизвестно.
    return (null, true);
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

  /// Медиа-параметры записи: пропорции, разрешения, длительности
  /// (строки Polza вида '4' приводятся к int), качества и лимит
  /// референсных изображений.
  static ({
    List<String> aspectRatios,
    List<String> resolutions,
    List<int> durations,
    List<String> qualities,
    int? maxImages,
  }) parseMediaParams(Map<String, dynamic> m) {
    var aspectRatios = const <String>[];
    var resolutions = const <String>[];
    var durations = const <int>[];
    var qualities = const <String>[];
    int? maxImages;
    try {
      final params = asMap(m['parameters']);
      if (params != null) {
        aspectRatios = asStrList(asMap(params['aspect_ratio'])?['values']);
        resolutions = asStrList(asMap(params['resolution'])?['values']);
        durations = asIntList(asMap(params['duration'])?['values']);
        qualities = asStrList(asMap(params['quality'])?['values']);
        maxImages = asInt(asMap(params['images'])?['max']);
      }
      // Формат RouterAI: плоские списки на верхнем уровне записи,
      // если блок parameters не дал данных.
      if (aspectRatios.isEmpty) {
        aspectRatios = asStrList(m['supported_aspect_ratios']);
      }
      if (resolutions.isEmpty) {
        resolutions = asStrList(m['supported_resolutions']);
      }
      if (durations.isEmpty) {
        durations = asIntList(m['supported_durations']);
      }
    } catch (_) {
      // Битые медиа-поля не роняют разбор записи.
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
    if (v is String) return int.tryParse(v.trim());
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

  /// Первое ненулевое значение по списку ключей.
  static Object? pick(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v != null) return v;
    }
    return null;
  }
}
