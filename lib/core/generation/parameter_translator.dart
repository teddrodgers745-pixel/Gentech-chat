// Copyright (c) 2026 Minkail. All rights reserved.

// Частичное исправление: для изображений больше не формируется поле
// resolution, а duration для видео передаётся строкой.
// Полная фильтрация по схеме Polza и передача выбора из панели не исправлены:
// для этого нужны исходники ActiveModelController, ModelCatalogAdapter,
// ModelInfoResolver, ModelInfo, ModelParameters, места создания
// GenerationRequest и пример parameters из каталога Polza.

import '../models/generation_schema.dart';
import '../models/model_info.dart';
import '../models/param_spec.dart';
import 'active_model_controller.dart';
import 'curated_parameter_catalog.dart';
import 'parameter_validation_exception.dart';
import 'user_param_override_store.dart';

/// Универсальные параметры генерации, собранные интерфейсом нейтрально:
/// пропорция (`aspect_ratio` формата "16:9"), длительность (`duration` — int),
/// разрешение (`resolution` — строка), размер холста и качество.
class UniversalParams {
  final String? aspectRatio;
  final int? duration;
  final String? resolution;
  final String? size;
  final String? quality;

  const UniversalParams({
    this.aspectRatio,
    this.duration,
    this.resolution,
    this.size,
    this.quality,
  });

  /// Читает нейтральные параметры из сырой карты запроса (ключи
  /// [ParamKeys] и альтернативные имена ключей), подставляя выбранные в UI
  /// значения из [ActiveModelController] как фоллбэк, если поле не было
  /// передано в [raw].
  factory UniversalParams.fromRaw(
    Map<String, dynamic> raw, {
    bool useControllerFallback = true,
  }) {
    final rawRatio = _aspectRatio(
      raw[ParamKeys.aspectRatio] ?? raw['aspectRatio'] ?? raw['ratio'],
    );
    final rawDuration = _int(
      raw[ParamKeys.duration] ?? raw['seconds'] ?? raw['duration_seconds'],
    );
    final rawResolution = _string(
      raw[ParamKeys.resolution] ?? raw['image_resolution'],
    );
    final rawSize = _string(raw[ParamKeys.size]);
    final rawQuality = _string(raw[ParamKeys.quality]);

    return UniversalParams(
      aspectRatio: rawRatio ??
          (useControllerFallback
              ? _aspectRatio(ActiveModelController.selectedAspectRatio)
              : null),
      duration: rawDuration ??
          (useControllerFallback
              ? ActiveModelController.selectedDuration
              : null),
      resolution: rawResolution ??
          (useControllerFallback
              ? _string(ActiveModelController.selectedResolution)
              : null),
      size: rawSize,
      quality: rawQuality ??
          (useControllerFallback
              ? _string(ActiveModelController.selectedQuality)
              : null),
    );
  }

  static String? _string(Object? v) {
    if (v == null) return null;
    final t = v.toString().trim();
    return t.isEmpty ? null : t;
  }

  static String? _aspectRatio(Object? v) {
    final s = _string(v);
    if (s == null) return null;
    // Формат "16:9", "9:16", "1:1" и т.п.
    final m = RegExp(r'^(\d+)\s*[:/]\s*(\d+)$').firstMatch(s);
    if (m != null) return '${m.group(1)}:${m.group(2)}';
    return s;
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) {
      final clean = v.trim();
      final direct = int.tryParse(clean);
      if (direct != null) return direct;
      final match = RegExp(r'(\d+)').firstMatch(clean);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }
}

/// Нормализация параметров генерации под конкретную модель.
abstract final class ParameterTranslator {
  static bool _isVideoGenerator(ModelInfo model) =>
      model.outputModalities.contains(Modality.video) ||
      model.route == GenerationRoute.asyncJob;

