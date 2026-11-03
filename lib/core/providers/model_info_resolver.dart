// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/model_info.dart';
import 'heuristic_rules.dart';
import 'model_catalog_adapter.dart';
import 'openrouter_catalog_adapter.dart';
import 'polza_catalog_adapter.dart';

/// Универсальный резолвер сведений о моделях.
///
/// Сводит воедино три источника:
///  1. каталог провайдера (адаптер по [providerId]) — высший приоритет;
///  2. запись каталога для конкретной модели, если она передана напрямую;
///  3. эвристику по идентификатору модели ([HeuristicRules]) — откат,
///     когда каталог недоступен или структура ответа не распознана.
///
/// Пока резолвер никем не вызывается — фундамент для следующих этапов
/// (список моделей, адаптивный ввод, выбор формата запроса).
abstract final class ModelInfoResolver {
  /// Адаптер каталога по идентификатору провайдера.
  /// null — провайдер не поддерживает разбор каталога.
  static ModelCatalogAdapter? adapterFor(String providerId) {
    switch (providerId.trim().toLowerCase()) {
      case 'openrouter':
        return const OpenRouterCatalogAdapter();
      case 'polza':
        return const PolzaCatalogAdapter();
      default:
        return null;
    }
  }

  /// Адаптер по провайдеру, определённому из Base URL, либо null.
  static ModelCatalogAdapter? adapterForBaseUrl(String baseUrl) {
    final id = ModelCatalogAdapter.providerIdFromBaseUrl(baseUrl);
    if (id == null) return null;
    return adapterFor(id);
  }

  /// Разбирает полный ответ каталога через подходящий адаптер.
  /// Возвращает пустой список, если провайдер не распознан или ответ
  /// не разобран — вызывающий код в этом случае откатывается к эвристике.
  static List<ModelInfo> parseCatalog(
    String providerId,
    Map<String, dynamic> responseBody,
  ) {
    final adapter = adapterFor(providerId);
    if (adapter == null) return const <ModelInfo>[];
    return adapter.parseCatalog(responseBody);
  }

  /// Сведения об одной модели.
  ///
  /// [catalogEntry] — запись каталога для этой модели, если известна:
  /// она разбирается адаптером провайдера; при неудаче используется
  /// эвристика. Без записи каталога работает только эвристика.
  static ModelInfo resolveModel(
    String providerId,
    String rawModelId, {
    Map<String, dynamic>? catalogEntry,
  }) {
    final id = rawModelId.trim();
    if (id.isEmpty) {
      return HeuristicRules.build(rawModelId, providerId: providerId);
    }
    final adapter = adapterFor(providerId);
    if (adapter != null && catalogEntry != null) {
      final info = adapter.parseModelEntry(catalogEntry);
      if (info != null) return info;
    }
    return HeuristicRules.build(id, providerId: providerId);
  }

  /// Список моделей из ответа каталога с откатом к эвристике:
  /// если адаптер не смог разобрать ответ, каждый идентификатор
  /// (строка либо поле 'id' записи) превращается в [ModelInfo] эвристикой.
  static List<ModelInfo> resolveCatalogWithFallback(
    String providerId,
    Map<String, dynamic> responseBody,
  ) {
    final parsed = parseCatalog(providerId, responseBody);
    if (parsed.isNotEmpty) return parsed;

    final data = responseBody['data'];
    if (data is! List) return const <ModelInfo>[];
    final out = <ModelInfo>[];
    final seen = <String>{};
    for (final e in data) {
      String? id;
      if (e is String) {
        id = e.trim();
      } else if (e is Map) {
        final v = e['id'] ?? e['name'] ?? e['model'];
        if (v is String && v.trim().isNotEmpty) id = v.trim();
      }
      if (id == null || id.isEmpty || !seen.add(id)) continue;
      out.add(HeuristicRules.build(id, providerId: providerId));
    }
    return out;
  }

  /// Индекс разобранного каталога по идентификатору модели —
  /// удобно, чтобы позже достать запись для конкретной модели.
  static Map<String, ModelInfo> indexById(List<ModelInfo> models) {
    return <String, ModelInfo>{
      for (final m in models) m.id: m,
    };
  }
}
