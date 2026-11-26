// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:shared_preferences/shared_preferences.dart';

import '../../app_state.dart';
import '../auth/polza_auth_service.dart';
import '../catalog/catalog_entry.dart';
import '../catalog/provider_catalog_service.dart';
import '../providers/heuristic_rules.dart';

/// Допустимые значения типа модели для ручного override.
abstract final class ModelTypes {
  static const String auto = 'auto';
  static const String text = 'text';
  static const String image = 'image';
  static const String video = 'video';
  static const String unknown = 'unknown';
}

/// Хранилище ручного override типа модели.
class ModelTypeOverrideStore {
  static const String _prefix = 'model_type_override_';

  ModelTypeOverrideStore._();

  static final ModelTypeOverrideStore instance = ModelTypeOverrideStore._();

  static String keyFor(String modelId) => '$_prefix${modelId.trim()}';

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
    } catch (_) {}
  }

  Future<void> clear(String modelId) async {
    final id = modelId.trim();
    if (id.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(keyFor(id));
    } catch (_) {}
  }

  /// Единый идентификатор подключения для каталога, настроек и генерации.
  static String? resolveConnectionId({String? baseUrl, String? apiKey}) {
    final url = (baseUrl ?? '').trim().toLowerCase();
    final key = (apiKey ?? '').trim();

    if (url.contains('polza.ai')) return 'polza';

    final pr = presets.active;
    if (pr != null &&
        pr.id != PresetStore.defaultPresetId &&
        pr.baseUrl.trim().isNotEmpty &&
        pr.apiKey.trim().isNotEmpty) {
      return 'preset:${pr.id}';
    }

    if (url.isEmpty || key.isEmpty) {
      if (polzaAuth.isAuthenticated &&
          polzaAuth.accessToken.trim().isNotEmpty) {
        return 'polza';
      }
      return null;
    }
    if (url.contains('routerai')) return 'routerai';
    if (pr != null &&
        pr.baseUrl.trim().isNotEmpty &&
        pr.apiKey.trim().isNotEmpty) {
      return 'preset:${pr.id}';
    }
    return 'global';
  }

  String? _connectionId() {
    final cfg = effectiveConfig();
    return resolveConnectionId(baseUrl: cfg.baseUrl, apiKey: cfg.apiKey);
  }

  /// Единый резолвер типа: ручной override, затем каталог с
  /// [CatalogTypeSources.catalog], иначе [ModelTypes.unknown].
  /// Эвристики и curated не используются.
  Future<String> resolveType(
    String modelId, {
    String? connectionId,
  }) async {
    final id = modelId.trim();
    if (id.isEmpty) return ModelTypes.unknown;
    final norm = HeuristicRules.normalize(id);
    final ov = await loadOverride(id) ??
        (norm.isNotEmpty && norm != id ? await loadOverride(norm) : null);
    if (ov != null) return ov;

    final cid = connectionId ?? _connectionId();
    if (cid == null) return ModelTypes.unknown;
    try {
      final entry = await providerCatalog.lookup(cid, id);
      if (entry.typeSource != CatalogTypeSources.catalog) {
        return ModelTypes.unknown;
      }
      final type = entry.type.trim().toLowerCase();
      switch (type) {
        case 'chat':
        case 'text':
        case 'tts':
        case 'stt':
        case 'embedding':
        case 'music':
        case 'classification':
          return ModelTypes.text;
        case 'image':
          return ModelTypes.image;
        case 'video':
          return ModelTypes.video;
        default:
          return ModelTypes.unknown;
      }
    } catch (_) {
      return ModelTypes.unknown;
    }
  }

  /// Совместимый алиас.
  Future<String> effectiveType(String modelId) => resolveType(modelId);
}