  /// Приводит [rawParams] к формату payload модели [model].
  /// Возвращает новую карту; исходная не меняется.
  static Map<String, dynamic> translate(
    Map<String, dynamic> rawParams,
    ModelInfo model,
  ) {
    final isVideo = _isVideoGenerator(model);
    final enriched = _enrichRawWithSelected(rawParams, isVideo: isVideo);
    final schema = model.generationSchema;
    if (schema == null) {
      return _normalizeRawTypes(enriched, isImage: model.isImageGenerator);
    }
    final clean = schema.sanitize(enriched);
    final result = switch (schema.payloadStyle) {
      PayloadStyle.sizeOnly => _sizeOnly(clean, schema),
      PayloadStyle.openAiSora => _sora(clean, schema),
      PayloadStyle.openRouterChatConfig => _openRouterConfig(clean),
      PayloadStyle.standardFlat => _standardFlat(clean, model),
    };
    // Если схема отфильтровала явно выбранные пользователем параметры
    // (aspect_ratio, duration, resolution), сохраняем их в корректных типах.
    if (schema.payloadStyle == PayloadStyle.standardFlat) {
      final p = UniversalParams.fromRaw(enriched);
      if (p.aspectRatio != null && !result.containsKey(ParamKeys.aspectRatio)) {
        result[ParamKeys.aspectRatio] = p.aspectRatio!;
      }
      if (p.duration != null &&
          isVideo &&
          !result.containsKey(ParamKeys.duration)) {
        result[ParamKeys.duration] = p.duration!;
      }
      if (p.resolution != null &&
          !result.containsKey(ParamKeys.resolution) &&
          !result.containsKey('image_resolution')) {
        result[ParamKeys.resolution] = p.resolution!;
      }
    }
    return result;
  }

  static Map<String, dynamic> _enrichRawWithSelected(
    Map<String, dynamic> rawParams, {
    required bool isVideo,
  }) {
    final out = Map<String, dynamic>.of(rawParams);
    final ratio = UniversalParams._aspectRatio(
      out[ParamKeys.aspectRatio] ?? ActiveModelController.selectedAspectRatio,
    );
    if (ratio != null) out[ParamKeys.aspectRatio] = ratio;

    final dur = UniversalParams._int(
      out[ParamKeys.duration] ??
          (isVideo ? ActiveModelController.selectedDuration : null),
    );
    if (dur != null) out[ParamKeys.duration] = dur;

    final res = UniversalParams._string(
      out[ParamKeys.resolution] ??
          out['image_resolution'] ??
          ActiveModelController.selectedResolution,
    );
    if (res != null) out[ParamKeys.resolution] = res;

    final qual = UniversalParams._string(
      out[ParamKeys.quality] ?? ActiveModelController.selectedQuality,
    );
    if (qual != null) out[ParamKeys.quality] = qual;
    return out;
  }

  static Map<String, dynamic> _normalizeRawTypes(
    Map<String, dynamic> params, {
    bool isImage = false,
  }) {
    final out = <String, dynamic>{};
    final p = UniversalParams.fromRaw(params);
    if (p.aspectRatio != null) out[ParamKeys.aspectRatio] = p.aspectRatio!;
    if (!isImage && p.duration != null) out[ParamKeys.duration] = p.duration!;
    if (p.resolution != null) out[ParamKeys.resolution] = p.resolution!;
    if (p.size != null) out[ParamKeys.size] = p.size!;
    if (p.quality != null) out[ParamKeys.quality] = p.quality!;
    return out;
  }

  // ---------- каталог параметров (приоритет user > curated) ----------

  static Future<ModelParameters?> resolveParams(
    String modelId,
    UserParamOverrideStore ov,
  ) async {
    final user = await ov.load(modelId);
    if (user != null) return user;
    return CuratedParameterCatalog.byId(modelId);
  }

  /// Тело параметров REST-запроса генерации изображения.
  ///
  /// Поля, которых нет в схеме модели ([spec]), не отправляются.
  /// Значения, которых нет в списке допустимых, заменяются на дефолт
  /// (первый элемент каталога) — не первое попавшееся значение контроллера.
  static Map<String, dynamic> toImageBody(
    UniversalParams p,
    ModelParameters spec,
  ) {
    _validateCombination(p, spec);
    final out = <String, dynamic>{};

    final acceptsAspectRatio = !_hasConstraint(spec, 'no aspect_ratio');
    final acceptsSize = !_hasConstraint(spec, 'width/height rejected');

    if (acceptsAspectRatio && spec.aspectRatios.isNotEmpty) {
      final raw = p.aspectRatio;
      final chosen = (raw != null && spec.aspectRatios.contains(raw))
          ? raw
          : spec.aspectRatios.first;
      out[ParamKeys.aspectRatio] = chosen;
    }

    if (acceptsSize && spec.sizes.isNotEmpty) {
      final raw = p.size;
      final chosen = (raw != null && spec.sizes.contains(raw))
          ? raw
          : spec.sizes.first;
      out[ParamKeys.size] = chosen;
    }

    if (spec.resolutions.isNotEmpty) {
      final raw = p.resolution;
      final chosen = (raw != null && spec.resolutions.contains(raw))
          ? raw
          : spec.resolutions.first;
      out[ParamKeys.resolution] = chosen;
    }

    _addQuality(out, p, spec);
    return out;
  }

