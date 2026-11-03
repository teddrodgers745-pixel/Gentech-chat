// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/param_spec.dart';

/// Курированный каталог параметров генерации.
///
/// Загружается один раз из assets/data/models_curated.json (записи
/// с достоверностью 'high'). [byId] возвращает null, если модели нет
/// в каталоге: fallback на значения по умолчанию НЕ выполняется —
/// вызывающий код решает сам, что делать с неизвестной моделью.
abstract final class CuratedParameterCatalog {
  static const String _assetPath = 'assets/data/models_curated.json';

  static Map<String, ModelParameters>? _entries;
  static bool _loading = false;

  /// Загружен ли каталог хотя бы один раз.
  static bool get isLoaded => _entries != null;

  /// Читает asset и разбирает записи. Ошибки (нет asset, битый JSON)
  /// не роняют приложение: каталог остаётся пустым, byId вернёт null.
  static Future<void> load() async {
    if (_entries != null || _loading) return;
    _loading = true;
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final decoded = jsonDecode(raw);
      final map = <String, ModelParameters>{};
      if (decoded is List) {
        for (final e in decoded) {
          if (e is! Map) continue;
          try {
            final p =
                _parseEntry(Map<String, dynamic>.from(e));
            if (p != null) map[p.key] = p.value;
          } catch (_) {
            // Битая запись пропускается.
          }
        }
      }
      _entries = map;
    } catch (_) {
      // Asset недоступен либо JSON битый: каталог пуст, byId вернёт null.
      _entries = <String, ModelParameters>{};
    } finally {
      _loading = false;
    }
  }

  /// Параметры модели по идентификатору; null — модели нет в каталоге
  /// либо каталог ещё не загружен ([load] не вызывался).
  static ModelParameters? byId(String modelId) {
    final map = _entries;
    if (map == null) return null;
    final id = modelId.trim();
    if (id.isEmpty) return null;
    return map[id];
  }

  /// Разбор одной записи каталога в пару (id, ModelParameters).
  /// null — запись без идентификатора.
  static MapEntry<String, ModelParameters>? _parseEntry(
    Map<String, dynamic> e,
  ) {
    final id = ((e['id'] as String?) ?? '').trim();
    if (id.isEmpty) return null;

    List<String> strings(Object? raw) {
      if (raw is! List) return <String>[];
      return <String>[
        for (final v in raw)
          if (v != null) v.toString(),
      ];
    }

    // durations приходит в двух формах: список дискретных значений
    // ([4, 8, 12]) либо объект-диапазон {type: 'range', min: 3, max: 15}.
    DurationRange? durations;
    final rawDur = e['durations'];
    if (rawDur is List) {
      final discrete = <int>[
        for (final v in rawDur)
          if (v is num) v.round(),
      ];
      if (discrete.isNotEmpty) {
        durations = DurationRange(discrete: discrete);
      }
    } else if (rawDur is Map) {
      try {
        final m = Map<String, dynamic>.from(rawDur);
        final dr = DurationRange(
          min: (m['min'] as num?)?.toInt(),
          max: (m['max'] as num?)?.toInt(),
        );
        if (!dr.isEmpty) durations = dr;
      } catch (_) {
        durations = null;
      }
    }

    return MapEntry(
      id,
      ModelParameters(
        aspectRatios: strings(e['aspect_ratios']),
        durations: durations,
        resolutions: strings(e['resolutions']),
        sizes: strings(e['size_options']),
        qualities: strings(e['quality_options']),
        constraints: strings(e['special_constraints']),
        confidence: ((e['confidence'] as String?) ?? 'low').trim(),
        isUserDefined: false,
      ),
    );
  }
}
