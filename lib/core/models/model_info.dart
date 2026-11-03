// Copyright (c) 2026 Minkail. All rights reserved.

import 'generation_schema.dart';

/// Модальность данных: что модель принимает на вход или отдаёт на выход.
enum Modality {
  text,
  image,
  audio,
  video;

  /// Разбор названия модальности из каталога провайдера.
  /// Терпимо к синонимам: 'image_url', 'vision', 'images' -> image.
  static Modality? fromName(String? raw) {
    final s = (raw ?? '').trim().toLowerCase();
    if (s.isEmpty) return null;
    const map = <String, Modality>{
      'text': Modality.text,
      'image': Modality.image,
      'images': Modality.image,
      'image_url': Modality.image,
      'vision': Modality.image,
      'audio': Modality.audio,
      'speech': Modality.audio,
      'video': Modality.video,
    };
    return map[s];
  }

  /// Человекочитаемое название по-русски.
  String get label => switch (this) {
        Modality.text => 'текст',
        Modality.image => 'изображения',
        Modality.audio => 'аудио',
        Modality.video => 'видео',
      };
}

/// Маршрут генерации: через какой API работает модель.
enum GenerationRoute {
  chatCompletions,
  responsesApi,
  imageGeneration,
  liveRealtime,
  textToSpeech,
  audioTranscription,
  embeddings,

  /// Асинхронная задача генерации видео: запрос создаёт задание,
  /// результат приходит позже (kling, veo, sora, wan ...).
  asyncJob;

  /// Человекочитаемое название по-русски.
  String get label => switch (this) {
        GenerationRoute.chatCompletions => 'чат',
        GenerationRoute.responsesApi => 'responses',
        GenerationRoute.imageGeneration => 'генерация изображений',
        GenerationRoute.liveRealtime => 'голосовой режим',
        GenerationRoute.textToSpeech => 'озвучка',
        GenerationRoute.audioTranscription => 'распознавание речи',
        GenerationRoute.embeddings => 'эмбеддинги',
        GenerationRoute.asyncJob => 'генерация видео (асинхронно)',
      };

  /// Модель общается через чат-протокол (текстовые сообщения).
  bool get isChat =>
      this == GenerationRoute.chatCompletions ||
      this == GenerationRoute.responsesApi;
}

/// Откуда приложение знает возможности модели.
enum CapabilitySource {
  /// Данные получены из каталога провайдера (/models).
  providerCatalog,

  /// Выведено эвристикой по идентификатору модели.
  heuristic,

  /// Указано пользователем вручную.
  userOverride;

  String get label => switch (this) {
        CapabilitySource.providerCatalog => 'каталог провайдера',
        CapabilitySource.heuristic => 'эвристика',
        CapabilitySource.userOverride => 'указано вручную',
      };
}

/// Цены модели за миллион токенов: вход и выход.
class Pricing {
  final double? inputPerMillion;
  final double? outputPerMillion;

  /// Валюта ('USD', 'RUB' ...); по умолчанию — доллары каталогов.
  final String currency;

  const Pricing({
    this.inputPerMillion,
    this.outputPerMillion,
    this.currency = 'USD',
  });

  /// Известна ли хоть одна цена.
  bool get hasAny =>
      (inputPerMillion != null && inputPerMillion! > 0) ||
      (outputPerMillion != null && outputPerMillion! > 0);

  /// Короткая подпись для интерфейса, null — если цен нет.
  String? get summary {
    if (!hasAny) return null;
    final symbol = currency == 'RUB' ? '₽' : r'$';
    final parts = <String>[
      if (inputPerMillion != null && inputPerMillion! > 0)
        'вход ${inputPerMillion!.toStringAsFixed(2)}',
      if (outputPerMillion != null && outputPerMillion! > 0)
        'выход ${outputPerMillion!.toStringAsFixed(2)}',
    ];
    if (parts.isEmpty) return null;
    return '${parts.join(' / ')} $symbol/1M';
  }

  /// Цена за один токен (как в OpenRouter) -> цена за миллион токенов.
  /// Значения >= 1 считаются уже переведёнными и возвращаются как есть.
  static double? perTokenToPerMillion(double? perToken) {
    if (perToken == null || perToken <= 0) return null;
    return perToken < 1 ? perToken * 1000000 : perToken;
  }

  @override
  String toString() => 'Pricing(in: $inputPerMillion, out: $outputPerMillion)';
}

/// Сводка возможностей модели: модальности входа/выхода, маршрут
/// генерации, флаги стриминга/инструментов/размышлений, контекст, цены
/// и схема параметров генерации. Используется интерфейсом (адаптивный
/// ввод, фильтры списка моделей) и сервисами (выбор формата запроса).
class ModelInfo {
  /// Полный идентификатор модели, как его вернул каталог
  /// (например 'vendor/model-name').
  final String id;

