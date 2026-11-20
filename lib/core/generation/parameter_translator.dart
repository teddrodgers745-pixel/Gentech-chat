// Copyright (c) 2026 Minkail. All rights reserved.

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
  /// Приводит [rawParams] к формату payload модели [model].
  /// Возвращает новую карту; исходная не меняется.
  static Map<String, dynamic> translate(
    Map<String, dynamic> rawParams,
    ModelInfo model,
  ) {
    final enriched = _enrichRawWithSelected(rawParams, isVideo: model.isVideoGenerator);
    final schema = model.generationSchema;
    if (schema == null) return _normalizeRawTypes(enriched, isImage: model.isImageGenerator);
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
          model.isVideoGenerator &&
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
  static Map<String, dynamic> toImageBody(
    UniversalParams p,
    ModelParameters spec,
  ) {
    _validateCombination(p, spec);
    final out = <String, dynamic>{};
    if (_hasConstraint(spec, 'no aspect_ratio')) {
      final size = _sizeFor(p);
      if (size != null) out[ParamKeys.size] = size;
      if (p.resolution != null) out[ParamKeys.resolution] = p.resolution!;
      _addQuality(out, p, spec);
      return out;
    }
    if (_hasConstraint(spec, 'width/height rejected')) {
      final r = p.aspectRatio;
      if (r != null) out[ParamKeys.aspectRatio] = r;
      if (p.resolution != null) out[ParamKeys.resolution] = p.resolution!;
      _addQuality(out, p, spec);
      return out;
    }
    final ratio = p.aspectRatio ??
        (spec.aspectRatios.isNotEmpty ? spec.aspectRatios.first : null);
    if (ratio != null) out[ParamKeys.aspectRatio] = ratio;
    if (p.size != null) out[ParamKeys.size] = p.size!;
    final res = p.resolution ??
        (spec.resolutions.isNotEmpty ? spec.resolutions.first : null);
    if (res != null) out[ParamKeys.resolution] = res;
    _addQuality(out, p, spec);
    return out;
  }

  /// Тело параметров запроса генерации видео:
  /// `aspect_ratio` — String ("16:9"), `duration` — int, `resolution` — String.
  static Map<String, dynamic> toVideoBody(
    UniversalParams p,
    ModelParameters spec,
  ) {
    _validateCombination(p, spec);
    final out = <String, dynamic>{};
    final defaultRatio =
        spec.aspectRatios.isNotEmpty ? spec.aspectRatios.first : null;
    if (_hasConstraint(spec, 'no aspect_ratio')) {
      final size = _sizeFor(p);
      if (size != null) out[ParamKeys.size] = size;
    } else if (_hasConstraint(spec, 'width/height rejected')) {
      final r = p.aspectRatio ?? defaultRatio;
      if (r != null) out[ParamKeys.aspectRatio] = r;
    } else {
      final r = p.aspectRatio ?? defaultRatio;
      if (r != null) out[ParamKeys.aspectRatio] = r;
      if (p.size != null) out[ParamKeys.size] = p.size!;
    }
    final discDurations = spec.durations?.discrete;
    final defaultDuration = (discDurations != null && discDurations.isNotEmpty)
        ? discDurations.first
        : spec.durations?.min;
    final duration = p.duration ?? defaultDuration;
    if (duration != null) out[ParamKeys.duration] = duration;

    final defaultResolution =
        spec.resolutions.isNotEmpty ? spec.resolutions.first : null;
    final resolution = p.resolution ?? defaultResolution;
    if (resolution != null) out[ParamKeys.resolution] = resolution;

    _addQuality(out, p, spec);
    return out;
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
      if (isHeuristicVid && p.duration != null) {
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

  static String? _sizeFor(UniversalParams p) {
    final s = p.size;
    if (s != null && s.isNotEmpty) return s;
    final r = p.aspectRatio;
    if (r == null || r.isEmpty) return null;
    return _sizeForRatio(r);
  }

  static String _sizeForRatio(String ratio) {
    switch (ratio.trim()) {
      case '16:9':
        return '1792x1024';
      case '9:16':
        return '1024x1792';
      default:
        return '1024x1024';
    }
  }

  static void _addQuality(
    Map<String, dynamic> out,
    UniversalParams p,
    ModelParameters spec,
  ) {
    final q = p.quality ??
        (spec.qualities.isNotEmpty ? spec.qualities.first : null);
    if (q == null) return;
    if (spec.qualities.isNotEmpty && !spec.qualities.contains(q)) return;
    out[ParamKeys.quality] = q;
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
