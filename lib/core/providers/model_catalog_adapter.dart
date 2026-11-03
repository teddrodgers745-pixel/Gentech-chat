// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/model_info.dart';

/// Базовый контракт адаптера каталога моделей провайдера.
///
/// Адаптер превращает необработанный JSON-ответ GET {baseUrl}/models
/// в список [ModelInfo]. Конкретные провайдеры (OpenRouter, Polza и другие)
/// реализуют контракт отдельными классами; универсальный код
/// ([ModelInfoResolver]) работает только через этот интерфейс.
/// Пока адаптеры никем не вызываются — фундамент для следующих этапов.
abstract class ModelCatalogAdapter {
  const ModelCatalogAdapter();

  /// Идентификатор провайдера ('polza', 'openrouter', ...).
  String get providerId;

  /// Разбирает полный ответ каталога. Возвращает пустой список,
  /// если структура ответа не распознана — вызывающий код в этом
  /// случае откатывается к эвристике по идентификаторам моделей.
  List<ModelInfo> parseCatalog(Map<String, dynamic> responseBody);

  /// Разбирает одну запись каталога в [ModelInfo].
  /// Возвращает null, если запись не содержит идентификатора модели.
  ModelInfo? parseModelEntry(Map<String, dynamic> entry);

  // ---------- общие помощники для адаптеров ----------

  /// Приводит значение к Map<String, dynamic>, либо null.
  static Map<String, dynamic>? asMap(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  /// Приводит значение к int (принимает int, num и числовую строку).
  static int? asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.round();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  /// Приводит значение к double (принимает num и строку с точкой/запятой).
  static double? asDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) {
      return double.tryParse(raw.trim().replaceAll(',', '.'));
    }
    return null;
  }

  /// Список строк из значения произвольного типа.
  static List<String> asStringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return <String>[
      for (final e in raw)
        if (e != null) e.toString(),
    ];
  }

  /// Разбирает список названий модальностей в множество [Modality].
  /// Терпимо к синонимам ('image_url', 'vision' и т.п.).
  static Set<Modality> parseModalities(Object? raw) {
    final out = <Modality>{};
    for (final name in asStringList(raw)) {
      final m = Modality.fromName(name);
      if (m != null) out.add(m);
    }
    return out;
  }

  /// Пара цен из полей, встречающихся в каталогах: сначала вложенный
  /// объект pricing (prompt/completion либо input/output), затем плоские
  /// поля input_price/output_price и price_in/price_out.
  /// Значения за один токен (< 1) переводятся в цену за миллион токенов.
  /// Возвращает null, если ни одной цены не найдено.
  static Pricing? parsePricing(Map<String, dynamic> entry) {
    final pricing = asMap(entry['pricing']);
    double? inPrice;
    double? outPrice;
    if (pricing != null) {
      inPrice = asDouble(pricing['prompt']) ?? asDouble(pricing['input']);
      outPrice =
          asDouble(pricing['completion']) ?? asDouble(pricing['output']);
    }
    inPrice ??= asDouble(entry['input_price']) ?? asDouble(entry['price_in']);
    outPrice ??=
        asDouble(entry['output_price']) ?? asDouble(entry['price_out']);
    final inMillion = Pricing.perTokenToPerMillion(inPrice);
    final outMillion = Pricing.perTokenToPerMillion(outPrice);
    if (inMillion == null && outMillion == null) return null;
    return Pricing(inputPerMillion: inMillion, outputPerMillion: outMillion);
  }

  /// Определяет идентификатор провайдера по Base URL.
  /// null — провайдер не распознан, нужен явный providerId.
  static String? providerIdFromBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    final host = (uri?.host ?? '').toLowerCase();
    if (host.endsWith('openrouter.ai')) return 'openrouter';
    if (host.endsWith('polza.ai')) return 'polza';
    if (host.contains('routerai')) return 'routerai';
    return null;
  }
}
