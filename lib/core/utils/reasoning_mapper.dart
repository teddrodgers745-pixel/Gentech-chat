// Copyright (c) 2026 Minkail. All rights reserved.

/// Единый селектор Reasoning Effort: уровни размышлений, их подписи
/// и перевод в поля API провайдера.
///
/// Уровни упорядочены от выключенного к максимальному — индекс enum
/// используется как позиция слайдера в интерфейсе.
enum ReasoningLevel { off, minimal, low, medium, high, xhigh }

/// Подписи и удобства уровня для интерфейса.
extension ReasoningLevelX on ReasoningLevel {
  /// Стабильный строковый идентификатор (совпадает с именем enum).
  String get id => name;

  /// Короткая подпись для капсулы и слайдера.
  String get label => switch (this) {
        ReasoningLevel.off => 'Off',
        ReasoningLevel.minimal => 'Min',
        ReasoningLevel.low => 'Low',
        ReasoningLevel.medium => 'Med',
        ReasoningLevel.high => 'High',
        ReasoningLevel.xhigh => 'Max',
      };
}

/// Перевод уровня размышлений в payload запроса к провайдеру.
abstract final class ReasoningMapper {
  /// Уровень по строковому идентификатору; неизвестное значение — off.
  static ReasoningLevel fromId(String id) {
    final s = id.trim().toLowerCase();
    for (final l in ReasoningLevel.values) {
      if (l.name == s) return l;
    }
    return ReasoningLevel.off;
  }

  /// Известен ли идентификатор уровня (валидация сохранённых настроек).
  static bool isKnownId(String id) {
    final s = id.trim().toLowerCase();
    for (final l in ReasoningLevel.values) {
      if (l.name == s) return true;
    }
    return false;
  }

  /// Уровни из списка строк каталога модели: дубликаты убираются,
  /// порядок — от off к максимуму (порядок слайдера).
  static List<ReasoningLevel> levelsFromNames(List<String> names) {
    final out = <ReasoningLevel>[];
    for (final n in names) {
      final l = fromId(n);
      if (!out.contains(l)) out.add(l);
    }
    out.sort((a, b) => a.index.compareTo(b.index));
    return out;
  }

  /// Payload уровня размышлений для тела запроса /chat/completions:
  ///  - [ReasoningLevel.off] — пустая карта (поле не отправляется);
  ///  - идентификатор с префиксом владельца ('vendor/model', формат
  ///    каталогов-агрегаторов) — поле reasoning: {effort: ...};
  ///  - остальные (прямые OpenAI-совместимые провайдеры) —
  ///    reasoning_effort: '...'.
  static Map<String, dynamic> mapToApi(
    ReasoningLevel level,
    String modelId,
  ) {
    if (level == ReasoningLevel.off) return const <String, dynamic>{};
    final id = modelId.trim().toLowerCase();
    if (id.contains('/')) {
      return <String, dynamic>{
        'reasoning': <String, dynamic>{'effort': level.name},
      };
    }
    return <String, dynamic>{'reasoning_effort': level.name};
  }
}
