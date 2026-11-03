// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/generation_schema.dart';
import '../models/model_info.dart';

/// Каталог правил параметров генерации для известных семейств моделей.
///
/// По подстрокам идентификатора модели (lowercase) и модальности вывода
/// возвращает готовую [GenerationSchema]: стиль сборки payload и список
/// параметров (пропорции, размер холста, длительность, разрешение).
/// Схема подсказывает интерфейсу, какие варианты показывать, и задаёт
/// значения по умолчанию. Неизвестные модели генерации изображений и
/// видео получают нейтральный фоллбэк; для остальных модальностей
/// возвращается null — схем параметров у них нет.
abstract final class CuratedParameterSchemas {
  /// Главная точка входа. null — правило для модели не найдено.
  static GenerationSchema? resolve(
    String providerId,
    String modelId,
    Modality outputModality,
  ) {
    final id = modelId.toLowerCase().trim();
    if (id.isEmpty) return null;
    final provider = providerId.trim().toLowerCase();

    if (outputModality == Modality.image) return _image(id, provider);
    if (outputModality == Modality.video) return _video(id);
    return null;
  }

  // ---------- изображения ----------

  static GenerationSchema? _image(String id, String provider) {
    if (id.contains('dall-e-3')) return _dalle3;
    if (id.contains('sdxl') || id.contains('stable-diffusion')) return _sdxl;
    if (id.contains('qwen')) return _qwenImage;
    if (id.contains('flux')) return _flux(provider);
    return _imageFallback;
  }

  /// DALL-E 3: провайдер понимает только поле size — размер выводится
  /// из выбранной пропорции через mappedSize.
  static const GenerationSchema _dalle3 = GenerationSchema(
    payloadStyle: PayloadStyle.sizeOnly,
    specs: <ParamSpec>[
      ParamSpec(
        key: ParamKeys.aspectRatio,
        label: 'Пропорция',
        type: ParamType.enumChoice,
        defaultValue: '1:1',
        options: <ParamOption>[
          ParamOption(value: '1:1', label: '1:1', mappedSize: '1024x1024'),
          ParamOption(value: '16:9', label: '16:9', mappedSize: '1792x1024'),
          ParamOption(value: '9:16', label: '9:16', mappedSize: '1024x1792'),
        ],
      ),
    ],
  );

  /// SDXL / Stable Diffusion: только размер холста, без пропорций.
  static const GenerationSchema _sdxl = GenerationSchema(
    payloadStyle: PayloadStyle.sizeOnly,
    specs: <ParamSpec>[
      ParamSpec(
        key: ParamKeys.size,
        label: 'Размер',
        type: ParamType.enumChoice,
        defaultValue: '1024x1024',
        options: <ParamOption>[
          ParamOption(value: '512x512', label: '512×512'),
          ParamOption(value: '1024x1024', label: '1024×1024'),
        ],
      ),
    ],
  );

  static const List<String> _qwenRatios = <String>[
    '1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3', '21:9',
  ];

  static const List<String> _fluxRatios = <String>[
    '1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3',
  ];

  static const List<String> _imageFallbackRatios = <String>[
    '1:1', '16:9', '9:16',
  ];

  /// Qwen-изображения: плоский payload, широкая сетка пропорций.
  static GenerationSchema get _qwenImage => GenerationSchema(
        payloadStyle: PayloadStyle.standardFlat,
        specs: <ParamSpec>[
          _ratioSpec(_ratioOptions(_qwenRatios), '1:1'),
        ],
      );

  /// Flux: OpenRouter принимает конфиг внутри chat/completions,
  /// остальные провайдеры — плоские поля. У RouterAI и Polza
  /// дополнительно доступно разрешение (1K/2K).
  static GenerationSchema _flux(String provider) {
    final style = provider == 'openrouter'
        ? PayloadStyle.openRouterChatConfig
        : PayloadStyle.standardFlat;
    final specs = <ParamSpec>[_ratioSpec(_ratioOptions(_fluxRatios), '1:1')];
    if (provider == 'routerai' || provider == 'polza') {
      specs.add(_resolutionSpec(const <String>['1K', '2K'], '1K'));
    }
    return GenerationSchema(payloadStyle: style, specs: specs);
  }

  /// Фоллбэк для неизвестных генераторов изображений.
  static GenerationSchema get _imageFallback => GenerationSchema(
        payloadStyle: PayloadStyle.standardFlat,
        specs: <ParamSpec>[
          _ratioSpec(_ratioOptions(_imageFallbackRatios), '1:1'),
        ],
      );

  // ---------- видео ----------

  static GenerationSchema? _video(String id) {
    if (id.contains('sora')) return _sora;
    if (id.contains('kling')) return _kling;
    if (id.contains('wan')) return _wan;
    if (id.contains('veo')) return _veo;
    if (id.contains('seedance')) return _seedance;
    return _videoFallback;
  }

