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
import 'model_type_override_store.dart';
import 'user_param_override_store.dart';

/// Реактивный контроллер «что умеет активная модель».
///
/// Модель принадлежит [PresetStore] — единственному источнику истины:
/// геттер [currentModelId] читает модель активного пресета, запись
/// ([setModel]) делегирует PresetStore.updateActivePresetModel.
///
/// Два способа обновления:
///  - [setModel] — пользовательская смена модели (пишет в PresetStore
///    и разрешает возможности);
///  - [syncModel] — реактивная синхронизация с эффективной моделью
///    (выбор пресета в настройках, режим «Без пресета»): НЕ мутирует
///    PresetStore, а сразу запрашивает параметры новой модели из
///    override / курированного каталога.
///
/// Слушатель пресетов тоже вызывает полное разрешение возможностей,
/// поэтому чипсы панели ввода всегда соответствуют активной модели.
class ActiveModelController extends ChangeNotifier {
  ActiveModelController({
    required PresetStore presetController,
    UserParamOverrideStore? overrides,
  })  : _presetController = presetController,
        _overrides = overrides ?? userParamOverrideStore {
    _presetController.addListener(_onPresetChanged);
  }

  final PresetStore _presetController;
  final UserParamOverrideStore _overrides;

  ActiveModelCapabilities _current = ActiveModelCapabilities.empty;

  /// true, пока выполняется setModel: слушатель пресетов в это время
  /// не запускает собственное разрешение (защита от рекурсии).
  bool _resolving = false;

  /// Счётчик запросов разрешения для защиты от гонки асинхронных вызовов.
  int _resolveToken = 0;

  /// Текущие возможности активной модели (никогда не null).
  ActiveModelCapabilities get current => _current;

  /// Активная модель. Читается напрямую из активного пресета.
  /// Пустая строка — активного пресета нет (режим «Без пресета»).
  String get currentModelId => _presetController.activePreset?.model ?? '';

  /// Смена активной модели пользователем: делегирует запись владельцу —
  /// [PresetStore.updateActivePresetModel] — и разрешает возможности.
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

  /// Реактивная синхронизация с эффективной моделью (при выборе пресета
  /// в настройках либо переключении на «Без пресета»). Не мутирует
  /// [PresetStore], а запрашивает параметры модели из override /
  /// каталога и уведомляет слушателей.
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

  /// Слушатель [PresetStore]: смена активного пресета либо модели внутри
  /// пресета мгновенно запрашивает параметры новой модели из каталога
  /// и перестраивает подписанные виджеты (включая панель ввода в чате).
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

  /// Разрешает возможности модели [modelId].
  ///
  /// Параметры: override пользователя, иначе курированный каталог
  /// (при необходимости каталог догружается лениво). Любая ошибка
  /// хранилища/ассетов не роняет вызов: модель останется с пустыми
  /// параметрами и видом по эвристике.
  Future<void> _resolve(
    String modelId, {
    bool vision = false,
    bool reasoning = false,
  }) async {
    final token = ++_resolveToken;
    final norm = ModelIdNormalizer.normalize(modelId);
    ModelParameters? params;
    if (norm.isNotEmpty) {
      try {
        params = await _overrides.load(norm);
      } catch (_) {
        params = null;
      }
      if (params == null) {
        try {
          if (!CuratedParameterCatalog.isLoaded) {
            await CuratedParameterCatalog.load();
          }
          params = CuratedParameterCatalog.byId(norm);
        } catch (_) {
          params = null;
        }
      }
    }
    String? typeOverride;
    try {
      typeOverride =
          await ModelTypeOverrideStore.instance.loadOverride(modelId);
    } catch (_) {
      typeOverride = null;
    }
    if (token != _resolveToken) return;
    final kind = _resolveKind(norm, params, typeOverride);
    final isText = kind == ActiveModelKind.text;
    _current = ActiveModelCapabilities(
      modelId: modelId,
      normalizedId: norm,
      kind: kind,
      params: params,
      vision: vision || isText,
      reasoning: reasoning || isText,
      reasoningLevels: const <String>[
        'off',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ],
    );
    notifyListeners();
  }

  /// Вид модели: override типа пользователя -> явный тип из параметров ->
  /// медиа-эвристика по параметрам -> эвристика маршрута по идентификатору.
  /// По умолчанию любая рабочая модель считается текстовой: kind unknown
  /// для рабочих моделей больше не возвращается, поэтому панель ввода
  /// никогда не теряет капсулы, скрепку и микрофон.
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
    if (p != null) {
      switch (p.type) {
        case 'image':
          return ActiveModelKind.image;
        case 'video':
          return ActiveModelKind.video;
        case 'live':
          return ActiveModelKind.live;
        case 'text':
          return ActiveModelKind.text;
      }
      final hasMedia = p.aspectRatios.isNotEmpty ||
          p.durations != null ||
          p.resolutions.isNotEmpty;
      if (hasMedia) {
        return p.durations != null
            ? ActiveModelKind.video
            : ActiveModelKind.image;
      }
    }
    if (normalizedId.isNotEmpty) {
      final lower = normalizedId.toLowerCase();
      if (lower.contains('live') || lower.contains('native-audio')) {
        return ActiveModelKind.live;
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
