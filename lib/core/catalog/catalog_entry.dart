// Copyright (c) 2026 Minkail. All rights reserved.

/// Источники данных записи каталога. Каждая группа данных (возможности,
/// цены) помнит, откуда она взята.
abstract final class CatalogSources {
  /// Данные из ответа GET {baseUrl}/models самого подключения.
  static const String connection = 'connection';

  /// Данные из справочника OpenRouter (только возможности, не цены).
  static const String openrouter = 'openrouter';

  /// Данные из курированного каталога проекта.
  static const String curated = 'curated';

  /// Запасные значения, когда другие источники молчат.
  static const String fallback = 'fallback';
}

/// Подключение: адрес провайдера и ключ (либо OAuth-токен Polza).
/// Нейтральные данные — собираются из пресетов, общих настроек
/// и активной Polza-сессии вызывающим кодом.
class CatalogConnection {
  /// Стабильный идентификатор подключения (для кэша и lookup).
  final String id;

  /// Base URL провайдера без завершающего слэша.
  final String baseUrl;

  /// Ключ доступа; используется так же, как в обычных запросах
  /// к этому подключению (Authorization: Bearer).
  final String apiKey;

  const CatalogConnection({
    required this.id,
    required this.baseUrl,
    required this.apiKey,
  });
}

/// Уровни размышлений (reasoning) модели: поддерживаемые усилия,
/// уровень по умолчанию и признак обязательности.
class CatalogReasoning {
  /// Поддерживаемые уровни ('max', 'high', 'low', 'none' ...) как есть
  /// из ответа провайдера.
  final List<String> levels;

  /// Уровень по умолчанию ('high' ...); '' — не сообщён.
  final String defaultEffort;

  /// true — размышления обязательны (уровень 'none' запрещён).
  final bool mandatory;

  const CatalogReasoning({
    required this.levels,
    this.defaultEffort = '',
    this.mandatory = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'levels': <String>[...levels],
        'defaultEffort': defaultEffort,
        'mandatory': mandatory,
      };

  factory CatalogReasoning.fromJson(Map<dynamic, dynamic> rawMap) {
    final j = <String, dynamic>{
      for (final entry in rawMap.entries)
        if (entry.key != null) entry.key.toString(): entry.value,
    };
    final raw = j['levels'];
    final defaultEffortRaw = j['defaultEffort'];
    return CatalogReasoning(
      levels: raw is List
          ? <String>[
              for (final e in raw)
                if (e != null && e.toString().trim().isNotEmpty)
                  e.toString().trim(),
            ]
          : const <String>[],
      defaultEffort: defaultEffortRaw is String ? defaultEffortRaw.trim() : '',
      mandatory: j['mandatory'] == true,
    );
  }
}

/// Конечная точка (провайдер/хостинг) конкретной модели в агрегаторе.
class ProviderEndpoint {
  static const Object _sentinel = Object();

  /// Идентификатор/тег провайдера (например, 'together', 'deepinfra/fp8').
  final String tag;

  /// Человекочитаемое имя провайдера или эндпоинта.
  final String name;

  /// Квантизация ('fp8', 'fp16', 'int4' ...); null — не указана.
  final String? quantization;

  /// Цена за 1 миллион входных токенов; null — неизвестна.
  final double? priceIn;

  /// Цена за 1 миллион выходных токенов; null — неизвестна.
  final double? priceOut;

  /// Контекстное окно на этом эндпоинте; null — неизвестно.
  final int? contextLength;

  /// Статус эндпоинта (например, 'online', 'degraded', '0'); null — неизвестен.
  final String? status;

  const ProviderEndpoint({
    required this.tag,
    this.name = '',
    this.quantization,
    this.priceIn,
    this.priceOut,
    this.contextLength,
    this.status,
  });

