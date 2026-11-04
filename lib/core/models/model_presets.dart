// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Пресет одной модели: допустимые соотношения сторон, длительности
/// и разрешения. Простой неизменяемый снимок данных из asset.
class ModelPreset {
  final String id;
  final List<String> aspectRatios;
  final List<int> durations;
  final List<String> resolutions;

  const ModelPreset({
    required this.id,
    required this.aspectRatios,
    required this.durations,
    required this.resolutions,
  });
}

/// Fallback-слой параметров из assets/model_presets.json.
///
/// Формат asset — список записей вида:
/// {"id": "...", "aspect_ratios": [...], "durations": [...],
///  "resolutions": [...]}
/// (допускается также карта {id: {...}}). Ключи с указанием
/// провайдера («model@provider») и «чистые» идентификаторы хранятся
/// одинаково; поиск — сначала точный, затем по базовому id.
class ModelPresets {
  final Map<String, ModelPreset> _byId;

  const ModelPresets._(this._byId);

  /// Читает и разбирает asset. Бросает исключение при недоступности
  /// файла или битом JSON — вызывающий код обязан это обработать
  /// (в CuratedParameterCatalog.load это уже сделано).
  static Future<ModelPresets> load() async {
    final raw = await rootBundle.loadString('assets/model_presets.json');
    final decoded = jsonDecode(raw);
    final map = <String, ModelPreset>{};

    void addFromMap(Map<String, dynamic> m) {
      final id = ((m['id'] as String?) ?? '').trim();
      if (id.isEmpty || map.containsKey(id)) return;
      map[id] = ModelPreset(
        id: id,
        aspectRatios: _strings(m['aspect_ratios']),
        durations: _ints(m['durations']),
        resolutions: _strings(m['resolutions']),
      );
    }

    if (decoded is List) {
      for (final e in decoded) {
        if (e is Map) addFromMap(Map<String, dynamic>.from(e));
      }
    } else if (decoded is Map) {
      decoded.forEach((key, value) {
        if (value is Map) {
          final m = Map<String, dynamic>.from(value);
          m.putIfAbsent('id', () => key.toString());
          addFromMap(m);
        }
      });
    }
    return ModelPresets._(map);
  }

  /// Пресет модели: сначала точное совпадение идентификатора
  /// (в том числе с суффиксом @provider), затем по базовому id
  /// без суффикса. null — пресета нет.
  ModelPreset? forModel(String modelId) {
    final id = modelId.trim();
    if (id.isEmpty) return null;
    final exact = _byId[id];
    if (exact != null) return exact;
    final base = id.split('@').first.trim();
    if (base.isEmpty || base == id) return null;
    return _byId[base];
  }

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const <String>[];
    return <String>[
      for (final v in raw)
        if (v != null) v.toString(),
    ];
  }

  static List<int> _ints(Object? raw) {
    if (raw is! List) return const <int>[];
    return <int>[
      for (final v in raw)
        if (v is num) v.round(),
    ];
  }
}
