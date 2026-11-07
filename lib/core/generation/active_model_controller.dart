// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';

import '../../app_state.dart';
import '../models/active_model_capabilities.dart';
import '../models/model_id_normalizer.dart';
import '../models/model_info.dart';
import '../models/model_presets.dart';
import '../models/param_spec.dart';
import '../providers/heuristic_rules.dart';
import 'curated_parameter_catalog.dart';
import 'generation_capability_resolver.dart';
import 'model_type_override_store.dart';
import 'reasoning_capability_resolver.dart';
import 'user_param_override_store.dart';

/// Реактивный контроллер «что умеет активная модель».
///
/// Модель принадлежит [PresetStore] — единственному источнику истины:
/// геттер [currentModelId] читает модель активного пресета, запись
/// ([setModel]) делегирует PresetStore.updateActivePresetModel.
class ActiveModelController extends ChangeNotifier {
  ActiveModelController({
    required PresetStore presetController,
    UserParamOverrideStore? overrides,
  })  : _presetController = presetController,
        _overrides = overrides ?? userParamOverrideStore {
    _presetController.addListener(_onPresetChanged);
  }

  static const List<String> _videoNameHints = <String>[
    'seedance',
    'kling',
    'sora',
    'veo',
    'runway',
    'wan',
    'hailuo',
  ];

  static const List<String> _imageNameHints = <String>[
    'flux',
    'dall-e',
    'dalle',
    'midjourney',
    'stable-diffusion',
    'stablediffusion',
  ];

  final PresetStore _presetController;
  final UserParamOverrideStore _overrides;

  ActiveModelCapabilities _current = ActiveModelCapabilities.empty;

  bool _resolving = false;
  int _resolveToken = 0;

  ActiveModelCapabilities get current => _current;

  String get currentModelId => _presetController.activePreset?.model ?? '';

  Future<void> setModel(
    String modelId, {
    bool vision = false,
    bool reasoning = false,
  }) async {
    _resolving = true;
    try {
      final owned = currentModelId.trim();
      final incoming = modelId.trim();
      if (incoming.isNotEmpty && incoming != owned) {
        await _presetController.updateActivePresetModel(incoming);
        notifyListeners();
      }
      final target = currentModelId.isNotEmpty ? currentModelId : incoming;
      await _resolve(target, vision: vision, reasoning: reasoning);
    } finally {
      _resolving = false;
    }
  }

  Future<void> syncModel(
    String modelId, {
    bool? vision,
    bool? reasoning,
  }) async {
    final id = modelId.trim();
    final inferredVision = vision ?? _inferVision(id);
    final inferredReasoning = reasoning ?? await _inferReasoning(id);
    await _resolve(
      id,
      vision: inferredVision,
      reasoning: inferredReasoning,
    );
  }

  Future<void> _onPresetChanged() async {
    if (_resolving) return;
    final presetModel = _presetController.active?.model.trim() ?? '';
    final id = presetModel.isNotEmpty ? presetModel : settings.model.trim();
    final vision = _inferVision(id);
    final reasoning = await _inferReasoning(id);
    await _resolve(id, vision: vision, reasoning: reasoning);
  }

  static bool _inferVision(String modelId) {
    if (modelId.isEmpty) return false;
    final id = HeuristicRules.normalize(modelId);
    return HeuristicRules.inferInputModalities(id).contains(Modality.image);
  }

  static Future<bool> _inferReasoning(String modelId) async {
    if (modelId.isEmpty) return false;
    final norm = HeuristicRules.normalize(modelId);
    var reasoning = HeuristicRules.inferSupportsReasoning(norm);
    if (!reasoning) {
      try {
        final ps = await ModelPresets.load();
        reasoning = ps.forModel(modelId)?.reasoning ?? false;
      } catch (_) {}
    }
    return reasoning;
  }

  static bool isHeuristicVideo(String rawId) {
    final lower = HeuristicRules.normalize(rawId).toLowerCase();
    if (lower.isEmpty) return false;
    if (lower.contains('wanx')) return false;
    for (final h in _videoNameHints) {
      if (lower.contains(h)) return true;
    }
    return HeuristicRules.inferRoute(lower) == GenerationRoute.asyncJob;
  }

