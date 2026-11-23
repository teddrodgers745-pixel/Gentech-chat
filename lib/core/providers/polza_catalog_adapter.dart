// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/model_info.dart';
import 'heuristic_rules.dart';
import 'model_catalog_adapter.dart';

/// Адаптер каталога Polza (GET {baseUrl}/models).
class PolzaCatalogAdapter extends ModelCatalogAdapter {
  const PolzaCatalogAdapter();

  @override
  String get providerId => 'polza';

  @override
  List<ModelInfo> parseCatalog(Map<String, dynamic> responseBody) {
    final data = responseBody['data'];
    if (data is! List) return const <ModelInfo>[];
    final out = <ModelInfo>[];
    final seen = <String>{};
    for (final e in data) {
      final map = ModelCatalogAdapter.asMap(e);
      if (map == null) continue;
      final info = parseModelEntry(map);
      if (info != null && seen.add(info.id)) out.add(info);
    }
    return out;
  }

  @override
  ModelInfo? parseModelEntry(Map<String, dynamic> entry) {
    final id = ((entry['id'] as String?) ?? '').trim();
    if (id.isEmpty) {
      final fallback = ((entry['model'] as String?) ?? '').trim();
      if (fallback.isEmpty) return null;
      final fb = HeuristicRules.build(
        fallback,
        displayName: (entry['name'] as String?)?.trim(),
        providerId: providerId,
      );
      return _enrich(fb, entry);
    }

    final name = ((entry['name'] as String?) ?? '').trim();
    final base = HeuristicRules.build(
      id,
      displayName: name,
      providerId: providerId,
    );
    return _enrich(base, entry);
  }

  ModelInfo _enrich(ModelInfo base, Map<String, dynamic> entry) {
    final ctx = ModelCatalogAdapter.asInt(entry['context_length']) ??
        ModelCatalogAdapter.asInt(entry['contextLength']) ??
        ModelCatalogAdapter.asInt(entry['context_window']);

    final type = (entry['type'] is String)
        ? (entry['type'] as String).trim().toLowerCase()
        : '';

    Set<Modality>? inputModalities;
    final architecture = entry['architecture'];
    if (architecture is Map) {
      final rawInput = architecture['input_modalities'];
      if (rawInput is List) {
        final parsed = <Modality>{};
        for (final value in rawInput) {
          final modality = Modality.fromName(value?.toString());
          if (modality != null) parsed.add(modality);
        }
        if (parsed.isNotEmpty) inputModalities = parsed;
      }
    }

    GenerationRoute? route;
    Set<Modality>? outputModalities;
    switch (type) {
      case 'image':
        route = GenerationRoute.imageGeneration;
        outputModalities = const <Modality>{Modality.image};
        break;
      case 'video':
        route = GenerationRoute.asyncJob;
        outputModalities = const <Modality>{Modality.video};
        break;
    }

    return base.copyWith(
      pricing: ModelCatalogAdapter.parsePricing(entry) ?? base.pricing,
      contextLength: ctx ?? base.contextLength,
      inputModalities: outputModalities != null ? inputModalities : null,
      outputModalities: outputModalities,
      route: route,
      source: CapabilitySource.providerCatalog,
    );
  }
}
