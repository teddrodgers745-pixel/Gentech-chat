// Copyright (c) 2026 Minkail. All rights reserved.

import 'catalog_entry.dart';
import 'parsing/openrouter_parser.dart';
import 'parsing/polza_parser.dart';
import 'parsing/routerai_parser.dart';

/// Разбирает ответ каталога, выбирая парсер по адресу провайдера.
List<CatalogEntry> parseModelsList(Map<String, dynamic> json, String baseUrl) {
  final u = baseUrl.trim().toLowerCase();
  if (u.contains('polza.ai')) {
    return _parseEachEntry(json, _parsePolzaEntry);
  }
  if (u.contains('routerai.ru')) {
    return _parseEachEntry(json, (m) => RouterAiParser.parseEntry(m, ''));
  }
  if (u.contains('openrouter.ai')) {
    return _parseEachEntry(json, parseOpenRouterModel);
  }
  return const <CatalogEntry>[];
}

/// Дополняет результат парсера Polza исходным типом и схемой параметров.
///
/// Сырые блоки цен сохраняются как есть (Map/List/другое) — в
/// `model_pricing_raw` и `top_provider_pricing_raw`. Это позволяет
/// `CostEstimator` учитывать условия тиров (resolution, has_video,
/// unitParam: duration) и не терять их при плоском кэше `pricing_tiers`.
///
/// Дополнительно в `mediaParams` сохраняется `resolution_default` из
/// параметра `resolution`/`image_resolution` — он нужен оценщику, когда
/// пользователь не передал явный разрешение.
CatalogEntry? _parsePolzaEntry(Map<String, dynamic> raw) {
  CatalogEntry? parsed;
  try {
    parsed = PolzaParser.parseEntry(raw, '');
  } catch (_) {
    // Запись с корректным id остаётся доступной даже тогда, когда
    // специализированный парсер не разобрал необязательное поле.
  }

  final rawId = raw['id'];
  final id = rawId is String ? rawId.trim() : '';
  final entry = parsed ??
      (id.isEmpty
          ? null
          : CatalogEntry(
              connectionId: '',
              id: id,
              name: raw['name'] is String ? raw['name'] as String : '',
              reasoningUnknown: true,
              capabilitiesSource: CatalogSources.connection,
            ));
  if (entry == null) return null;

  final rawType = raw['type'] is String ? raw['type'] as String : '';
  final type = rawType.trim().toLowerCase();
  final typeSource = type.isEmpty
      ? CatalogTypeSources.unknown
      : CatalogTypeSources.catalog;
  final mediaParams = <String, dynamic>{...entry.mediaParams};

  // Сырые блоки цен — сохраняем как есть, чтобы не потерять условия тиров,
  // валюту и единицы (форма Map/List/др. не должна обрезаться).
  final modelPricing = raw['pricing'];
  if (modelPricing != null) {
    mediaParams['model_pricing_raw'] = modelPricing;
  }
  final topProvider = raw['top_provider'];
  final topPricing = topProvider is Map ? topProvider['pricing'] : null;
  if (topPricing != null) {
    mediaParams['top_provider_pricing_raw'] = topPricing;
  }

  final rawParameters = raw['parameters'];
  if (rawParameters is! Map) {
    return entry.copyWith(
      type: type,
      rawType: rawType,
      typeSource: typeSource,
      mediaParams: mediaParams,
    );
  }

  final parameters = <String, dynamic>{
    for (final item in rawParameters.entries)
      if (item.key is String) item.key as String: item.value,
  };
  mediaParams['parameters'] = parameters;

  // `resolution_default` (для оценщика стоимости).
  final resolutionKey = type == 'image' ? 'image_resolution' : 'resolution';
  final resolutionSpec = parameters[resolutionKey];
  if (resolutionSpec is Map) {
    final def = resolutionSpec['default'];
    if (def is String && def.trim().isNotEmpty) {
      mediaParams['resolution_default'] = def.trim();
    }
  }

  if (type != 'image' && type != 'video') {
    return entry.copyWith(
      type: type,
      rawType: rawType,
      typeSource: typeSource,
      mediaParams: mediaParams,
    );
  }

  List<String> values(String key) {
    final constraint = parameters[key];
    if (constraint is! Map) return <String>[];
    final rawValues = constraint['values'] ?? constraint['enum'];
    if (rawValues is! List) return <String>[];
    return <String>[
      for (final value in rawValues)
        if (value is String || value is num || value is bool) value.toString(),
    ];
  }

  mediaParams['sizes'] = values('size');

  final durations = <int>[];
  for (final value in values('duration')) {
    final parsed = int.tryParse(value);
    if (parsed != null) durations.add(parsed);
  }

  final durationSpec = parameters['duration'];
  if (durationSpec is Map) {
    int? intOf(Object? v) {
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v.trim());
      return null;
    }

    final defSec = intOf(durationSpec['default']);
    final minSec = intOf(durationSpec['min']);
    final maxSec = intOf(durationSpec['max']);
    if (defSec != null) mediaParams['duration_default'] = defSec;
    if (minSec != null) mediaParams['duration_min'] = minSec;
    if (maxSec != null) mediaParams['duration_max'] = maxSec;
  }

  final images = parameters['images'];
  final maxImages = images is Map ? images['max'] : null;
  int? maxReferenceImages;
  if (maxImages is int) {
    maxReferenceImages = maxImages;
  } else if (maxImages is num && maxImages == maxImages.roundToDouble()) {
    maxReferenceImages = maxImages.toInt();
  } else if (maxImages is String) {
    maxReferenceImages = int.tryParse(maxImages);
  }

  return entry.copyWith(
    type: type,
    rawType: rawType,
    typeSource: typeSource,
    aspectRatios: values('aspect_ratio'),
    resolutions: values(type == 'image' ? 'image_resolution' : 'resolution'),
    durations: durations,
    qualities: values('quality'),
    maxReferenceImages: maxReferenceImages,
    mediaParams: mediaParams,
  );
}

/// Битая запись каталога не мешает разбору остальных.
List<CatalogEntry> _parseEachEntry(
  Map<String, dynamic> json,
  CatalogEntry? Function(Map<String, dynamic> m) parseOne,
) {
  final dynamic data = json['data'] ?? json['models'];
  if (data is! List) return <CatalogEntry>[];
  final out = <CatalogEntry>[];
  for (final dynamic item in data) {
    if (item is! Map) continue;
    final Map<String, dynamic> m = item is Map<String, dynamic>
        ? item
        : <String, dynamic>{
            for (final dynamic e in item.entries)
              if (e.key != null) e.key.toString(): e.value,
          };
    try {
      final parsed = parseOne(m);
      if (parsed != null) out.add(parsed);
    } catch (_) {
      // Одна битая запись не роняет разбор остальных.
    }
  }
  return out;
}
