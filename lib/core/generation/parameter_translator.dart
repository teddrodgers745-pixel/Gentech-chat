// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/generation_schema.dart';
import '../models/model_info.dart';
import '../models/param_spec.dart';
import 'curated_parameter_catalog.dart';
import 'parameter_validation_exception.dart';
import 'user_param_override_store.dart';

/// Универсальные параметры генерации, собранные интерфейсом нейтрально:
/// пропорция, длительность, разрешение, размер холста и качество.
/// Переводятся в формат конкретной модели методами
/// [ParameterTranslator.toImageBody] / [ParameterTranslator.toVideoBody]
/// по её [ModelParameters].
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
  /// [ParamKeys]); пустые и нестроковые значения считаются отсутствующими.
  factory UniversalParams.fromRaw(Map<String, dynamic> raw) {
    return UniversalParams(
      aspectRatio: _string(raw[ParamKeys.aspectRatio]),
      duration: _int(raw[ParamKeys.duration]),
      resolution: _string(raw[ParamKeys.resolution]),
      size: _string(raw[ParamKeys.size]),
      quality: _string(raw[ParamKeys.quality]),
    );
  }

  static String? _string(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }
}

/// Нормализация параметров генерации под конкретную модель.
///
/// Два уровня:
///  1. [translateWithCatalog] — курированный каталог
///     ([CuratedParameterCatalog]) и пользовательский override
///     ([UserParamOverrideStore], приоритет user > curated) с правилами
///     ограничений модели ([ModelParameters.constraints]);
///  2. [translate] — прежний путь по [GenerationSchema] модели;
///     используется как fallback, когда модель неизвестна каталогу.
abstract final class ParameterTranslator {
  /// Приводит [rawParams] к формату payload модели [model].
  /// Возвращает новую карту; исходная не меняется.
  static Map<String, dynamic> translate(
    Map<String, dynamic> rawParams,
    ModelInfo model,
  ) {
    final schema = model.generationSchema;
    if (schema == null) return rawParams;
    final clean = schema.sanitize(rawParams);
    return switch (schema.payloadStyle) {
      PayloadStyle.sizeOnly => _sizeOnly(clean, schema),
      PayloadStyle.openAiSora => _sora(clean, schema),
      PayloadStyle.openRouterChatConfig => _openRouterConfig(clean),
      PayloadStyle.standardFlat => _standardFlat(clean, model),
    };
  }

  // ---------- каталог параметров (приоритет user > curated) ----------

  /// Параметры модели: сначала override пользователя, затем курированный
  /// каталог; null — модель неизвестна ни там, ни там.
  ///
  /// Параметр [cat] сохранён в сигнатуре по контракту этапа: каталог
  /// является статическим ([CuratedParameterCatalog.load]/[CuratedParameterCatalog.byId]),
  /// поэтому внутри используется статический доступ.
  static Future<ModelParameters?> resolveParams(
    String modelId,
    CuratedParameterCatalog cat,
    UserParamOverrideStore ov,
  ) async {
    final user = await ov.load(modelId);
    if (user != null) return user;
    return CuratedParameterCatalog.byId(modelId);
  }

  /// Тело параметров REST-запроса генерации изображения.
  ///
  /// Правила по ограничениям модели:
  ///  - 'no aspect_ratio' — провайдер понимает только size: пропорция
  ///    конвертируется в размер холста (16:9 -> 1792x1024,
  ///    9:16 -> 1024x1792, 1:1 -> 1024x1024);
  ///  - 'width/height rejected' — отправляется только aspect_ratio;
  ///  - '1080p only with 6s' — проверка комбинации, иначе
  ///    [ParameterValidationException].
  static Map<String, dynamic> toImageBody(
    UniversalParams p,
    ModelParameters spec,
  ) {
    _validateCombination(p, spec);
    final out = <String, dynamic>{};
    if (_hasConstraint(spec, 'no aspect_ratio')) {
      final size = _sizeFor(p);
      if (size != null) out[ParamKeys.size] = size;
      _addQuality(out, p, spec);
      return out;
    }
    if (_hasConstraint(spec, 'width/height rejected')) {
      final r = p.aspectRatio;
      if (r != null) out[ParamKeys.aspectRatio] = r;
      return out;
    }
    if (p.aspectRatio != null) out[ParamKeys.aspectRatio] = p.aspectRatio!;
    if (p.size != null) out[ParamKeys.size] = p.size!;
    if (p.resolution != null) out[ParamKeys.resolution] = p.resolution!;
    _addQuality(out, p, spec);
    return out;
  }