  /// Тело параметров запроса генерации видео:
  /// `aspect_ratio` — String ("16:9"), `duration` — int, `resolution` — String.
  ///
  /// Поля, которых нет в схеме модели, не отправляются; duration берётся
  /// из `defaultValue` каталога (у Seedance это 15), а не из первого
  /// элемента списка.
  static Map<String, dynamic> toVideoBody(
    UniversalParams p,
    ModelParameters spec,
  ) {
    _validateCombination(p, spec);
    final out = <String, dynamic>{};

    final acceptsAspectRatio = !_hasConstraint(spec, 'no aspect_ratio');
    final acceptsSize = !_hasConstraint(spec, 'width/height rejected');

    if (acceptsAspectRatio && spec.aspectRatios.isNotEmpty) {
      final raw = p.aspectRatio;
      final chosen = (raw != null && spec.aspectRatios.contains(raw))
          ? raw
          : spec.aspectRatios.first;
      out[ParamKeys.aspectRatio] = chosen;
    }

    if (acceptsSize && spec.sizes.isNotEmpty) {
      final raw = p.size;
      final chosen = (raw != null && spec.sizes.contains(raw))
          ? raw
          : spec.sizes.first;
      out[ParamKeys.size] = chosen;
    }

    final durationRange = spec.durations;
    final defaultDuration = _defaultDuration(durationRange);
    final current = p.duration;
    final durationChoice =
        (current != null && _isDurationValid(current, durationRange))
            ? current
            : defaultDuration;
    if (durationChoice != null) {
      out[ParamKeys.duration] = durationChoice;
    }

    if (spec.resolutions.isNotEmpty) {
      final raw = p.resolution;
      final chosen = (raw != null && spec.resolutions.contains(raw))
          ? raw
          : spec.resolutions.first;
      out[ParamKeys.resolution] = chosen;
    }

    _addQuality(out, p, spec);
    return out;
  }

  /// Дефолт длительности из каталога: `defaultValue` (Seedance = 15),
  /// иначе первый дискретный элемент, иначе min/max.
  static int? _defaultDuration(DurationRange? range) {
    if (range == null) return null;
    final dv = range.defaultValue;
    if (dv != null) return dv;
    final disc = range.discrete;
    if (disc != null && disc.isNotEmpty) return disc.first;
    return range.min ?? range.max;
  }

  /// Допустима ли длительность [value] в диапазоне [range].
  /// `range == null` — ограничения нет, значение допустимо.
  static bool _isDurationValid(int value, DurationRange? range) {
    if (range == null) return true;
    final disc = range.discrete;
    if (disc != null && disc.isNotEmpty) return disc.contains(value);
    final min = range.min;
    final max = range.max;
    if (min != null && value < min) return false;
    if (max != null && value > max) return false;
    return true;
  }

  /// Точка входа для исполнителей: собирает и приводит параметры
  /// `aspect_ratio` (String), `duration` (int), `resolution` (String).
  static Future<Map<String, dynamic>> translateWithCatalog({
    required String modelId,
    required Map<String, dynamic> rawParams,
    required Map<String, dynamic> Function() fallback,
  }) async {
    var spec = ActiveModelController.mergedParamsFor(modelId);
    if (spec != null && spec.hasAny) {
      ModelParameters? user;
      try {
        user = await userParamOverrideStore.load(modelId);
      } catch (_) {
        user = null;
      }
      if (user != null && user.hasAny) {
        spec = _userOverBase(user, spec);
      }
    } else {
      if (!CuratedParameterCatalog.isLoaded) {
        await CuratedParameterCatalog.load();
      }
      spec = await resolveParams(modelId, userParamOverrideStore);
    }

    final isHeuristicVid = ActiveModelController.isHeuristicVideo(modelId);
    final p = UniversalParams.fromRaw(rawParams, useControllerFallback: true);

    if (spec == null || !spec.hasAny) {
      final fb = Map<String, dynamic>.of(fallback());
      if (p.aspectRatio != null &&
          !fb.containsKey(ParamKeys.aspectRatio) &&
          !fb.containsKey(ParamKeys.size)) {
        fb[ParamKeys.aspectRatio] = p.aspectRatio!;
      }
      // Длительность: выбранное пользователем значение ВСЕГДА доходит
      // до тела запроса и приходит int (строки '5'/'10' приводим к int).
      if (p.duration != null) {
        fb[ParamKeys.duration] = p.duration!;
      } else if (fb[ParamKeys.duration] != null) {
        final dInt = UniversalParams._int(fb[ParamKeys.duration]);
        if (dInt != null) fb[ParamKeys.duration] = dInt;
      }
      if (p.resolution != null &&
          !fb.containsKey(ParamKeys.resolution) &&
          !fb.containsKey('image_resolution')) {
        fb[ParamKeys.resolution] = p.resolution!;
      }
      if (p.quality != null && !fb.containsKey(ParamKeys.quality)) {
        fb[ParamKeys.quality] = p.quality!;
      }
      return fb;
    }

    final durations = spec.durations;
    final isVideo = spec.type == 'video' ||
        (durations != null && !durations.isEmpty) ||
        p.duration != null ||
        isHeuristicVid;
    final body = isVideo ? toVideoBody(p, spec) : toImageBody(p, spec);
    if (body.isEmpty) return fallback();
    return body;
  }

