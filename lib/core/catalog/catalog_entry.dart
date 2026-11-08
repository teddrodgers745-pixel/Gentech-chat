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

  factory CatalogReasoning.fromJson(Map<String, dynamic> j) {
    final raw = j['levels'];
    return CatalogReasoning(
      levels: raw is List
          ? <String>[
              for (final e in raw)
                if (e != null && e.toString().trim().isNotEmpty)
                  e.toString().trim(),
            ]
          : const <String>[],
      defaultEffort: (j['defaultEffort'] as String?) ?? '',
      mandatory: j['mandatory'] == true,
    );
  }
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

  final int? contextLength;
  final int? maxCompletionTokens;

  /// Размышления; null — провайдер в известном формате явно не заявил
  /// reasoning (при неизвестном формате устанавливается [reasoningUnknown]).
  final CatalogReasoning? reasoning;

  /// true — провайдер не отдал ни reasoning, ни supported_parameters
  /// (формат В): данные считаются неизвестными и добираются из
  /// запасных источников.
  final bool reasoningUnknown;

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

  /// Валюта цен ('RUB', 'USD' ...); null — не определена.
  final String? currency;

  /// Источник группы «возможности»: connection | openrouter | curated |
  /// fallback ([CatalogSources]).
  final String capabilitiesSource;

  /// Источник группы «цены»: всегда connection либо null.
  final String? priceSource;

  const CatalogEntry({
    required this.connectionId,
    required this.id,
    this.name = '',
    this.type = '',
    this.contextLength,
    this.maxCompletionTokens,
    this.reasoning,
    this.reasoningUnknown = false,
    this.supportsTools,
    this.aspectRatios = const <String>[],
    this.resolutions = const <String>[],
    this.durations = const <int>[],
    this.qualities = const <String>[],
    this.maxReferenceImages,
    this.priceIn,
    this.priceOut,
    this.currency,
    this.capabilitiesSource = CatalogSources.fallback,
    this.priceSource,
  });

  /// Копия с заменой отдельных полей (для сборки по приоритетам в lookup).
  CatalogEntry copyWith({
    String? name,
    String? type,
    int? contextLength,
    int? maxCompletionTokens,
    CatalogReasoning? reasoning,
    bool reasoningUnknown = false,
    bool? supportsTools,
    List<String>? aspectRatios,
    List<String>? resolutions,
    List<int>? durations,
    List<String>? qualities,
    int? maxReferenceImages,
    double? priceIn,
    double? priceOut,
    String? currency,
    String? capabilitiesSource,
    String? priceSource,
    bool clearReasoning = false,
    bool clearReasoningUnknown = false,
    bool clearMaxCompletionTokens = false,
    bool clearMaxReferenceImages = false,
  }) {
    return CatalogEntry(
      connectionId: connectionId,
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      contextLength: contextLength ?? this.contextLength,
      maxCompletionTokens:
          clearMaxCompletionTokens ? null : (maxCompletionTokens ?? this.maxCompletionTokens),
      reasoning: clearReasoning ? null : (reasoning ?? this.reasoning),
      reasoningUnknown: clearReasoningUnknown
          ? false
          : (reasoningUnknown || this.reasoningUnknown),
      supportsTools: supportsTools ?? this.supportsTools,
      aspectRatios: aspectRatios ?? this.aspectRatios,
      resolutions: resolutions ?? this.resolutions,
      durations: durations ?? this.durations,
      qualities: qualities ?? this.qualities,
      maxReferenceImages:
          clearMaxReferenceImages ? null : (maxReferenceImages ?? this.maxReferenceImages),
      priceIn: priceIn ?? this.priceIn,
      priceOut: priceOut ?? this.priceOut,
      currency: currency ?? this.currency,
      capabilitiesSource: capabilitiesSource ?? this.capabilitiesSource,
      priceSource: priceSource ?? this.priceSource,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'connectionId': connectionId,
        'id': id,
        'name': name,
        'type': type,
        if (contextLength != null) 'contextLength': contextLength,
        if (maxCompletionTokens != null)
          'maxCompletionTokens': maxCompletionTokens,
        if (reasoning != null) 'reasoning': reasoning!.toJson(),
        'reasoningUnknown': reasoningUnknown,
        if (supportsTools != null) 'supportsTools': supportsTools,
        'aspectRatios': <String>[...aspectRatios],
        'resolutions': <String>[...resolutions],
        'durations': <int>[...durations],
        'qualities': <String>[...qualities],
        if (maxReferenceImages != null)
          'maxReferenceImages': maxReferenceImages,
        if (priceIn != null) 'priceIn': priceIn,
        if (priceOut != null) 'priceOut': priceOut,
        if (currency != null) 'currency': currency,
        'capabilitiesSource': capabilitiesSource,
        if (priceSource != null) 'priceSource': priceSource,
      };

  /// Терпимый разбор сохранённой записи: битые/отсутствующие поля дают
  /// значения по умолчанию, разбор не роняет вызывающий код.
  factory CatalogEntry.fromJson(Map<String, dynamic> j) {
    List<String> strings(Object? raw) {
      if (raw is! List) return const <String>[];
      return <String>[
        for (final e in raw)
          if (e != null) e.toString(),
      ];
    }

    List<int> ints(Object? raw) {
      if (raw is! List) return const <int>[];
      return <int>[
        for (final e in raw)
          if (e is num) e.round(),
      ];
    }

    final reasonRaw = j['reasoning'];
    return CatalogEntry(
      connectionId: (j['connectionId'] as String?) ?? '',
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      type: (j['type'] as String?) ?? '',
      contextLength: (j['contextLength'] as num?)?.toInt(),
      maxCompletionTokens: (j['maxCompletionTokens'] as num?)?.toInt(),
      reasoning: reasonRaw is Map
          ? CatalogReasoning.fromJson(Map<String, dynamic>.from(reasonRaw))
          : null,
      reasoningUnknown: j['reasoningUnknown'] == true,
      supportsTools: j['supportsTools'] is bool
          ? j['supportsTools'] as bool
          : null,
      aspectRatios: strings(j['aspectRatios']),
      resolutions: strings(j['resolutions']),
      durations: ints(j['durations']),
      qualities: strings(j['qualities']),
      maxReferenceImages: (j['maxReferenceImages'] as num?)?.toInt(),
      priceIn: (j['priceIn'] as num?)?.toDouble(),
      priceOut: (j['priceOut'] as num?)?.toDouble(),
      currency: j['currency'] as String?,
      capabilitiesSource:
          (j['capabilitiesSource'] as String?) ?? CatalogSources.fallback,
      priceSource: j['priceSource'] as String?,
    );
  }

  @override
  String toString() =>
      'CatalogEntry($id, type: $type, src: $capabilitiesSource, '
      'price: $priceSource)';
}
