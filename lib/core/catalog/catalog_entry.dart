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
    final defRaw = j['defaultEffort'];
    return CatalogReasoning(
      levels: raw is List
          ? <String>[
              for (final e in raw)
                if (e != null && e.toString().trim().isNotEmpty)
                  e.toString().trim(),
            ]
          : const <String>[],
      defaultEffort: defRaw is String ? defRaw : '',
      mandatory: j['mandatory'] == true,
    );
  }
}

/// Информация о конкретном эндпоинте (провайдере) внутри агрегатора.
class ProviderEndpoint {
  final String tag;
  final String name;
  final String? quantization;
  final double? priceIn;
  final double? priceOut;
  final int? contextLength;
  final String? status;

  static const Object _sentinel = Object();

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
  /// Для явного обнуления nullable-полей передайте `null` (используется
  /// внутренний sentinel-объект [_sentinel], отличающий пропуск аргумента
  /// от явной передачи `null`).
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
      priceIn: identical(priceIn, _sentinel)
          ? this.priceIn
          : (priceIn as num?)?.toDouble(),
      priceOut: identical(priceOut, _sentinel)
          ? this.priceOut
          : (priceOut as num?)?.toDouble(),
      contextLength: identical(contextLength, _sentinel)
          ? this.contextLength
          : (contextLength as num?)?.toInt(),
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

  /// Терпимый разбор эндпоинта из JSON. Невалидные типы приводятся к null
  /// или безопасным дефолтам без выброса исключений.
  factory ProviderEndpoint.fromJson(Map<dynamic, dynamic> raw) {
    final j = <String, dynamic>{
      for (final entry in raw.entries)
        if (entry.key != null) entry.key.toString(): entry.value,
    };

    String? str(Object? v) {
      if (v is String) return v;
      return null;
    }

    double? dbl(Object? v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
      return null;
    }

    int? integer(Object? v) {
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    return ProviderEndpoint(
      tag: str(j['tag']) ?? '',
      name: str(j['name']) ?? '',
      quantization: str(j['quantization']),
      priceIn: dbl(j['priceIn']),
      priceOut: dbl(j['priceOut']),
      contextLength: integer(j['contextLength']),
      status: str(j['status']),
    );
  }

  @override
  String toString() => 'ProviderEndpoint($tag, name: $name)';
}

/// Одна запись каталога моделей по подключению: сводка возможностей
/// и цен с указанием источника каждой группы данных.
///
/// Цены ([priceIn]/[priceOut] за 1M токенов) приходят ТОЛЬКО из ответа
/// того подключения, которым модель будет вызвана ([CatalogSources.connection]);
/// справочник OpenRouter цены не поставляет.
class CatalogEntry {
  final String connectionId;
  final String id;
  final String name;

  /// Тип модели: chat | image | video | tts | stt | embedding | music |
  /// classification; '' — тип неизвестен ни одному источнику.
  final String type;

  /// Модальности модели (например: text, image, audio, video).
  final List<String> modalities;

  final int? contextLength;
  final int? maxCompletionTokens;

  /// Размышления; null — провайдер в известном формате явно не заявил
  /// reasoning (при неизвестном формате устанавливается [reasoningUnknown]).
  final CatalogReasoning? reasoning;

  /// Список поддерживаемых уровней размышлений (например: low, medium, high);
  /// null — уровни не заданы.
  final List<String>? reasoningLevels;

  /// Признак известности поддержки reasoning из API:
  /// - `true`: API заявил поддержку reasoning, но без конкретных уровней;
  /// - `false`: API явно указал отсутствие поддержки reasoning;
  /// - `null`: API промолчал (неизвестно).
  final bool? reasoningCapabilityKnown;

  /// true — провайдер не отдал ни reasoning, ни supported_parameters
  /// (формат В): данные считаются неизвестными и добираются из
  /// запасных источников.
  final bool reasoningUnknown;

  /// Поддерживаемые параметры API (tools, reasoning, temperature и т.д.).
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

  /// Валюта цен ('RUB', 'USD' ...); по умолчанию 'USD'.
  final String currency;

  /// Единица тарификации для медиа/спец. моделей (например, 'image', 'second',
  /// 'character', 'request'); null — стандартная токенная тарификация.
  final String? pricingUnit;

  /// Цена за 1 единицу медиа (единица указана в [pricingUnit]); null — нет.
  final double? mediaPrice;

