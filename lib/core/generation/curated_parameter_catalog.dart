// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/model_presets.dart';
import '../models/param_spec.dart';

/// Курированный каталог параметров генерации.
///
/// Загружается один раз из assets/data/models_curated.json (записи
/// с достоверностью 'high'). Дополнительно подгружаются пресеты моделей
/// ([ModelPresets], assets/model_presets.json) — fallback-слой для
/// моделей, которых нет в курированном каталоге: параметры строятся
/// из пресета с достоверностью 'auto'.
///
/// [byId] возвращает null, если модели нет ни в каталоге, ни в пресетах:
/// fallback на значения по умолчанию НЕ выполняется — вызывающий код
/// решает сам, что делать с неизвестной моделью. SKIP-модели (озвучка,
/// апскейл и т.п. — не генераторы) возвращают пустую спецификацию с
/// confidence='skip', чтобы интерфейс отличал «нет данных» от
/// «не генератор».
abstract final class CuratedParameterCatalog {
  static const String _assetPath = 'assets/data/models_curated.json';

  /// Модели, которые не являются генераторами изображений/видео:
  /// параметры им не нужны, интерфейсу сообщается confidence='skip'.
  static const Set<String> _skipped = <String>{
    'deepgram/flux-tts',
    'heygen/heygen-voice-1',
    'heygen/heygen-voice-1-turbo',
    'black-forest-labs/flux-video-upscale',
    'thinkingmachines/inkling',
    'thinkingmachines/inkling-small',
  };

  /// Модель, для которой тип явно фиксируется как 'video':
  /// эвристика по идентификатору её маршрут не распознаёт.
  static const String _flux3VideoId = 'black-forest-labs/flux-3-video';

  static Map<String, ModelParameters>? _entries;
  static ModelPresets? _presets;
  static bool _loading = false;

  /// Загружен ли каталог хотя бы один раз.
  static bool get isLoaded => _entries != null;

  /// Читает asset и разбирает записи. Ошибки (нет asset, битый JSON)
  /// не роняют приложение: каталог остаётся пустым, byId вернёт null.
  /// Ошибка загрузки пресетов тоже не роняет каталог: fallback-слоя
  /// просто не будет ([_presets] = null).
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
            final p = _parseEntry(Map<String, dynamic>.from(e));
            if (p != null) map[p.key] = p.value;
          } catch (_) {
            // Битая запись пропускается.
          }
        }
      }
      try {
        _presets = await ModelPresets.load();
      } catch (_) {
        _presets = null;
      }
      _entries = map;
    } catch (_) {
      // Asset недоступен либо JSON битый: каталог пуст, byId вернёт null.
      _entries = <String, ModelParameters>{};
      _presets = null;
    } finally {
      _loading = false;
    }
  }

  /// Параметры модели по идентификатору; null — модели нет в каталоге
  /// либо каталог ещё не загружен ([load] не вызывался).
  ///
  /// Приоритет: курированный каталог ('high') -> SKIP-модели ('skip') ->
  /// пресеты моделей ('auto') -> null.
  static ModelParameters? byId(String modelId) {
    final map = _entries;
    if (map == null) return null;
    final id = modelId.trim();
    if (id.isEmpty) return null;
    final curated = map[id];
    if (curated != null) return _withTypeFix(curated, id);
    final baseId = id.split('@').first.trim();
    if (_skipped.contains(baseId)) {
      return ModelParameters.unknown(confidence: 'skip');
    }
    final presets = _presets;
    if (presets != null) {
      final p = presets.forModel(modelId);
      if (p == null) return null;
      final durs = _ints(p.durations);
      return _withTypeFix(
        ModelParameters(
          aspectRatios: _strings(p.aspectRatios),
          durations: durs.isEmpty ? null : DurationRange(discrete: durs),
          resolutions: _strings(p.resolutions),
          sizes: const <String>[],
          qualities: const <String>[],
          constraints: const <String>[],
          confidence: 'auto',
          isUserDefined: false,
        ),
        id,
      );
    }
    return null;
  }

  /// Явный тип для моделей, чьё семейство не распознаётся эвристикой
  /// (flux-3-video); остальные спецификации не меняет.
  static ModelParameters _withTypeFix(ModelParameters spec, String modelId) {
    final baseId = modelId.trim().split('@').first.trim();
    if (baseId == _flux3VideoId) spec.type = 'video';
    return spec;
  }

  /// Список строк из значения произвольного типа (терпимо к List<String>,
  /// List<dynamic> и т.п.); null-элементы пропускаются.
  static List<String> _strings(Object? raw) {
    if (raw is! List) return const <String>[];
    return <String>[
      for (final v in raw)
        if (v != null) v.toString(),
    ];
  }

  /// Список int из значения произвольного типа (числа округляются).
  static List<int> _ints(Object? raw) {
    if (raw is! List) return const <int>[];
    return <int>[
      for (final v in raw)
        if (v is num) v.round(),
    ];
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
