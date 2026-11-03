// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/generation_schema.dart';
import '../models/model_info.dart';

/// Нормализация параметров генерации под конкретную модель.
///
/// Интерфейс собирает значения параметров нейтрально (aspect_ratio,
/// duration, resolution ...), а провайдеры ожидают их в разных форматах.
/// [ParameterTranslator.translate] приводит сырые параметры к формату
/// конкретной модели по её [GenerationSchema]:
///  - [PayloadStyle.sizeOnly] — провайдер понимает только `size`,
///    пропорция превращается в размер холста через mappedSize;
///  - [PayloadStyle.openAiSora] — пропорция -> `size`, длительность ->
///    `seconds` (int), параметры OpenAI Sora;
///  - [PayloadStyle.openRouterChatConfig] — параметры упаковываются
///    внутрь `image_config` (chat/completions OpenRouter);
///  - [PayloadStyle.standardFlat] — плоские поля рядом с model/prompt;
///    для генераторов изображений разрешение уходит как `image_resolution`.
///
/// Если у модели нет схемы (generationSchema == null), параметры
/// возвращаются как есть — прежнее поведение.
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

  // ---------- стили payload ----------

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
      final key = model.isImageGenerator ? 'image_resolution' : ParamKeys.resolution;
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