  /// Понятное имя из каталога; если нет — вычисляется из [id].
  final String? displayName;

  /// Идентификатор провайдера ('polza', 'openrouter' ...); '' — неизвестен.
  final String providerId;

  /// Что модель принимает на вход.
  final Set<Modality> inputModalities;

  /// Что модель отдаёт на выход.
  final Set<Modality> outputModalities;

  /// Через какой API работать с моделью.
  final GenerationRoute route;

  /// Поддерживает ли SSE-стриминг ответа.
  final bool supportsStreaming;

  /// Поддерживает ли вызов инструментов (function calling).
  final bool supportsTools;

  /// Умеет ли «размышлять» (reasoning/thinking).
  final bool supportsReasoning;

  /// Размер контекстного окна в токенах, если известен.
  final int? contextLength;

  /// Цены за миллион токенов, если известны.
  final Pricing? pricing;

  /// Источник этих сведений.
  final CapabilitySource source;

  /// Схема параметров генерации (пропорции, размер, длительность и т.п.);
  /// null — модель не сообщает параметры либо кеш старого формата.
  final GenerationSchema? generationSchema;

  const ModelInfo({
    required this.id,
    this.displayName,
    this.providerId = '',
    this.inputModalities = const <Modality>{Modality.text},
    this.outputModalities = const <Modality>{Modality.text},
    this.route = GenerationRoute.chatCompletions,
    this.supportsStreaming = true,
    this.supportsTools = true,
    this.supportsReasoning = false,
    this.contextLength,
    this.pricing,
    this.source = CapabilitySource.heuristic,
    this.generationSchema,
  });

  // ---------- геттеры ----------

  /// Короткое имя без префикса владельца: 'vendor/name' -> 'name'.
  String get label {
    final custom = displayName;
    if (custom != null && custom.trim().isNotEmpty) return custom.trim();
    final idx = id.lastIndexOf('/');
    if (idx >= 0 && idx < id.length - 1) return id.substring(idx + 1);
    return id;
  }

  /// Принимает изображения на вход (vision).
  bool get acceptsImages => inputModalities.contains(Modality.image);

  /// Принимает аудио на вход.
  bool get acceptsAudio => inputModalities.contains(Modality.audio);

  /// Принимает видео на вход.
  bool get acceptsVideo => inputModalities.contains(Modality.video);

  /// Мультимодальная ли модель: хоть одна нетекстовая модальность входа.
  bool get isMultimodal => acceptsImages || acceptsAudio || acceptsVideo;

  /// Генератор изображений.
  bool get isImageGenerator => route == GenerationRoute.imageGeneration;

  /// Голосовой realtime-режим.
  bool get isLiveVoice => route == GenerationRoute.liveRealtime;

  /// Обычная чат-модель (текст в ответ).
  bool get isTextChat => route.isChat;

  /// Служебная аудио-модель (TTS или распознавание).
  bool get isAudioUtility =>
      route == GenerationRoute.textToSpeech ||
      route == GenerationRoute.audioTranscription;

  /// Эмбеддинги (не для чата).
  bool get isEmbedding => route == GenerationRoute.embeddings;

  /// Подпись модальностей входа: 'текст · изображения'.
  String get inputLabel => _modalityLabel(inputModalities);

  /// Подпись модальностей выхода.
  String get outputLabel => _modalityLabel(outputModalities);

  /// Короткая сводка для списка моделей: маршрут + модальности + контекст.
  String get subtitle {
    final parts = <String>[route.label];
    final io = inputLabel;
    if (io.isNotEmpty && io != 'текст') parts.add('вход: $io');
    final out = outputLabel;
    if (out.isNotEmpty && out != 'текст') parts.add('выход: $out');
    final ctx = contextLength;
    if (ctx != null && ctx > 0) parts.add('контекст: ${_fmtTokens(ctx)}');
    return parts.join(' · ');
  }

  static String _modalityLabel(Set<Modality> set) =>
      set.isEmpty ? '' : set.map((m) => m.label).join(' · ');

  static String _fmtTokens(int count) {
    if (count >= 1000000) {
      final m = count / 1000000;
      return m == m.roundToDouble() ? '${m.round()}M' : '${m.toStringAsFixed(1)}M';
    }
    if (count >= 1000) {
      final k = count / 1000;
      return k == k.roundToDouble() ? '${k.round()}K' : '${k.toStringAsFixed(1)}K';
    }
    return '$count';
  }