  /// Тело `input` для Polza Media API (POST /v1/media).
  ///
  /// Параметры генерации лежат внутри объекта `input`. Этот метод
  /// нормализует имена и типы, но не фильтрует поля по схеме модели —
  /// фильтрация выполняется в [toImageBody]/[toVideoBody] до вызова.
  static Map<String, dynamic> toPolzaMediaInput(
    String prompt,
    Map<String, dynamic> translated, {
    bool isVideo = false,
  }) {
    final out = <String, dynamic>{'prompt': prompt};
    final ratio = UniversalParams._aspectRatio(
      translated[ParamKeys.aspectRatio] ?? translated['aspect_ratio'],
    );
    if (ratio != null) out['aspect_ratio'] = ratio;

    if (isVideo) {
      final duration = UniversalParams._int(
        translated[ParamKeys.duration] ??
            translated['seconds'] ??
            translated['duration_seconds'],
      );
      if (duration != null) out['duration'] = duration.toString();

      final resolution = UniversalParams._string(
        translated[ParamKeys.resolution],
      );
      if (resolution != null) out['resolution'] = resolution;
    } else {
      final resolution = UniversalParams._string(
        translated['image_resolution'] ?? translated[ParamKeys.resolution],
      );
      if (resolution != null && _isImageResolutionTier(resolution)) {
        out['image_resolution'] = resolution;
      }
    }

    final quality = UniversalParams._string(translated[ParamKeys.quality]);
    if (quality != null) out['quality'] = quality;

    final size = UniversalParams._string(translated[ParamKeys.size]);
    if (size != null) out['size'] = size;

    return out;
  }

  /// Разрешение вида «1K»/«2K»/«4K» — это image_resolution, а не
  /// video-разрешение вида «720p»/«1080p».
  static bool _isImageResolutionTier(String value) =>
      RegExp(r'^\d+(\.\d+)?K$', caseSensitive: false)
          .hasMatch(value.trim());

  static ModelParameters _userOverBase(
    ModelParameters user,
    ModelParameters base,
  ) {
    final ud = user.durations;
    final bd = base.durations;
    final constraints = <String>[...base.constraints];
    for (final c in user.constraints) {
      if (!constraints.contains(c)) constraints.add(c);
    }
    return ModelParameters(
      aspectRatios: user.aspectRatios.isNotEmpty
          ? List<String>.of(user.aspectRatios)
          : List<String>.of(base.aspectRatios),
      durations: (ud != null && !ud.isEmpty) ? ud : bd,
      resolutions: user.resolutions.isNotEmpty
          ? List<String>.of(user.resolutions)
          : List<String>.of(base.resolutions),
      sizes: user.sizes.isNotEmpty
          ? List<String>.of(user.sizes)
          : List<String>.of(base.sizes),
      qualities: user.qualities.isNotEmpty
          ? List<String>.of(user.qualities)
          : List<String>.of(base.qualities),
      constraints: constraints,
      type: (user.type?.trim().isNotEmpty ?? false) ? user.type : base.type,
      confidence: 'user',
      isUserDefined: true,
    );
  }

  // ---------- правила ограничений ----------

