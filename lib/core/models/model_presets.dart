import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

/// Пресеты одной модели: какие параметры можно выбирать в интерфейсе.
class ModelPreset {
  final String id;
  final String type; // text | image | video
  final int? contextLength;
  final bool vision;
  final bool reasoning;
  final List<String> aspectRatios;
  final List<int> durations;
  final List<String> resolutions;

  const ModelPreset({
    required this.id,
    required this.type,
    this.contextLength,
    this.vision = false,
    this.reasoning = false,
    this.aspectRatios = const [],
    this.durations = const [],
    this.resolutions = const [],
  });

  factory ModelPreset.fromJson(Map<String, dynamic> j) => ModelPreset(
        id: j['id'] as String,
        type: j['type'] as String,
        contextLength: j['ctx'] as int?,
        vision: j['vision'] == true,
        reasoning: j['reasoning'] == true,
        aspectRatios: List<String>.from(j['ar'] ?? const []),
        durations: List<int>.from(j['dur'] ?? const []),
        resolutions: List<String>.from(j['res'] ?? const []),
      );

  // Какие селекторы показывать в UI (пустой список = селектор скрыт).
  bool get showAspectRatio => aspectRatios.isNotEmpty;
  bool get showDuration => durations.isNotEmpty;
  bool get showResolution => resolutions.isNotEmpty;

  /// Модель генерирует картинки/видео, а не обычный текст.
  bool get isMedia => type == 'image' || type == 'video' || showAspectRatio;
}

class ModelPresets {
  ModelPresets._(this._byId);
  final Map<String, ModelPreset> _byId;

  /// Загрузка из assets/model_presets.json
  static Future<ModelPresets> load() async {
    final raw = await rootBundle.loadString('assets/model_presets.json');
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return ModelPresets._({
      for (final j in list) j['id'] as String: ModelPreset.fromJson(j),
    });
  }

  /// Ищет пресет; суффикс провайдера (@provider=...) отбрасывается.
  ModelPreset? forModel(String modelId) =>
      _byId[modelId.split('@').first.trim()];

  Iterable<ModelPreset> get all => _byId.values;
  Iterable<ModelPreset> ofType(String t) => all.where((m) => m.type == t);
}
