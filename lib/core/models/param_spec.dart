// Copyright (c) 2026 Minkail. All rights reserved.

/// Модель параметров генерации конкретной модели: какие пропорции,
/// длительности, разрешения, размеры и качества она поддерживает.
/// Данные приходят из курированного каталога (assets/data/models_curated.json)
/// либо из пользовательского override (UserParamOverrideStore).
///
/// Нейтральная модель: значения — plain data, подписи и нормализацию
/// под конкретный API делает существующий ParameterTranslator.
library;

/// Виды параметров генерации, которые описывает [ModelParameters].
enum ParamKind {
  aspectRatio,
  duration,
  resolution,
  size,
  quality,
}

/// Диапазон длительности видео: либо непрерывный диапазон (min..max),
/// либо дискретный список допустимых значений ([discrete]).
class DurationRange {
  /// Минимальная длительность в секундах; null — диапазон не задан.
  int? min;

  /// Максимальная длительность в секундах; null — диапазон не задан.
  int? max;

  /// Дискретный список длительностей (4, 8, 12 ...); null либо пусто —
  /// длительность задаётся диапазоном min..max, если он известен.
  List<int>? discrete;

  DurationRange({this.min, this.max, this.discrete});

  /// Есть ли хоть какие-то данные о длительности.
  bool get isEmpty =>
      min == null && max == null && (discrete == null || discrete!.isEmpty);

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (discrete != null) 'discrete': <int>[...?discrete],
      };

  factory DurationRange.fromJson(Map<String, dynamic> j) {
    List<int>? discrete;
    final raw = j['discrete'];
    if (raw is List) {
      discrete = <int>[
        for (final e in raw)
          if (e is num) e.round(),
      ];
      if (discrete.isEmpty) discrete = null;
    }
    return DurationRange(
      min: (j['min'] as num?)?.toInt(),
      max: (j['max'] as num?)?.toInt(),
      discrete: discrete,
    );
  }
}

/// Сводка параметров генерации одной модели.
class ModelParameters {
  /// Поддерживаемые пропорции ('1:1', '16:9', ...).
  List<String> aspectRatios;

  /// Диапазон/список длительностей видео; null — параметра нет.
  DurationRange? durations;

  /// Допустимые разрешения ('720p', '1K', '4K' ...).
  List<String> resolutions;

  /// Допустимые размеры холста ('1024x1024', ...).
  List<String> sizes;

  /// Допустимые уровни качества ('low', 'hd' ...).
  List<String> qualities;

  /// Особые ограничения модели в свободной текстовой форме
  /// ('no aspect_ratio, use size only', '4K only with 8s' ...).
  List<String> constraints;

  /// Тип модели ('video' и т.п.); null — тип не задан (авто).
  String? type;

  /// Достоверность данных: 'high' в курированном каталоге, 'auto' из
  /// пресетов моделей, 'user' в пользовательских override, 'skip' —
  /// модель не является генератором.
  String confidence;

  /// true — параметры заданы пользователем (override), а не каталогом.
  bool isUserDefined;

  ModelParameters({
    List<String>? aspectRatios,
    this.durations,
    List<String>? resolutions,
    List<String>? sizes,
    List<String>? qualities,
    List<String>? constraints,
    this.type,
    this.confidence = 'low',
    this.isUserDefined = false,
  })  : aspectRatios = aspectRatios ?? <String>[],

        resolutions = resolutions ?? <String>[],
        sizes = sizes ?? <String>[],
        qualities = qualities ?? <String>[],
        constraints = constraints ?? <String>[];

  /// Пустая спецификация: данных о параметрах нет. Используется каталогом,
  /// чтобы отличить «нет данных» от «модель не генератор» (confidence='skip').
  factory ModelParameters.unknown({String confidence = 'low'}) =>
      ModelParameters(confidence: confidence, isUserDefined: false);

  /// Есть ли у модели хоть один настраиваемый параметр.
  bool get hasAny =>
      aspectRatios.isNotEmpty ||
      (durations != null && !durations!.isEmpty) ||
      resolutions.isNotEmpty ||
      sizes.isNotEmpty ||
      qualities.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'aspectRatios': <String>[...aspectRatios],
        if (durations != null) 'durations': durations!.toJson(),
        'resolutions': <String>[...resolutions],
        'sizes': <String>[...sizes],
        'qualities': <String>[...qualities],
        'constraints': <String>[...constraints],
        if (type != null) 'type': type,
        'confidence': confidence,
        'isUserDefined': isUserDefined,
      };

  /// Терпимый разбор: отсутствующие поля -> пустые значения,
  /// битые элементы пропускаются, разбор не роняет вызывающий код.
  factory ModelParameters.fromJson(Map<String, dynamic> j) {
    List<String> strings(Object? raw) {
      if (raw is! List) return <String>[];
      return <String>[
        for (final e in raw)
          if (e != null) e.toString(),
      ];
    }

    DurationRange? durations;
    final rawDur = j['durations'];
    if (rawDur is Map) {
      try {
        final dr = DurationRange.fromJson(Map<String, dynamic>.from(rawDur));
        if (!dr.isEmpty) durations = dr;
      } catch (_) {
        durations = null;
      }
    }
    return ModelParameters(
      aspectRatios: strings(j['aspectRatios']),
      durations: durations,
      resolutions: strings(j['resolutions']),
      sizes: strings(j['sizes']),
      qualities: strings(j['qualities']),
      constraints: strings(j['constraints']),
      type: (j['type'] as String?),
      confidence: (j['confidence'] as String?) ?? 'low',
      isUserDefined: j['isUserDefined'] == true,
    );
  }
}
