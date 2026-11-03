// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/param_spec.dart';

/// Хранилище пользовательских override параметров моделей.
///
/// Пользователь может вручную задать параметры конкретной модели;
/// они сохраняются в SharedPreferences по ключу
/// 'model_params_override_<modelId>' как JSON [ModelParameters]
/// и переживают обновление приложения. Все операции терпимы к сбоям
/// хранилища: ошибка чтения/записи возвращает null/false, не роняя код.
class UserParamOverrideStore {
  static const String _prefix = 'model_params_override_';

  /// Полный ключ хранения для модели.
  static String keyFor(String modelId) =>
      '$_prefix${modelId.trim()}';

  /// Читает override модели; null — override не задан либо битый.
  Future<ModelParameters?> load(String modelId) async {
    final id = modelId.trim();
    if (id.isEmpty) return null;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(keyFor(id));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return ModelParameters.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  /// Сохраняет override модели: запись помечается isUserDefined=true
  /// и confidence='user', чтобы интерфейс отличал её от каталога.
  Future<void> save(String modelId, ModelParameters params) async {
    final id = modelId.trim();
    if (id.isEmpty) return;
    final copy = ModelParameters(
      aspectRatios: params.aspectRatios,
      durations: params.durations,
      resolutions: params.resolutions,
      sizes: params.sizes,
      qualities: params.qualities,
      constraints: params.constraints,
      confidence: 'user',
      isUserDefined: true,
    );
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(keyFor(id), jsonEncode(copy.toJson()));
    } catch (_) {
      // Хранилище недоступно — override не сохранится, приложение работает.
    }
  }

  /// Удаляет override модели (если он был).
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

  /// Идентификаторы всех моделей, у которых задан override.
  Future<List<String>> allModelIdsWithOverride() async {
    try {
      final p = await SharedPreferences.getInstance();
      final keys = p.getKeys();
      final out = <String>[
        for (final k in keys)
          if (k.startsWith(_prefix) && k.length > _prefix.length)
            k.substring(_prefix.length),
      ];
      out.sort();
      return out;
    } catch (_) {
      return const <String>[];
    }
  }
}

/// Глобальный экземпляр хранилища override.
final UserParamOverrideStore userParamOverrideStore =
    UserParamOverrideStore();