  static bool isHeuristicImage(String rawId) {
    final lower = HeuristicRules.normalize(rawId).toLowerCase();
    if (lower.isEmpty) return false;
    if (isHeuristicVideo(lower) && !lower.contains('wanx')) return false;
    for (final h in _imageNameHints) {
      if (lower.contains(h)) return true;
    }
    return HeuristicRules.inferRoute(lower) == GenerationRoute.imageGeneration;
  }

  static bool isHeuristicSearch(String rawId) {
    final lower = HeuristicRules.normalize(rawId).toLowerCase();
    return lower.contains('sonar');
  }

  /// Принудительный поиск параметров модели в пользовательских override,
  /// курированном каталоге и ModelPresets (включая поиск без префикса
  /// провайдера и по совпадению семейства).
  Future<ModelParameters?> _lookupCatalogParams(
    String rawModelId,
    String norm,
  ) async {
    if (norm.isEmpty && rawModelId.trim().isEmpty) return null;
    final trimmed = rawModelId.trim();
    final shortId = ModelIdNormalizer.withoutProviderPrefix(
      norm.isNotEmpty ? norm : trimmed,
    );
    final candidates = <String>{
      if (norm.isNotEmpty) norm,
      if (trimmed.isNotEmpty) trimmed,
      if (shortId.isNotEmpty) shortId,
    };

    for (final c in candidates) {
      try {
        final ov = await _overrides.load(c);
        if (ov != null && ov.hasAny) return ov;
      } catch (_) {}
    }

    try {
      if (!CuratedParameterCatalog.isLoaded) {
        await CuratedParameterCatalog.load();
      }
      for (final c in candidates) {
        final found = CuratedParameterCatalog.byId(c);
        if (found != null && (found.hasAny || found.confidence == 'skip')) {
          return found;
        }
      }
    } catch (_) {}

    try {
      final ps = await ModelPresets.load();
      ModelPreset? preset;
      for (final c in candidates) {
        preset = ps.forModel(c);
        if (preset != null) break;
      }
      if (preset == null && shortId.isNotEmpty) {
        for (final item in ps.all) {
          final itemShort = ModelIdNormalizer.withoutProviderPrefix(item.id);
          if (itemShort == shortId ||
              shortId.contains(itemShort) ||
              itemShort.contains(shortId)) {
            if (item.isMedia) {
              preset = item;
              break;
            }
          }
        }
      }
      if (preset != null && preset.isMedia) {
        return ModelParameters(
          type: preset.type,
          aspectRatios: List<String>.of(preset.aspectRatios),
          durations: preset.durations.isEmpty
              ? null
              : DurationRange(discrete: List<int>.of(preset.durations)),
          resolutions: List<String>.of(preset.resolutions),
          confidence: 'auto',
          isUserDefined: false,
        );
      }
    } catch (_) {}

    return null;
  }

  /// Гарантирует дефолтные параметры для медиа-моделей (видео/картинки),
  /// если в каталоге точной записи не нашлось или в ней нет пропорций/длительностей.
  static ModelParameters defaultMediaParams(
    ActiveModelKind kind,
    String normalizedId,
    ModelParameters? existing,
  ) {
    final lower = normalizedId.toLowerCase();
    if (kind == ActiveModelKind.video) {
      final ratios = (existing != null && existing.aspectRatios.isNotEmpty)
          ? existing.aspectRatios
          : (lower.contains('veo') || lower.contains('sora')
              ? const <String>['16:9', '9:16']
              : const <String>['16:9', '9:16', '1:1']);
      final durations = (existing?.durations != null &&
              !existing!.durations!.isEmpty)
          ? existing.durations
          : DurationRange(
              discrete: lower.contains('sora')
                  ? const <int>[4, 8, 12]
                  : lower.contains('veo') || lower.contains('seedance')
                      ? const <int>[5, 8]
                      : const <int>[5, 10],
            );
      final resolutions = (existing != null && existing.resolutions.isNotEmpty)
          ? existing.resolutions
          : const <String>['720p', '1080p'];
      return ModelParameters(
        type: 'video',
        aspectRatios: List<String>.of(ratios),
        durations: durations,
        resolutions: List<String>.of(resolutions),
        sizes: existing?.sizes ?? const <String>[],
        qualities: existing?.qualities ?? const <String>[],
        constraints: existing?.constraints ?? const <String>[],
        confidence: existing?.confidence ?? 'auto',
        isUserDefined: existing?.isUserDefined ?? false,
      );
    }
    if (kind == ActiveModelKind.image) {
      final ratios = (existing != null && existing.aspectRatios.isNotEmpty)
          ? existing.aspectRatios
          : (lower.contains('flux')
              ? const <String>['1:1', '16:9', '9:16', '4:3', '3:4']
              : const <String>['1:1', '16:9', '9:16']);
      return ModelParameters(
        type: 'image',
        aspectRatios: List<String>.of(ratios),
        durations: null,
        resolutions: existing?.resolutions ?? const <String>[],
        sizes: existing?.sizes ?? const <String>[],
        qualities: existing?.qualities ?? const <String>[],
        constraints: existing?.constraints ?? const <String>[],
        confidence: existing?.confidence ?? 'auto',
        isUserDefined: existing?.isUserDefined ?? false,
      );
    }
    return existing ?? ModelParameters.unknown();
  }

