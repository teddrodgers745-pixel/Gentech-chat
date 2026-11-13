// Copyright (c) 2026 Minkail. All rights reserved.

import 'catalog_entry.dart';
import 'parsing/openrouter_parser.dart';
import 'parsing/polza_parser.dart';
import 'parsing/routerai_parser.dart';

/// Разбирает уже декодированный ответ `GET {baseUrl}/models`
/// в список [CatalogEntry], выбирая парсер по адресу провайдера.
///
/// Детект провайдера — по [baseUrl] (без учёта регистра):
/// - содержит `polza.ai` → PolzaParser.parseEntry для каждой записи;
/// - содержит `routerai.ru` → RouterAiParser.parseEntry для каждой записи;
/// - содержит `openrouter.ai` → parseOpenRouterModel для каждой записи;
/// - иначе → пустой список.
///
/// Реальные сигнатуры парсеров (сами парсеры не меняются):
/// PolzaParser/RouterAiParser.parseEntry принимают ОДНУ запись
/// Map<String, dynamic> + connectionId (их parseCatalogResponse берёт
/// сырую строку ответа String, а не Map, поэтому здесь не используется);
/// parseOpenRouterModel — top-level функция с одной картой записи.
/// Идентификатор подключения диспетчеру не известен (его передаст
/// ProviderCatalogService на следующем этапе), поэтому в parseEntry
/// передаётся '' — нейтральное значение по умолчанию
/// CatalogEntry.connectionId.
List<CatalogEntry> parseModelsList(Map<String, dynamic> json, String baseUrl) {
  final String u = baseUrl.trim().toLowerCase();
  if (u.contains('polza.ai')) {
    return _parseEachEntry(json, (m) => PolzaParser.parseEntry(m, ''));
  }
  if (u.contains('routerai.ru')) {
    return _parseEachEntry(json, (m) => RouterAiParser.parseEntry(m, ''));
  }
  if (u.contains('openrouter.ai')) {
    return _parseEachEntry(json, parseOpenRouterModel);
  }
  return const <CatalogEntry>[];
}

/// Общий цикл разбора: список моделей берётся из `data` либо `models`
/// (те же ключи, что принимают сами парсеры Polza/RouterAI), каждая
/// запись безопасно приводится к `Map<String, dynamic>` (ключи-не-строки
/// переводятся в строки) и разбирается [parseOne]. Записи не-Map,
/// битые записи (исключение) и записи без идентификатора (null)
/// пропускаются, не мешая остальным.
List<CatalogEntry> _parseEachEntry(
  Map<String, dynamic> json,
  CatalogEntry? Function(Map<String, dynamic> m) parseOne,
) {
  final dynamic data = json['data'] ?? json['models'];
  if (data is! List) return const <CatalogEntry>[];
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
      final CatalogEntry? parsed = parseOne(m);
      if (parsed != null) out.add(parsed);
    } catch (_) {
      // Одна битая запись не роняет разбор остальных.
    }
  }
  return out;
}
