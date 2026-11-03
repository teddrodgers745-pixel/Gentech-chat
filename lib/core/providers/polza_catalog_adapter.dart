// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/model_info.dart';
import 'heuristic_rules.dart';
import 'model_catalog_adapter.dart';

/// Адаптер каталога Polza (GET {baseUrl}/models).
///
/// Формат ответа — OpenAI-совместимый:
/// {"data": [{"id": "vendor/model", "name": "Модель", ...},
///           ...]}
/// Часть полей (модальности, маршрут, флаги) в ответе обычно отсутствует —
/// они добираются эвристикой по идентификатору модели; цены и понятное имя
/// берутся из каталога, поэтому источник помечается как [CapabilitySource.providerCatalog].
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
      // Некоторые каталоги кладут идентификатор в 'name' или 'model'.
      final fallback =
          ((entry['model'] as String?) ?? '').trim();
      if (fallback.isEmpty) return null;
      final fb = HeuristicRules.build(
        fallback,
        displayName: (entry['name'] as String?)?.trim(),
        providerId: providerId,
      );
      return _enrich(fb, entry);
    }

    final name = ((entry['name'] as String?) ?? '').trim();
    final base = HeuristicRules.build(id, displayName: name, providerId: providerId);
    return _enrich(base, entry);
  }

  /// Дополняет эвристическую модель данными каталога: цены, контекст.
  /// Модальности каталог Polza в общем случае не сообщает, поэтому
  /// эвристические значения остаются (они консервативны и безопасны).
  ModelInfo _enrich(ModelInfo base, Map<String, dynamic> entry) {
    final ctx = ModelCatalogAdapter.asInt(entry['context_length']) ??
        ModelCatalogAdapter.asInt(entry['contextLength']) ??
        ModelCatalogAdapter.asInt(entry['context_window']);
    return base.copyWith(
      pricing:
          ModelCatalogAdapter.parsePricing(entry) ?? base.pricing,
      contextLength: ctx ?? base.contextLength,
      source: CapabilitySource.providerCatalog,
    );
  }
}
