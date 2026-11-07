// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:shared_preferences/shared_preferences.dart';

import '../models/model_info.dart';
import '../providers/heuristic_rules.dart';
import 'curated_parameter_catalog.dart';
import 'user_param_override_store.dart';

/// Допустимые значения типа модели для ручного override.
abstract final class ModelTypes {
  static const String auto = 'auto';
  static const String text = 'text';
  static const String image = 'image';
  static const String video = 'video';
}

/// Хранилище ручного override типа модели.
///
/// Пользователь может явно указать, чем является модель — текстовой,
/// генератором изображений или видео. Значение сохраняется в
/// SharedPreferences по ключу 'model_type_override_<modelId>' и
/// переживает перезапуск приложения. Все операции терпимы к сбоям
/// хранилища: ошибка чтения/записи возвращает null, не роняя код.
class ModelTypeOverrideStore {
  static const String _prefix = 'model_type_override_';

  ModelTypeOverrideStore._();

  static final ModelTypeOverrideStore instance = ModelTypeOverrideStore._();

  /// Полный ключ хранения для модели.
  static String keyFor(String modelId) => '$_prefix${modelId.trim()}';

  /// Читает override типа модели; null — override не задан («Авто»).
  Future<String?> loadOverride(String modelId) async {
    final id = modelId.trim();
    if (id.isEmpty) return null;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(keyFor(id));
      switch (raw) {
        case ModelTypes.text:
        case ModelTypes.image:
        case ModelTypes.video:
          return raw;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Сохраняет override типа модели ('text' / 'image' / 'video').
  Future<void> save(String modelId, String type) async {
    final id = modelId.trim();
    if (id.isEmpty) return;
    if (type != ModelTypes.text &&
        type != ModelTypes.image &&
        type != ModelTypes.video) {
      return;
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(keyFor(id), type);
    } catch (_) {
      // Хранилище недоступно — override не сохранится, приложение работает.
    }
  }

  /// Удаляет override типа (возврат к режиму «Авто»).
  Future<void> clear(String modelId) async {
    final id = modelId.trim();
    if (id.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(keyFor(id));
    } catch (_) {
      // Хранилище недоступно — сбрасывать нечего.
    }
  }

  /// Эффективный тип модели ('text' / 'image' / 'video').
  ///
  /// Порядок приоритетов:
  ///  1. явный override пользователя;
  ///  2. эвристика по идентификатору (маршрут генерации);
  ///  3. если эвристика дала текст, но модель известна каталогу параметров
  ///     (курированный каталог либо пользовательский override параметров) —
  ///     тип берётся из параметров: есть длительности -> видео,
  ///     иначе изображение.
  Future<String> effectiveType(String modelId) async {
    final id = modelId.trim();
    if (id.isEmpty) return ModelTypes.text;
    final norm = HeuristicRules.normalize(id);
    final ov = await loadOverride(id) ??
        (norm.isNotEmpty && norm != id ? await loadOverride(norm) : null);
    if (ov != null) return ov;
    final lower = norm.toLowerCase();
    const videoHints = <String>[
      'seedance',
      'kling',
      'sora',
      'veo',
      'runway',
      'wan',
      'hailuo',
    ];
    const imageHints = <String>[
      'flux',
      'dall-e',
      'dalle',
      'midjourney',
      'stable-diffusion',
      'stablediffusion',
    ];
    if (!lower.contains('wanx')) {
      for (final h in videoHints) {
        if (lower.contains(h)) return ModelTypes.video;
      }
    }
    for (final h in imageHints) {
      if (lower.contains(h)) return ModelTypes.image;
    }
    final route = HeuristicRules.inferRoute(norm);
    if (route == GenerationRoute.imageGeneration) return ModelTypes.image;
    if (route == GenerationRoute.asyncJob) return ModelTypes.video;
    if (!CuratedParameterCatalog.isLoaded) {
      try {
        await CuratedParameterCatalog.load();
      } catch (_) {
        // Каталог недоступен — считаем модель текстовой ниже.
      }
    }
    var spec = CuratedParameterCatalog.byId(id) ??
        (norm.isNotEmpty ? CuratedParameterCatalog.byId(norm) : null);
    spec ??= await userParamOverrideStore.load(id) ??
        (norm.isNotEmpty ? await userParamOverrideStore.load(norm) : null);
    if (spec != null && spec.hasAny) {
      if (spec.type == 'video') return ModelTypes.video;
      if (spec.type == 'image') return ModelTypes.image;
      final durs = spec.durations;
      if (durs != null && !durs.isEmpty) return ModelTypes.video;
      if (spec.aspectRatios.isNotEmpty || spec.resolutions.isNotEmpty) {
        return ModelTypes.image;
      }
    }
    return ModelTypes.text;
  }
}
