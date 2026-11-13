// Copyright (c) 2026 Minkail Uchuev. All rights reserved.

import 'catalog_entry.dart';
import 'parsing/openrouter_parser.dart';
import 'parsing/polza_parser.dart';
import 'parsing/routerai_parser.dart';

/// Разбирает ответ `GET {baseUrl}/models` в список [CatalogEntry].
///
/// Определение провайдера по [baseUrl] (без учёта регистра):
/// - `polza.ai` → [PolzaParser.parseCatalogResponse]
/// - `routerai.ru` → [RouterAiParser.parseCatalogResponse]
/// - `openrouter.ai` → цикл по `json['data']` через [parseOpenRouterModel]
/// - иначе → пустой список.
List<CatalogEntry> parseModelsList(Map<String, dynamic> json, String baseUrl) {
  final String u = baseUrl.trim().toLowerCase();
  if (u.contains('polza.ai')) {
    return PolzaParser.parseCatalogResponse(json);
  }
  if (u.contains('routerai.ru')) {
    return RouterAiParser.parseCatalogResponse(json);
  }
  if (u.contains('openrouter.ai')) {
    final dynamic data = json['data'];
    if (data is! List) return const <CatalogEntry>[];
    final out = <CatalogEntry>[];
    for (final dynamic item in data) {
      if (item is! Map) continue;
      final Map<String, dynamic> m = item is Map<String, dynamic>
          ? item
          : <String, dynamic>{
              for (final e in item.entries)
                if (e.key != null) e.key.toString(): e.value,
            };
      try {
        final CatalogEntry? parsed = parseOpenRouterModel(m);
        if (parsed != null) out.add(parsed);
      } catch (_) {}
    }
    return out;
  }
  return const <CatalogEntry>[];
}