  /// Тело параметров запроса генерации видео (те же правила ограничений,
  /// плюс duration/resolution/quality).
  static Map<String, dynamic> toVideoBody(
    UniversalParams p,
    ModelParameters spec,
  ) {
    _validateCombination(p, spec);
    final out = <String, dynamic>{};
    if (_hasConstraint(spec, 'no aspect_ratio')) {
      final size = _sizeFor(p);
      if (size != null) out[ParamKeys.size] = size;
    } else if (_hasConstraint(spec, 'width/height rejected')) {
      // Только aspect_ratio: размерные поля не отправляются вовсе.
      final r = p.aspectRatio;
      if (r != null) out[ParamKeys.aspectRatio] = r;
      return out;
    } else {
      if (p.aspectRatio != null) out[ParamKeys.aspectRatio] = p.aspectRatio!;
      if (p.size != null) out[ParamKeys.size] = p.size!;
    }
    if (p.duration != null) out[ParamKeys.duration] = p.duration!;
    if (p.resolution != null) out[ParamKeys.resolution] = p.resolution!;
    _addQuality(out, p, spec);
    return out;
  }

  /// Точка входа для исполнителей: если модель известна каталогу
  /// (user override либо curated), тело собирается по правилам
  /// ограничений; если универсальные параметры пусты или модель
  /// неизвестна — используется [fallback] (прежнее поведение).
  static Future<Map<String, dynamic>> translateWithCatalog({
    required String modelId,
    required Map<String, dynamic> rawParams,
    required Map<String, dynamic> Function() fallback,
  }) async {
    if (!CuratedParameterCatalog.isLoaded) {
      await CuratedParameterCatalog.load();
    }
    final spec = await resolveParams(
      modelId,
      CuratedParameterCatalog,
      userParamOverrideStore,
    );
    if (spec == null || !spec.hasAny) return fallback();
    final p = UniversalParams.fromRaw(rawParams);
    final durations = spec.durations;
    final isVideo = durations != null && !durations.isEmpty;
    final body = isVideo ? toVideoBody(p, spec) : toImageBody(p, spec);
    if (body.isEmpty) return fallback();
    return body;
  }

  // ---------- правила ограничений ----------

  /// Есть ли у модели ограничение, содержащее [needle] (без регистра).
  static bool _hasConstraint(ModelParameters spec, String needle) {
    final n = needle.toLowerCase();
    for (final c in spec.constraints) {
      if (c.toLowerCase().contains(n)) return true;
    }
    return false;
  }

  /// Правило '1080p only with 6s': разрешение 1080p допустимо только
  /// при явно заданной длительности 6 секунд.
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

  /// Размер холста для тела: явный size пользователя, иначе пропорция,
  /// конвертированная по правилу 'no aspect_ratio'; null — не задано.
  static String? _sizeFor(UniversalParams p) {
    final s = p.size;
    if (s != null && s.isNotEmpty) return s;
    final r = p.aspectRatio;
    if (r == null || r.isEmpty) return null;
    return _sizeForRatio(r);
  }

  /// 16:9 -> 1792x1024, 9:16 -> 1024x1792, 1:1 и прочее -> 1024x1024.
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

  /// Качество уходит в тело, только если модель его заявляет
  /// (либо список качеств неизвестен).
  static void _addQuality(
    Map<String, dynamic> out,
    UniversalParams p,
    ModelParameters spec,
  ) {
    final q = p.quality;
    if (q == null) return;
    if (spec.qualities.isNotEmpty && !spec.qualities.contains(q)) return;
    out[ParamKeys.quality] = q;
  }

  // ---------- стили payload (прежний путь по GenerationSchema) ----------

  /// sizeOnly: единственное поле `size` из mappedSize пропорции либо
  /// из значения параметра size. Ключ aspect_ratio не отправляется.
  static Map<String, dynamic> _sizeOnly(
    Map<String, dynamic> params,
    GenerationSchema schema,
  ) {
    final size = _resolveSize(params, schema);
    return <String, dynamic>{
      if (size.isNotEmpty) ParamKeys.size: size,
    };
  }

  /// OpenAI Sora: пропорция -> size через mappedSize,
  /// длительность -> seconds (int).
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

  /// OpenRouter chat/completions: aspect_ratio/quality/size упаковываются
  /// внутрь image_config.
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

  /// Плоские поля рядом с model/prompt: aspect_ratio, duration (int),
  /// resolution (для генераторов изображений — image_resolution).
  static Map<String, dynamic> _standardFlat(
    Map<String, dynamic> params,
    ModelInfo model,
  ) {
    final out = <String, dynamic>{};
    final ratio = params[ParamKeys.aspectRatio];
    if (ratio is String && ratio.trim().isNotEmpty) {
      out[ParamKeys.aspectRatio] = ratio.trim();
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

  /// Размер холста: mappedSize выбранного варианта пропорции (или само
  /// значение варианта), иначе явный параметр size.
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

  /// Значение к int: int как есть, num округляется, строка через
  /// int.tryParse. null — привести не удалось.
  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
