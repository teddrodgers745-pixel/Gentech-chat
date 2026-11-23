// Copyright (c) 2026 Minkail. All rights reserved.

// ВНИМАНИЕ: это частичное исправление, не готовая реализация v6c.
// Маршрутизация в ChatScreen, повтор, обновление каталога и панель
// параметров остаются неисправленными. providerCatalog.lookup может
// синтезировать тип, поэтому этот файл не обеспечивает строгую проверку
// наличия исходного type в каталоге. Применять как завершённый фикс нельзя.
//
// Точный источник Cannot add to an unmodifiable list по приведённым
// исходникам установить не удалось; временная диагностика в исполнителе
// в этом частичном результате не добавлена.

import 'package:shared_preferences/shared_preferences.dart';

import '../../app_state.dart';
import '../auth/polza_auth_service.dart';
import '../catalog/provider_catalog_service.dart';
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
      // Хранилище недоступно — override не сохранится.
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

  /// Идентификатор активного подключения, соответствующий существующей
  /// логике ActiveModelController и GenerationService.
  String? _connectionId() {
    final pr = presets.active;
    if (pr != null &&
        pr.id != PresetStore.defaultPresetId &&
        pr.baseUrl.trim().isNotEmpty &&
        pr.apiKey.trim().isNotEmpty) {
      return 'preset:${pr.id}';
    }

    final cfg = effectiveConfig();
    final url = cfg.baseUrl.trim().toLowerCase();
    final key = cfg.apiKey.trim();
    if (url.isEmpty || key.isEmpty) {
      if (polzaAuth.isAuthenticated &&
          polzaAuth.accessToken.trim().isNotEmpty) {
        return 'polza';
      }
      return null;
    }
    if (url.contains('polza.ai')) return 'polza';
    if (url.contains('routerai')) return 'routerai';
    if (pr != null &&
        pr.baseUrl.trim().isNotEmpty &&
        pr.apiKey.trim().isNotEmpty) {
      return 'preset:${pr.id}';
    }
    return 'global';
  }

  /// Эффективный тип модели: ручной override, затем запись подключения,
  /// затем прежние резервные источники.
  ///
  /// Ограничение текущего API: lookup может дозаполнить пустой тип.
  /// Для строгой маршрутизации нужен доступ к исходной записи каталога.
  Future<String> effectiveType(String modelId) async {
    final id = modelId.trim();
    if (id.isEmpty) return ModelTypes.text;
    final norm = HeuristicRules.normalize(id);
    final ov = await loadOverride(id) ??
        (norm.isNotEmpty && norm != id ? await loadOverride(norm) : null);
    if (ov != null) return ov;

    final connectionId = _connectionId();
    if (connectionId != null) {
      try {
        final entry = await providerCatalog.lookup(connectionId, id);
        if (entry.capabilitiesSource == CatalogSources.connection) {
          final type = entry.type.trim().toLowerCase();
          switch (type) {
            case 'chat':
            case 'text':
              return ModelTypes.text;
            case 'image':
              return ModelTypes.image;
            case 'video':
              return ModelTypes.video;
            case '':
              break;
            default:
              return type;
          }
        }
      } catch (_) {
        // Каталог недоступен — остаются прежние резервные источники.
      }
    }

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
        // Каталог недоступен — используем прежний резерв ниже.
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
