// Copyright (c) 2026 Minkail. All rights reserved.

/// Канонические уровни размышлений (Reasoning Effort) в порядке
/// возрастания: от выключенного до максимального.
const List<String> kCanonicalReasoningLevels = <String>[
  'off', 'low', 'medium', 'high', 'xhigh', 'max',
];

/// Нормализует уровни reasoning к каноническому виду.
/// - 'none' → 'off', 'minimal' → 'low'
/// - неизвестные значения отбрасываются
/// - дубли удаляются
/// - сортирует по kCanonicalReasoningLevels
/// - если mandatory=true — удаляет 'off'
/// - если результат пуст — возвращает ['off'] (или ['high'] если mandatory)
List<String> normalizeReasoningLevels(
  List<String> raw, {
  bool mandatory = false,
}) {
  final out = <String>[];
  for (final v in raw) {
    final s = v.trim().toLowerCase();
    if (s.isEmpty) continue;
    final String? mapped;
    switch (s) {
      case 'none':
        mapped = 'off';
      case 'minimal':
        mapped = 'low';
      case 'off':
      case 'low':
      case 'medium':
      case 'high':
      case 'xhigh':
      case 'max':
        mapped = s;
      default:
        mapped = null;
    }
    if (mapped != null && !out.contains(mapped)) out.add(mapped);
  }
  out.sort((a, b) =>
      kCanonicalReasoningLevels.indexOf(a)
          .compareTo(kCanonicalReasoningLevels.indexOf(b)));
  if (mandatory) out.remove('off');
  if (out.isEmpty) out.add(mandatory ? 'high' : 'off');
  return out;
}

/// Нормализует одиночный default effort ('none'→'off', 'minimal'→'low').
String normalizeReasoningEffort(String raw) {
  final s = raw.trim().toLowerCase();
  if (s == 'none') return 'off';
  if (s == 'minimal') return 'low';
  return s;
}