  /// Произвольные медиа-параметры и ограничения модели из API.
  final Map<String, dynamic> mediaParams;

  /// Список доступных эндпоинтов/провайдеров для данной модели.
  final List<ProviderEndpoint> endpoints;

  /// Были ли загружены эндпоинты для этой модели.
  final bool endpointsLoaded;

  /// Источник группы «возможности»: connection | openrouter | curated |
  /// fallback ([CatalogSources]).
  final String capabilitiesSource;

  /// Источник группы «цены»: всегда connection либо null.
  final String? priceSource;

  static const Object _sentinel = Object();

  const CatalogEntry({
    this.connectionId = '',
    required this.id,
    this.name = '',
    this.type = '',
    this.modalities = const <String>[],
    this.contextLength,
    this.maxCompletionTokens,
    this.reasoning,
    this.reasoningLevels,
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
  }) : currency = currency ?? 'USD';

  /// Копия с заменой отдельных полей (для сборки по приоритетам в lookup).
  ///
  /// Поддерживает явное обнуление nullable-полей через паттерн sentinel
  /// ([_sentinel]): если передать `field: null`, поле будет сброшено в `null`
  /// (для совместимости со старым кодом при передаче `null` в поля `name`,
  /// `type`, `currency`, `capabilitiesSource`, списки или булевы флаги
  /// сохраняется прежнее значение `this.<field>`).
  /// Также сохранены флаги `clearReasoning`, `clearReasoningUnknown`,
  /// `clearMaxCompletionTokens`, `clearMaxReferenceImages` для обратной
  /// совместимости с существующими вызовами.
  CatalogEntry copyWith({
    Object? connectionId = _sentinel,
    Object? id = _sentinel,
    Object? name = _sentinel,
    Object? type = _sentinel,
    Object? modalities = _sentinel,
    Object? contextLength = _sentinel,
    Object? maxCompletionTokens = _sentinel,
    Object? reasoning = _sentinel,
    Object? reasoningLevels = _sentinel,
    Object? reasoningCapabilityKnown = _sentinel,
    Object? reasoningUnknown = _sentinel,
    Object? supportedParams = _sentinel,
    Object? supportsTools = _sentinel,
    Object? aspectRatios = _sentinel,
    Object? resolutions = _sentinel,
    Object? durations = _sentinel,
    Object? qualities = _sentinel,
    Object? maxReferenceImages = _sentinel,
    Object? priceIn = _sentinel,
    Object? priceOut = _sentinel,
    Object? currency = _sentinel,
    Object? pricingUnit = _sentinel,
    Object? mediaPrice = _sentinel,
    Object? mediaParams = _sentinel,
    Object? endpoints = _sentinel,
    Object? endpointsLoaded = _sentinel,
    Object? capabilitiesSource = _sentinel,
    Object? priceSource = _sentinel,
    bool clearReasoning = false,
    bool clearReasoningUnknown = false,
    bool clearMaxCompletionTokens = false,
    bool clearMaxReferenceImages = false,
  }) {
    final String resolvedConnectionId =
        identical(connectionId, _sentinel) || connectionId == null
            ? this.connectionId
            : connectionId as String;
    final String resolvedId = identical(id, _sentinel) || id == null
        ? this.id
        : id as String;
    final String resolvedName = identical(name, _sentinel) || name == null
        ? this.name
        : name as String;
    final String resolvedType = identical(type, _sentinel) || type == null
        ? this.type
        : type as String;
    final List<String> resolvedModalities =
        identical(modalities, _sentinel) || modalities == null
            ? this.modalities
            : modalities as List<String>;
    final int? resolvedContextLength = identical(contextLength, _sentinel)
        ? this.contextLength
        : (contextLength as num?)?.toInt();
    final int? resolvedMaxCompletionTokens = clearMaxCompletionTokens
        ? null
        : (identical(maxCompletionTokens, _sentinel)
            ? this.maxCompletionTokens
            : (maxCompletionTokens as num?)?.toInt());
    final CatalogReasoning? resolvedReasoning = clearReasoning
        ? null
        : (identical(reasoning, _sentinel)
            ? this.reasoning
            : reasoning as CatalogReasoning?);
    final List<String>? resolvedReasoningLevels =
        identical(reasoningLevels, _sentinel)
            ? this.reasoningLevels
            : reasoningLevels as List<String>?;
    final bool? resolvedReasoningCapabilityKnown =
        identical(reasoningCapabilityKnown, _sentinel)
            ? this.reasoningCapabilityKnown
            : reasoningCapabilityKnown as bool?;
    final bool resolvedReasoningUnknown = clearReasoningUnknown
        ? false
        : (identical(reasoningUnknown, _sentinel) || reasoningUnknown == null
            ? this.reasoningUnknown
            : reasoningUnknown as bool);
    final List<String> resolvedSupportedParams =
        identical(supportedParams, _sentinel) || supportedParams == null
            ? this.supportedParams
            : supportedParams as List<String>;
    final bool? resolvedSupportsTools = identical(supportsTools, _sentinel)
        ? this.supportsTools
        : supportsTools as bool?;
    final List<String> resolvedAspectRatios =
        identical(aspectRatios, _sentinel) || aspectRatios == null
            ? this.aspectRatios
            : aspectRatios as List<String>;
    final List<String> resolvedResolutions =
        identical(resolutions, _sentinel) || resolutions == null
            ? this.resolutions
            : resolutions as List<String>;
    final List<int> resolvedDurations =
        identical(durations, _sentinel) || durations == null
            ? this.durations
            : durations as List<int>;
    final List<String> resolvedQualities =
        identical(qualities, _sentinel) || qualities == null
            ? this.qualities
            : qualities as List<String>;
    final int? resolvedMaxReferenceImages = clearMaxReferenceImages
        ? null
        : (identical(maxReferenceImages, _sentinel)
            ? this.maxReferenceImages
            : (maxReferenceImages as num?)?.toInt());
    final double? resolvedPriceIn = identical(priceIn, _sentinel)
        ? this.priceIn
        : (priceIn as num?)?.toDouble();
    final double? resolvedPriceOut = identical(priceOut, _sentinel)
        ? this.priceOut
        : (priceOut as num?)?.toDouble();
    final String resolvedCurrency =
        identical(currency, _sentinel) || currency == null
            ? this.currency
            : currency as String;
    final String? resolvedPricingUnit = identical(pricingUnit, _sentinel)
        ? this.pricingUnit
        : pricingUnit as String?;
    final double? resolvedMediaPrice = identical(mediaPrice, _sentinel)
        ? this.mediaPrice
        : (mediaPrice as num?)?.toDouble();
    final Map<String, dynamic> resolvedMediaParams =
        identical(mediaParams, _sentinel) || mediaParams == null
            ? this.mediaParams
            : mediaParams as Map<String, dynamic>;
    final List<ProviderEndpoint> resolvedEndpoints =
        identical(endpoints, _sentinel) || endpoints == null
            ? this.endpoints
            : endpoints as List<ProviderEndpoint>;
    final bool resolvedEndpointsLoaded =
        identical(endpointsLoaded, _sentinel) || endpointsLoaded == null
            ? this.endpointsLoaded
            : endpointsLoaded as bool;
    final String resolvedCapabilitiesSource =
        identical(capabilitiesSource, _sentinel) || capabilitiesSource == null
            ? this.capabilitiesSource
            : capabilitiesSource as String;
    final String? resolvedPriceSource = identical(priceSource, _sentinel)
        ? this.priceSource
        : priceSource as String?;

    return CatalogEntry(
      connectionId: resolvedConnectionId,
      id: resolvedId,
      name: resolvedName,
      type: resolvedType,
      modalities: resolvedModalities,
      contextLength: resolvedContextLength,
      maxCompletionTokens: resolvedMaxCompletionTokens,
      reasoning: resolvedReasoning,
      reasoningLevels: resolvedReasoningLevels,
      reasoningCapabilityKnown: resolvedReasoningCapabilityKnown,
      reasoningUnknown: resolvedReasoningUnknown,
      supportedParams: resolvedSupportedParams,
      supportsTools: resolvedSupportsTools,
      aspectRatios: resolvedAspectRatios,
      resolutions: resolvedResolutions,
      durations: resolvedDurations,
      qualities: resolvedQualities,
      maxReferenceImages: resolvedMaxReferenceImages,
      priceIn: resolvedPriceIn,
      priceOut: resolvedPriceOut,
      currency: resolvedCurrency,
      pricingUnit: resolvedPricingUnit,
      mediaPrice: resolvedMediaPrice,
      mediaParams: resolvedMediaParams,
      endpoints: resolvedEndpoints,
      endpointsLoaded: resolvedEndpointsLoaded,
      capabilitiesSource: resolvedCapabilitiesSource,
      priceSource: resolvedPriceSource,
    );
  }