  Future<void> _resolve(
    String modelId, {
    bool vision = false,
    bool reasoning = false,
  }) async {
    final token = ++_resolveToken;
    final norm = ModelIdNormalizer.normalize(modelId);
    // Приоритет 1: кэш GenerationCapabilityResolver (каталог OpenRouter:
    // медиа-параметры видео и изображений). Данные помечаются
    // confidence='openrouter'; если модели в кэше нет —
    // приоритет 2: пользовательские override, курированный каталог
    // и пресеты моделей (_lookupCatalogParams).
    ModelParameters? params;
    try {
      // Догрузка дискового кэша: no-op, если уже загружен в main.dart.
      await GenerationCapabilityResolver.loadCache();
    } catch (_) {
      // Кэш недоступен — продолжаем с каталогом/пресетами.
    }
    final genCap = GenerationCapabilityResolver.getCapability(norm);
    if (genCap != null) {
      params = _withConfidence(genCap, 'openrouter');
    }
    params ??= await _lookupCatalogParams(modelId, norm);

    String? typeOverride;
    try {
      typeOverride =
          await ModelTypeOverrideStore.instance.loadOverride(modelId);
      if (typeOverride == null && norm.isNotEmpty && norm != modelId.trim()) {
        typeOverride =
            await ModelTypeOverrideStore.instance.loadOverride(norm);
      }
    } catch (_) {
      typeOverride = null;
    }
    if (token != _resolveToken) return;

    final kind = _resolveKind(norm, params, typeOverride);

    if (kind == ActiveModelKind.video || kind == ActiveModelKind.image) {
      params ??= await _lookupCatalogParams(modelId, norm);
      if (params == null ||
          !params.hasAny ||
          (kind == ActiveModelKind.video &&
              (params.durations == null || params.durations!.isEmpty))) {
        params = defaultMediaParams(kind, norm, params);
      }
    }

    if (isHeuristicSearch(norm) && settings.searchMode == 'off') {
      settings.setSearchMode('native');
    }

    final isText = kind == ActiveModelKind.text;
    final supportsReasoning = isText && reasoning;
    final reasoningLevels = supportsReasoning
        ? await _reasoningLevelsFor(norm)
        : const <String>['off'];
    // Защита от гонки: за время await модель могла смениться again.
    if (token != _resolveToken) return;
    _current = ActiveModelCapabilities(
      modelId: modelId,
      normalizedId: norm,
      kind: kind,
      params: params,
      vision: vision || isText,
      reasoning: supportsReasoning,
      reasoningLevels: reasoningLevels,
    );
    notifyListeners();
  }

