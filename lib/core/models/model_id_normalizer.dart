// Copyright (c) 2026 Minkail. All rights reserved.

/// Нормализация идентификатора модели к «базовому» виду.
///
/// Один и тот же идентификатор приходит в разных формах: с суффиксом
/// выбранного провайдера ('vendor/model@provider=polza'), с вариантом
/// маршрутизации ('model:free', 'model:exacto') или в другом регистре.
/// Для сравнения, поиска в каталоге и определения типа модели нужна
/// одна каноническая строка — её и возвращает [ModelIdNormalizer].
abstract final class ModelIdNormalizer {
  /// Базовый идентификатор: нижний регистр, без '@provider=...'
  /// и без ':free' / ':exacto' и подобных суффиксов.
  static String normalize(String id) {
    var s = id.trim().toLowerCase();
    s = s.split('@').first; // убрать @provider=...
    if (s.contains(':')) s = s.split(':').first; // убрать :free, :exacto
    return s;
  }

  /// Идентификатор без префикса владельца: 'vendor/model' -> 'model'.
  /// Если префикса нет, возвращается нормализованный идентификатор целиком.
  static String withoutProviderPrefix(String id) {
    final n = normalize(id);
    final slash = n.indexOf('/');
    return slash >= 0 ? n.substring(slash + 1) : n;
  }
}