  static bool _hasConstraint(ModelParameters spec, String needle) {
    final n = needle.toLowerCase();
    for (final c in spec.constraints) {
      if (c.toLowerCase().contains(n)) return true;
    }
    return false;
  }

  static void _validateCombination(UniversalParams p, ModelParameters spec) {
    if (!_hasConstraint(spec, '1080p only with 6s')) return;
    final res = (p.resolution ?? '').trim().toLowerCase();
    if (res != '1080p') return;
    final d = p.duration;
    if (d != null && d != 6) {
      throw const ParameterValidationException(
        'Для этой модели 1080p доступен только при длительности 6 секунд. '
        'Выберите другое разрешение либо длительность 6 с.',
      );
    }
  }

  /// Качество: только если модель его перечисляет.
  /// Если `p.quality` не входит в список — берём первый допустимый
  /// (дефолт определяется значением каталога, а не контроллером).
  static void _addQuality(
    Map<String, dynamic> out,
    UniversalParams p,
    ModelParameters spec,
  ) {
    if (spec.qualities.isEmpty) return;
    final raw = p.quality;
    final chosen = (raw != null && spec.qualities.contains(raw))
        ? raw
        : spec.qualities.first;
    out[ParamKeys.quality] = chosen;
  }

  // ---------- стили payload (прежний путь по GenerationSchema) ----------

  static Map<String, dynamic> _sizeOnly(
    Map<String, dynamic> params,
    GenerationSchema schema,
  ) {
    final size = _resolveSize(params, schema);
    return <String, dynamic>{
      if (size.isNotEmpty) ParamKeys.size: size,
    };
  }

  static Map<String, dynamic> _sora(
    Map<String, dynamic> params,
    GenerationSchema schema,
  ) {
    final out = <String, dynamic>{};
    final size = _resolveSize(params, schema);
    if (size.isNotEmpty) out[ParamKeys.size] = size;
    final seconds = _asInt(params[ParamKeys.duration]);
    if (seconds != null) out['seconds'] = seconds;
    return out;
  }

  static Map<String, dynamic> _openRouterConfig(Map<String, dynamic> params) {
    final cfg = <String, dynamic>{};
    void take(String key) {
      final v = params[key];
      if (v is String && v.trim().isNotEmpty) {
        cfg[key] = v.trim();
      } else if (v is int) {
        cfg[key] = v;
      }
    }

    take(ParamKeys.aspectRatio);
    take(ParamKeys.quality);
    take(ParamKeys.size);
    return <String, dynamic>{'image_config': cfg};
  }

  static Map<String, dynamic> _standardFlat(
    Map<String, dynamic> params,
    ModelInfo model,
  ) {
    final out = <String, dynamic>{};
    final ratio = UniversalParams._aspectRatio(params[ParamKeys.aspectRatio]);
    if (ratio != null && ratio.isNotEmpty) {
      out[ParamKeys.aspectRatio] = ratio;
    }
    final duration = _asInt(params[ParamKeys.duration]);
    if (duration != null) out[ParamKeys.duration] = duration;
    final resolution = params[ParamKeys.resolution];
    if (resolution is String && resolution.trim().isNotEmpty) {
      final key =
          model.isImageGenerator ? 'image_resolution' : ParamKeys.resolution;
      out[key] = resolution.trim();
    }
    return out;
  }

  // ---------- помощники ----------

  static String _resolveSize(
    Map<String, dynamic> params,
    GenerationSchema schema,
  ) {
    final ratio = params[ParamKeys.aspectRatio];
    if (ratio is String && ratio.trim().isNotEmpty) {
      final spec = _specFor(schema, ParamKeys.aspectRatio);
      final opt = _optionOf(spec, ratio.trim());
      if (opt != null) {
        final mapped = opt.mappedSize?.trim();
        if (mapped != null && mapped.isNotEmpty) return mapped;
        return opt.value;
      }
    }
    final size = params[ParamKeys.size];
    if (size is String && size.trim().isNotEmpty) return size.trim();
    return '';
  }

  static ParamSpec? _specFor(GenerationSchema schema, String key) {
    for (final s in schema.specs) {
      if (s.key == key) return s;
    }
    return null;
  }

  static ParamOption? _optionOf(ParamSpec? spec, String value) {
    if (spec == null) return null;
    for (final o in spec.options) {
      if (o.value == value) return o;
    }
    return null;
  }

  static int? _asInt(Object? value) => UniversalParams._int(value);
}