  /// Точные уровни размышлений активной модели из
  /// [ReasoningCapabilityResolver] (кэш каталога OpenRouter) вместо
  /// прежнего фиксированного списка ['off', 'medium', 'high'].
  ///
  /// Правила:
  ///  - levels берутся из cap.supportedEfforts как есть;
  ///  - если cap.mandatory == true (размышления обязательны), уровни
  ///    'none' и 'off' убираются из списка доступных для показа;
  ///  - cap.defaultEffort сохраняется как рекомендуемый по умолчанию:
  ///    он остаётся в списке, а если после фильтрации список опустел —
  ///    возвращается одним уровнем;
  ///  - для моделей без данных в кэше резолвер отдаёт fallback
  ///    (['off', 'medium', 'high']) — прежнее поведение сохранено;
  ///  - любая ошибка резолвера не роняет разрешение модели.
  Future<List<String>> _reasoningLevelsFor(String normId) async {
    try {
      // Догрузка дискового кэша: no-op, если уже загружен. Гарантирует,
      // что getCapability увидит данные даже до фоновой синхронизации.
      await ReasoningCapabilityResolver.loadCache();
      final cap = ReasoningCapabilityResolver.getCapability(normId);
      final levels = <String>[...cap.supportedEfforts];
      if (cap.mandatory) {
        levels.removeWhere((l) => l == 'none' || l == 'off');
      }
      if (levels.isNotEmpty) return levels;
      final def = cap.defaultEffort.trim();
      if (def.isNotEmpty) return <String>[def];
    } catch (_) {
      // Резолвер недоступен — используем базовый список уровней ниже.
    }
    return const <String>['off', 'medium', 'high'];
  }

  /// Копия [ModelParameters] с заменённой достоверностью данных.
  /// Кэш Generation сохраняет записи с confidence='high'; контроллер
  /// помечает использованные из него данные как 'openrouter'.
  static ModelParameters _withConfidence(
    ModelParameters p,
    String confidence,
  ) {
    return ModelParameters(
      aspectRatios: List<String>.of(p.aspectRatios),
      durations: p.durations,
      resolutions: List<String>.of(p.resolutions),
      sizes: List<String>.of(p.sizes),
      qualities: List<String>.of(p.qualities),
      constraints: List<String>.of(p.constraints),
      type: p.type,
      confidence: confidence,
      isUserDefined: p.isUserDefined,
    );
  }

  /// Данные кэша Generation для модели; null — записи нет либо резолвер
  /// недоступен. Ошибки не роняют разрешение модели.
  static ModelParameters? _genCapabilityQuietly(String normId) {
    try {
      return GenerationCapabilityResolver.getCapability(normId);
    } catch (_) {
      return null;
    }
  }

  ActiveModelKind _resolveKind(
    String normalizedId,
    ModelParameters? p,
    String? typeOverride,
  ) {
    if (p != null && p.confidence == 'skip') return ActiveModelKind.skip;
    switch (typeOverride) {
      case 'image':
        return ActiveModelKind.image;
      case 'video':
        return ActiveModelKind.video;
      case 'text':
        return ActiveModelKind.text;
    }
    // Кэш Generation (OpenRouter): если для модели известны длительности
    // видео — это видео-модель. Ручной override типа (выше) всё ещё
    // имеет приоритет над кэшем.
    final genCap = _genCapabilityQuietly(normalizedId);
    if (genCap != null) {
      final d = genCap.durations;
      if (d != null && !d.isEmpty) return ActiveModelKind.video;
    }
    if (p != null) {
      switch (p.type) {
        case 'image':
          return ActiveModelKind.image;
        case 'video':
          return ActiveModelKind.video;
        case 'live':
          return ActiveModelKind.live;
        case 'text':
          if (!isHeuristicVideo(normalizedId) &&
              !isHeuristicImage(normalizedId)) {
            return ActiveModelKind.text;
          }
      }
      final hasMedia = p.aspectRatios.isNotEmpty ||
          p.durations != null ||
          p.resolutions.isNotEmpty;
      if (hasMedia) {
        return (p.durations != null && !p.durations!.isEmpty) ||
                isHeuristicVideo(normalizedId)
            ? ActiveModelKind.video
            : ActiveModelKind.image;
      }
    }
    if (normalizedId.isNotEmpty) {
      final lower = normalizedId.toLowerCase();
      if (lower.contains('live') || lower.contains('native-audio')) {
        return ActiveModelKind.live;
      }
      if (isHeuristicVideo(lower)) {
        return ActiveModelKind.video;
      }
      if (isHeuristicImage(lower)) {
        return ActiveModelKind.image;
      }
      final route = HeuristicRules.inferRoute(
        HeuristicRules.normalize(normalizedId),
      );
      if (route == GenerationRoute.asyncJob) {
        return ActiveModelKind.video;
      }
      if (route == GenerationRoute.imageGeneration) {
        return ActiveModelKind.image;
      }
    }
    return ActiveModelKind.text;
  }

  @override
  void dispose() {
    _presetController.removeListener(_onPresetChanged);
    super.dispose();
  }
}