  /// Копия с заменой отдельных полей.
  ModelInfo copyWith({
    String? displayName,
    String? providerId,
    Set<Modality>? inputModalities,
    Set<Modality>? outputModalities,
    GenerationRoute? route,
    bool? supportsStreaming,
    bool? supportsTools,
    bool? supportsReasoning,
    int? contextLength,
    Pricing? pricing,
    CapabilitySource? source,
    GenerationSchema? generationSchema,
  }) {
    return ModelInfo(
      id: id,
      displayName: displayName ?? this.displayName,
      providerId: providerId ?? this.providerId,
      inputModalities: inputModalities ?? this.inputModalities,
      outputModalities: outputModalities ?? this.outputModalities,
      route: route ?? this.route,
      supportsStreaming: supportsStreaming ?? this.supportsStreaming,
      supportsTools: supportsTools ?? this.supportsTools,
      supportsReasoning: supportsReasoning ?? this.supportsReasoning,
      contextLength: contextLength ?? this.contextLength,
      pricing: pricing ?? this.pricing,
      source: source ?? this.source,
      generationSchema: generationSchema ?? this.generationSchema,
    );
  }

  // ---------- сериализация ----------

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (displayName != null) 'displayName': displayName,
        'providerId': providerId,
        'inputModalities': <String>[for (final m in inputModalities) m.name],
        'outputModalities': <String>[for (final m in outputModalities) m.name],
        'route': route.name,
        'supportsStreaming': supportsStreaming,
        'supportsTools': supportsTools,
        'supportsReasoning': supportsReasoning,
        if (contextLength != null) 'contextLength': contextLength,
        if (pricing != null)
          'pricing': <String, dynamic>{
            if (pricing!.inputPerMillion != null)
              'inputPerMillion': pricing!.inputPerMillion,
            if (pricing!.outputPerMillion != null)
              'outputPerMillion': pricing!.outputPerMillion,
            'currency': pricing!.currency,
          },
        'source': source.name,
        if (generationSchema != null)
          'generationSchema': generationSchema!.toJson(),
      };

  /// Безопасный разбор: старые кеши без отдельных ключей (включая
  /// generationSchema) читаются со значениями по умолчанию, битые
  /// имена enum не роняют разбор.
  factory ModelInfo.fromJson(Map<String, dynamic> j) {
    Set<Modality> modalities(Object? raw) {
      final out = <Modality>{};
      if (raw is List) {
        for (final e in raw) {
          final m = Modality.fromName(e?.toString());
          if (m != null) out.add(m);
        }
      }
      return out;
    }

    GenerationRoute routeFrom(Object? raw) {
      final s = (raw as String?)?.trim() ?? '';
      for (final r in GenerationRoute.values) {
        if (r.name == s) return r;
      }
      return GenerationRoute.chatCompletions;
    }

    CapabilitySource sourceFrom(Object? raw) {
      final s = (raw as String?)?.trim() ?? '';
      for (final c in CapabilitySource.values) {
        if (c.name == s) return c;
      }
      return CapabilitySource.heuristic;
    }

    Pricing? pricingFrom(Object? raw) {
      if (raw is! Map) return null;
      final m = Map<String, dynamic>.from(raw);
      final inP = (m['inputPerMillion'] as num?)?.toDouble();
      final outP = (m['outputPerMillion'] as num?)?.toDouble();
      if (inP == null && outP == null) return null;
      return Pricing(
        inputPerMillion: inP,
        outputPerMillion: outP,
        currency: (m['currency'] as String?) ?? 'USD',
      );
    }

    var input = modalities(j['inputModalities']);
    if (input.isEmpty) input = const <Modality>{Modality.text};
    var output = modalities(j['outputModalities']);
    if (output.isEmpty) output = const <Modality>{Modality.text};

    final schemaRaw = j['generationSchema'];
    final schema = schemaRaw is Map
        ? GenerationSchema.fromJson(Map<String, dynamic>.from(schemaRaw))
        : null;

    return ModelInfo(
      id: ((j['id'] as String?) ?? '').trim(),
      displayName: j['displayName'] as String?,
      providerId: (j['providerId'] as String?) ?? '',
      inputModalities: input,
      outputModalities: output,
      route: routeFrom(j['route']),
      supportsStreaming: (j['supportsStreaming'] as bool?) ?? true,
      supportsTools: (j['supportsTools'] as bool?) ?? true,
      supportsReasoning: (j['supportsReasoning'] as bool?) ?? false,
      contextLength: (j['contextLength'] as num?)?.toInt(),
      pricing: pricingFrom(j['pricing']),
      source: sourceFrom(j['source']),
      generationSchema: schema,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ModelInfo && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ModelInfo($id, route: $route)';
}