  /// Копия с заменой отдельных полей.
  ///
  /// Nullable-поля ([quantization], [priceIn], [priceOut], [contextLength],
  /// [status]) принимают `Object?` со значением по умолчанию `_sentinel`,
  /// поэтому передача `null` явно сбрасывает соответствующее поле в `null`.
  ProviderEndpoint copyWith({
    String? tag,
    String? name,
    Object? quantization = _sentinel,
    Object? priceIn = _sentinel,
    Object? priceOut = _sentinel,
    Object? contextLength = _sentinel,
    Object? status = _sentinel,
  }) {
    return ProviderEndpoint(
      tag: tag ?? this.tag,
      name: name ?? this.name,
      quantization: identical(quantization, _sentinel)
          ? this.quantization
          : quantization as String?,
      priceIn:
          identical(priceIn, _sentinel) ? this.priceIn : priceIn as double?,
      priceOut:
          identical(priceOut, _sentinel) ? this.priceOut : priceOut as double?,
      contextLength: identical(contextLength, _sentinel)
          ? this.contextLength
          : contextLength as int?,
      status: identical(status, _sentinel) ? this.status : status as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tag': tag,
        'name': name,
        if (quantization != null) 'quantization': quantization,
        if (priceIn != null) 'priceIn': priceIn,
        if (priceOut != null) 'priceOut': priceOut,
        if (contextLength != null) 'contextLength': contextLength,
        if (status != null) 'status': status,
      };

  /// Терпимый разбор эндпоинта из произвольного JSON-словаря.
  /// Некорректные типы полей приводятся к `null` без выброса исключений.
  factory ProviderEndpoint.fromJson(Map<dynamic, dynamic> rawMap) {
    final j = <String, dynamic>{
      for (final entry in rawMap.entries)
        if (entry.key != null) entry.key.toString(): entry.value,
    };

    String? optStr(Object? v) {
      if (v is String) {
        final s = v.trim();
        return s.isEmpty ? null : s;
      }
      return null;
    }

    double? optDouble(Object? v) {
      if (v is num) return v.toDouble();
      if (v is String) {
        return double.tryParse(v.trim().replaceAll(',', '.'));
      }
      return null;
    }

    int? optInt(Object? v) {
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    final tagStr = optStr(j['tag']) ?? optStr(j['id']) ?? '';
    final nameStr = optStr(j['name']) ?? '';

    return ProviderEndpoint(
      tag: tagStr,
      name: nameStr,
      quantization: optStr(j['quantization']),
      priceIn: optDouble(j['priceIn']),
      priceOut: optDouble(j['priceOut']),
      contextLength: optInt(j['contextLength']),
      status: j['status'] is String
          ? (j['status'] as String).trim()
          : (j['status'] is num ? j['status'].toString() : null),
    );
  }

  @override
  String toString() => 'ProviderEndpoint($tag, name: $name, '
      'priceIn: $priceIn, priceOut: $priceOut)';
}

/// Одна запись каталога моделей по подключению: сводка возможностей
/// и цен с указанием источника каждой группы данных.
///
/// Цены ([priceIn]/[priceOut] за 1M токенов, [mediaPrice] за 1 единицу медиа)
/// приходят ТОЛЬКО из ответа того подключения, которым модель будет вызвана
/// ([CatalogSources.connection]); справочник OpenRouter цены не поставляет.
class CatalogEntry {
  static const Object _sentinel = Object();

  final String connectionId;
  final String id;
  final String name;

  /// Тип модели: chat | image | video | tts | stt | embedding | music |
  /// classification; '' — тип неизвестен ни одному источнику.
  final String type;

  /// Поддерживаемые модальности модели (например: 'text', 'image', 'audio', 'video').
  final List<String> modalities;

  final int? contextLength;
  final int? maxCompletionTokens;

  /// Размышления; null — провайдер в известном формате явно не заявил
  /// reasoning (при неизвестном формате устанавливается [reasoningUnknown]).
  final CatalogReasoning? reasoning;

  /// Поддерживаемые уровни размышлений (например, ['low', 'medium', 'high']);
  /// null — уровни не заданы.
  final List<String>? reasoningLevels;

  /// Признак известности поддержки размышлений (reasoning) из API:
  /// - `true`: API заявил поддержку reasoning (возможно, без уровней);
  /// - `false`: API явно указал, что модель не поддерживает reasoning;
  /// - `null`: API промолчал (неизвестно).
  final bool? reasoningCapabilityKnown;

  /// true — провайдер не отдал ни reasoning, ни supported_parameters
  /// (формат В): данные считаются неизвестными и добираются из
  /// запасных источников.
  final bool reasoningUnknown;

  /// Список параметров, поддерживаемых моделью ('temperature', 'tools', 'reasoning' ...).
  final List<String> supportedParams;

  /// Поддержка инструментов (function calling); null — данных нет.
  final bool? supportsTools;

  final List<String> aspectRatios;
  final List<String> resolutions;

  /// Длительности видео в секундах (строки провайдера приводятся к int).
  final List<int> durations;
  final List<String> qualities;

  /// Максимум референсных изображений (Polza parameters.images.max).
  final int? maxReferenceImages;

  /// Цена за миллион входных/выходных токенов; null — цены нет
  /// (не показываем 0).
  final double? priceIn;
  final double? priceOut;

  /// Валюта цен ('RUB', 'USD' ...). По умолчанию '' если не определена.
  final String currency;

  /// Единица тарификации ('1M tokens', 'image', 'second', 'minute', 'char', 'request' ...);
  /// null — не указана.
  final String? pricingUnit;

  /// Цена за 1 единицу медиа (единица указана в [pricingUnit]);
  /// null — не медиа-тарификация или цена неизвестна.
  final double? mediaPrice;

  /// Произвольные параметры медиа-моделей (разрешения, лимиты, форматы и т.д.).
  final Map<String, dynamic> mediaParams;

  /// Доступные провайдерские эндпоинты модели.
  final List<ProviderEndpoint> endpoints;

  /// Загружены ли детальные эндпоинты модели.
  final bool endpointsLoaded;

  /// Источник группы «возможности»: connection | openrouter | curated |
  /// fallback ([CatalogSources]).
  final String capabilitiesSource;

  /// Источник группы «цены»: всегда connection либо null.
  final String? priceSource;

  const CatalogEntry({
    this.connectionId = '',
    required this.id,
    this.name = '',
    this.type = '',
    this.modalities = const <String>[],
    this.contextLength,
    this.maxCompletionTokens,
    this.reasoning,
    List<String>? reasoningLevels,
    this.reasoningCapabilityKnown,
    this.reasoningUnknown = false,
    this.supportedParams = const <String>[],
    this.supportsTools,
    this.aspectRatios = const <String>[],
    this.resolutions = const <String>[],
    this.durations = const <int>[],
    this.qualities = const <String>[],
    this.maxReferenceImages,
    this.priceIn,
    this.priceOut,
    String? currency,
    this.pricingUnit,
    this.mediaPrice,
    this.mediaParams = const <String, dynamic>{},
    this.endpoints = const <ProviderEndpoint>[],
    this.endpointsLoaded = false,
    this.capabilitiesSource = CatalogSources.fallback,
    this.priceSource,
  })  : currency = currency ?? '',
        reasoningLevels = reasoningLevels;

  /// Копия с заменой отдельных полей (для сборки по приоритетам в lookup
  /// и обновления состояния).
  ///
  /// Все nullable-поля (`contextLength`, `maxCompletionTokens`, `reasoning`,
  /// `reasoningLevels`, `reasoningCapabilityKnown`, `supportsTools`,
  /// `maxReferenceImages`, `priceIn`, `priceOut`, `pricingUnit`, `mediaPrice`,
  /// `priceSource`, а также `currency`) поддерживают явное обнуление через
  /// передачу `null` (используется внутренний sentinel `_sentinel`).
  ///
  /// Для обратной совместимости с существующим кодом:
  /// - если для поля `name`, `type`, `aspectRatios`, `resolutions`, `durations`,
  ///   `qualities`, `capabilitiesSource` передан `null`, сохраняется прежнее
  ///   значение `this.<field>`;
  /// - флаги `clearReasoning`, `clearReasoningUnknown`, `clearMaxCompletionTokens`,
  ///   `clearMaxReferenceImages` также поддерживаются.
  CatalogEntry copyWith({
    String? connectionId,
    String? id,
    String? name,
    String? type,
    List<String>? modalities,
    Object? contextLength = _sentinel,
    Object? maxCompletionTokens = _sentinel,
    Object? reasoning = _sentinel,
    Object? reasoningLevels = _sentinel,
    Object? reasoningCapabilityKnown = _sentinel,
    Object? reasoningUnknown = _sentinel,
    List<String>? supportedParams,
    Object? supportsTools = _sentinel,
    List<String>? aspectRatios,
    List<String>? resolutions,
    List<int>? durations,
    List<String>? qualities,
    Object? maxReferenceImages = _sentinel,
    Object? priceIn = _sentinel,
    Object? priceOut = _sentinel,
    Object? currency = _sentinel,
    Object? pricingUnit = _sentinel,
    Object? mediaPrice = _sentinel,
    Map<String, dynamic>? mediaParams,
    List<ProviderEndpoint>? endpoints,
    bool? endpointsLoaded,
    String? capabilitiesSource,
    Object? priceSource = _sentinel,
    bool clearReasoning = false,
    bool clearReasoningUnknown = false,
    bool clearMaxCompletionTokens = false,
    bool clearMaxReferenceImages = false,
  }) {
    final CatalogReasoning? nextReasoning;
    if (clearReasoning) {
      nextReasoning = null;
    } else if (identical(reasoning, _sentinel)) {
      nextReasoning = this.reasoning;
    } else {
      nextReasoning = reasoning as CatalogReasoning?;
    }

    final List<String>? nextReasoningLevels;
    if (clearReasoning && identical(reasoningLevels, _sentinel)) {
      nextReasoningLevels = null;
    } else if (identical(reasoningLevels, _sentinel)) {
      nextReasoningLevels = this.reasoningLevels ?? nextReasoning?.levels;
    } else {
      nextReasoningLevels = reasoningLevels as List<String>?;
    }

    final bool nextReasoningUnknown;
    if (clearReasoningUnknown) {
      nextReasoningUnknown = false;
    } else if (identical(reasoningUnknown, _sentinel)) {
      nextReasoningUnknown = this.reasoningUnknown;
    } else if (reasoningUnknown is bool) {
      nextReasoningUnknown = reasoningUnknown || this.reasoningUnknown;
    } else {
      nextReasoningUnknown = this.reasoningUnknown;
    }

    final int? nextMaxCompletionTokens;
    if (clearMaxCompletionTokens) {
      nextMaxCompletionTokens = null;
    } else if (identical(maxCompletionTokens, _sentinel)) {
      nextMaxCompletionTokens = this.maxCompletionTokens;
    } else {
      nextMaxCompletionTokens = maxCompletionTokens as int?;
    }

    final int? nextMaxReferenceImages;
    if (clearMaxReferenceImages) {
      nextMaxReferenceImages = null;
    } else if (identical(maxReferenceImages, _sentinel)) {
      nextMaxReferenceImages = this.maxReferenceImages;
    } else {
      nextMaxReferenceImages = maxReferenceImages as int?;
    }

    final String nextCurrency;
    if (identical(currency, _sentinel)) {
      nextCurrency = this.currency;
    } else if (currency is String) {
      nextCurrency = currency;
    } else {
      nextCurrency = '';
    }

    return CatalogEntry(
      connectionId: connectionId ?? this.connectionId,
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      modalities: modalities ?? this.modalities,
      contextLength: identical(contextLength, _sentinel)
          ? this.contextLength
          : contextLength as int?,
      maxCompletionTokens: nextMaxCompletionTokens,
      reasoning: nextReasoning,
      reasoningLevels: nextReasoningLevels,
      reasoningCapabilityKnown: identical(reasoningCapabilityKnown, _sentinel)
          ? this.reasoningCapabilityKnown
          : reasoningCapabilityKnown as bool?,
      reasoningUnknown: nextReasoningUnknown,
      supportedParams: supportedParams ?? this.supportedParams,
      supportsTools: identical(supportsTools, _sentinel)
          ? this.supportsTools
          : supportsTools as bool?,
      aspectRatios: aspectRatios ?? this.aspectRatios,
      resolutions: resolutions ?? this.resolutions,
      durations: durations ?? this.durations,
      qualities: qualities ?? this.qualities,
      maxReferenceImages: nextMaxReferenceImages,
      priceIn:
          identical(priceIn, _sentinel) ? this.priceIn : priceIn as double?,
      priceOut:
          identical(priceOut, _sentinel) ? this.priceOut : priceOut as double?,
      currency: nextCurrency,
      pricingUnit: identical(pricingUnit, _sentinel)
          ? this.pricingUnit
          : pricingUnit as String?,
      mediaPrice: identical(mediaPrice, _sentinel)
          ? this.mediaPrice
          : mediaPrice as double?,
      mediaParams: mediaParams ?? this.mediaParams,
      endpoints: endpoints ?? this.endpoints,
      endpointsLoaded: endpointsLoaded ?? this.endpointsLoaded,
      capabilitiesSource: capabilitiesSource ?? this.capabilitiesSource,
      priceSource: identical(priceSource, _sentinel)
          ? this.priceSource
          : priceSource as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'connectionId': connectionId,
        'id': id,
        'name': name,
        'type': type,
        'modalities': <String>[...modalities],
        if (contextLength != null) 'contextLength': contextLength,
        if (maxCompletionTokens != null)
          'maxCompletionTokens': maxCompletionTokens,
        if (reasoning != null) 'reasoning': reasoning!.toJson(),
        if (reasoningLevels != null)
          'reasoningLevels': <String>[...reasoningLevels!],
        if (reasoningCapabilityKnown != null)
          'reasoningCapabilityKnown': reasoningCapabilityKnown,
        'reasoningUnknown': reasoningUnknown,
        'supportedParams': <String>[...supportedParams],
        if (supportsTools != null) 'supportsTools': supportsTools,
        'aspectRatios': <String>[...aspectRatios],
        'resolutions': <String>[...resolutions],
        'durations': <int>[...durations],
        'qualities': <String>[...qualities],
        if (maxReferenceImages != null)
          'maxReferenceImages': maxReferenceImages,
        if (priceIn != null) 'priceIn': priceIn,
        if (priceOut != null) 'priceOut': priceOut,
        'currency': currency,
        if (pricingUnit != null) 'pricingUnit': pricingUnit,
        if (mediaPrice != null) 'mediaPrice': mediaPrice,
        'mediaParams': Map<String, dynamic>.from(mediaParams),
        'endpoints': <Map<String, dynamic>>[
          for (final ep in endpoints) ep.toJson(),
        ],
        'endpointsLoaded': endpointsLoaded,
        'capabilitiesSource': capabilitiesSource,
        if (priceSource != null) 'priceSource': priceSource,
      };

  /// Терпимый разбор сохранённой записи из произвольного JSON-словаря:
  /// битые/отсутствующие поля дают значения по умолчанию или `null`,
  /// невалидные элементы списков отфильтровываются, разбор не роняет
  /// вызывающий код.
  factory CatalogEntry.fromJson(Map<dynamic, dynamic> rawMap) {
    final j = <String, dynamic>{
      for (final entry in rawMap.entries)
        if (entry.key != null) entry.key.toString(): entry.value,
    };

    String? optStr(Object? v) => v is String ? v : null;

    int? optInt(Object? v) {
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    double? optDouble(Object? v) {
      if (v is num) return v.toDouble();
      if (v is String) {
        return double.tryParse(v.trim().replaceAll(',', '.'));
      }
      return null;
    }

    bool? optBool(Object? v) => v is bool ? v : null;

    List<String> strings(Object? raw) {
      if (raw is! List) return const <String>[];
      final out = <String>[];
      for (final e in raw) {
        if (e == null || e is Map || e is List) continue;
        final s = e.toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
      return out;
    }

    List<String>? optStrings(Object? raw) {
      if (raw is! List) return null;
      final out = <String>[];
      for (final e in raw) {
        if (e == null || e is Map || e is List) continue;
        final s = e.toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
      return out;
    }

    List<int> ints(Object? raw) {
      if (raw is! List) return const <int>[];
      final out = <int>[];
      for (final e in raw) {
        final v = optInt(e);
        if (v != null) out.add(v);
      }
      return out;
    }

    Map<String, dynamic> safeMap(Object? raw) {
      if (raw is! Map) return const <String, dynamic>{};
      final out = <String, dynamic>{};
      for (final entry in raw.entries) {
        if (entry.key != null) {
          out[entry.key.toString()] = entry.value;
        }
      }
      return out;
    }

    List<ProviderEndpoint> parseEndpoints(Object? raw) {
      if (raw is! List) return const <ProviderEndpoint>[];
      final out = <ProviderEndpoint>[];
      for (final item in raw) {
        if (item is! Map) continue;
        try {
          final ep = ProviderEndpoint.fromJson(item);
          if (ep.tag.isNotEmpty || ep.name.isNotEmpty) {
            out.add(ep);
          }
        } catch (_) {
          // Одна битая запись в endpoints не роняет весь fromJson.
        }
      }
      return out;
    }

    CatalogReasoning? parsedReasoning;
    final reasonRaw = j['reasoning'];
    if (reasonRaw is Map) {
      try {
        parsedReasoning = CatalogReasoning.fromJson(reasonRaw);
      } catch (_) {
        parsedReasoning = null;
      }
    }

    final parsedLevels =
        optStrings(j['reasoningLevels']) ?? parsedReasoning?.levels;

    return CatalogEntry(
      connectionId: optStr(j['connectionId']) ?? '',
      id: optStr(j['id']) ?? '',
      name: optStr(j['name']) ?? '',
      type: optStr(j['type']) ?? '',
      modalities: strings(j['modalities']),
      contextLength: optInt(j['contextLength']),
      maxCompletionTokens: optInt(j['maxCompletionTokens']),
      reasoning: parsedReasoning,
      reasoningLevels: parsedLevels,
      reasoningCapabilityKnown: optBool(j['reasoningCapabilityKnown']),
      reasoningUnknown: j['reasoningUnknown'] == true,
      supportedParams: strings(j['supportedParams']),
      supportsTools: optBool(j['supportsTools']),
      aspectRatios: strings(j['aspectRatios']),
      resolutions: strings(j['resolutions']),
      durations: ints(j['durations']),
      qualities: strings(j['qualities']),
      maxReferenceImages: optInt(j['maxReferenceImages']),
      priceIn: optDouble(j['priceIn']),
      priceOut: optDouble(j['priceOut']),
      currency: optStr(j['currency']) ?? '',
      pricingUnit: optStr(j['pricingUnit']),
      mediaPrice: optDouble(j['mediaPrice']),
      mediaParams: safeMap(j['mediaParams']),
      endpoints: parseEndpoints(j['endpoints']),
      endpointsLoaded: j['endpointsLoaded'] == true,
      capabilitiesSource:
          optStr(j['capabilitiesSource']) ?? CatalogSources.fallback,
      priceSource: optStr(j['priceSource']),
    );
  }

  @override
  String toString() =>
      'CatalogEntry($id, type: $type, src: $capabilitiesSource, '
      'price: $priceSource)';
}