  /// Sora: параметры вложены в собственный блок запроса OpenAI.
  static const GenerationSchema _sora = GenerationSchema(
    payloadStyle: PayloadStyle.openAiSora,
    specs: <ParamSpec>[
      ParamSpec(
        key: ParamKeys.aspectRatio,
        label: 'Пропорция',
        type: ParamType.enumChoice,
        defaultValue: '16:9',
        options: <ParamOption>[
          ParamOption(value: '16:9', label: '16:9', mappedSize: '1280x720'),
          ParamOption(value: '9:16', label: '9:16', mappedSize: '720x1280'),
        ],
      ),
      ParamSpec(
        key: ParamKeys.duration,
        label: 'Длительность',
        type: ParamType.intChoice,
        defaultValue: '4',
        options: <ParamOption>[
          ParamOption(value: '4', label: '4 с'),
          ParamOption(value: '8', label: '8 с'),
          ParamOption(value: '12', label: '12 с'),
          ParamOption(value: '16', label: '16 с'),
          ParamOption(value: '20', label: '20 с'),
        ],
      ),
    ],
  );

  static const GenerationSchema _kling = GenerationSchema(
    payloadStyle: PayloadStyle.standardFlat,
    specs: <ParamSpec>[
      ParamSpec(
        key: ParamKeys.aspectRatio,
        label: 'Пропорция',
        type: ParamType.enumChoice,
        defaultValue: '16:9',
        options: <ParamOption>[
          ParamOption(value: '16:9', label: '16:9'),
          ParamOption(value: '9:16', label: '9:16'),
          ParamOption(value: '1:1', label: '1:1'),
        ],
      ),
      ParamSpec(
        key: ParamKeys.duration,
        label: 'Длительность',
        type: ParamType.intChoice,
        defaultValue: '5',
        options: <ParamOption>[
          ParamOption(value: '5', label: '5 с'),
          ParamOption(value: '10', label: '10 с'),
        ],
      ),
    ],
  );

  static GenerationSchema get _wan => GenerationSchema(
        payloadStyle: PayloadStyle.standardFlat,
        specs: <ParamSpec>[
          _ratioSpec(
            _ratioOptions(const <String>['16:9', '9:16', '1:1', '4:3', '3:4']),
            '16:9',
          ),
          _durationSpec(const <int>[5, 10]),
          _resolutionSpec(const <String>['720p', '1080p'], '720p'),
        ],
      );

  static GenerationSchema get _veo => GenerationSchema(
        payloadStyle: PayloadStyle.standardFlat,
        specs: <ParamSpec>[
          _ratioSpec(_ratioOptions(const <String>['16:9', '9:16']), '16:9'),
          _resolutionSpec(const <String>['720p', '1080p'], '720p'),
          // Фиксированная длительность: в payload уходит, в интерфейсе скрыта.
          _durationSpec(const <int>[8], def: '8', hidden: true),
        ],
      );

  static GenerationSchema get _seedance => GenerationSchema(
        payloadStyle: PayloadStyle.standardFlat,
        specs: <ParamSpec>[
          _ratioSpec(
            _ratioOptions(const <String>['16:9', '9:16', '1:1']),
            '16:9',
          ),
          _durationSpec(const <int>[8], def: '8', hidden: true),
        ],
      );

  /// Фоллбэк для неизвестных видео-моделей.
  static GenerationSchema get _videoFallback => GenerationSchema(
        payloadStyle: PayloadStyle.standardFlat,
        specs: <ParamSpec>[
          _ratioSpec(_ratioOptions(const <String>['16:9', '9:16']), '16:9'),
          _durationSpec(const <int>[5, 10]),
        ],
      );

  // ---------- помощники сборки ----------

  static List<ParamOption> _ratioOptions(
    List<String> values, {
    Map<String, String> sizes = const <String, String>{},
  }) =>
      <ParamOption>[
        for (final v in values)
          ParamOption(value: v, label: v, mappedSize: sizes[v]),
      ];

  static ParamSpec _ratioSpec(List<ParamOption> options, String def) =>
      ParamSpec(
        key: ParamKeys.aspectRatio,
        label: 'Пропорция',
        type: ParamType.enumChoice,
        options: options,
        defaultValue: def,
      );

  static ParamSpec _durationSpec(
    List<int> seconds, {
    String def = '',
    bool hidden = false,
  }) {
    final d = def.isEmpty ? '${seconds.first}' : def;
    return ParamSpec(
      key: ParamKeys.duration,
      label: 'Длительность',
      type: ParamType.intChoice,
      hidden: hidden,
      options: <ParamOption>[
        for (final v in seconds) ParamOption(value: '$v', label: '$v с'),
      ],
      defaultValue: d,
    );
  }

  static ParamSpec _resolutionSpec(List<String> values, String def) =>
      ParamSpec(
        key: ParamKeys.resolution,
        label: 'Разрешение',
        type: ParamType.enumChoice,
        options: <ParamOption>[
          for (final v in values) ParamOption(value: v, label: v),
        ],
        defaultValue: def,
      );
}
