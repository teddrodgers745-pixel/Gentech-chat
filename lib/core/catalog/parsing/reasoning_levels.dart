// Copyright (c) 2026 Minkail. All rights reserved.

/// Известные уровни для оформления интерфейса. Этот список не является
/// источником поддерживаемых моделью значений.
const List<String> kCanonicalReasoningLevels = <String>[
  'off', 'low', 'medium', 'high', 'xhigh', 'max',
];

/// Сохраняет перечисленные каталогом уровни и их исходный порядок.
///
/// Пустые значения и повторения удаляются. Уровни не переименовываются,
/// не сортируются и не добавляются, даже если список пуст. Признак
/// [mandatory] оставлен в контракте для существующих вызывающих сторон;
/// сам по себе он не доказывает наличие какого-либо уровня.
List<String> normalizeReasoningLevels(
  List<String> raw, {
  bool mandatory = false,
}) {
  final out = <String>[];
  for (final value in raw) {
    final level = value.trim();
    if (level.isNotEmpty && !out.contains(level)) {
      out.add(level);
    }
  }
  return out;
}

/// Сохраняет идентификатор default effort без подмены значений каталога.
String normalizeReasoningEffort(String raw) => raw.trim();
