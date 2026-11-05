// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';

import '../../app_state.dart';
import '../models/active_model_capabilities.dart';
import '../models/model_id_normalizer.dart';
import '../models/param_spec.dart';
import 'curated_parameter_catalog.dart';
import 'user_param_override_store.dart';

/// Реактивный контроллер «что умеет активная модель».
///
/// Модель принадлежит [PresetStore] (PresetController) — единственному
/// источнику истины: контроллер не хранит собственного поля модели,
/// геттер [currentModelId] читает модель активного пресета, а запись
/// ([setModel]) делегирует PresetStore.updateActivePresetModel.
///
/// Хранит снимок возможностей активной модели ([current]): нормализованный
/// идентификатор, вид (текст/изображение/видео/live/skip/unknown),
/// параметры генерации и флаги vision/reasoning. Подписан на смену
/// пресетов, поэтому чат перестраивается сразу после выбора другого
/// пресета либо смены модели в нём.
///
/// Источник параметров: пользовательский override ([UserParamOverrideStore])
/// имеет приоритет над курированным каталогом ([CuratedParameterCatalog]).
class ActiveModelController extends ChangeNotifier {
  /// [presetController] — владелец модели (обязателен: единственный
  /// источник истины). [overrides] можно подменить (например, в тестах);
  /// по умолчанию используется глобальное хранилище override.
  ///
  /// Каталог параметров отдельным параметром не принимается:
  /// [CuratedParameterCatalog] — справочник без экземпляров
  /// (abstract final class только со статическими методами), его статики
  /// вызываются напрямую.
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

  /// Модель, для которой в последний раз разрешались возможности
  /// (защита от повторного разрешения той же модели).
  String _resolvedFor = '';

  /// true, пока выполняется setModel: слушатель пресетов в это время
  /// не запускает собственное разрешение (защита от рекурсии).
  bool _resolving = false;

  /// Текущие возможности активной модели (никогда не null).
  ActiveModelCapabilities get current => _current;

  /// Активная модель. Читается напрямую из активного пресета
  /// (PresetStore.active.model) — единственного источника истины.
  /// Пустая строка — активного пресета нет (режим «Без пресета»).
  String get currentModelId => _presetController.active?.model ?? '';

  /// Смена активной модели: НЕ меняет локальное состояние, а делегирует
  /// запись владельцу — [PresetStore.updateActivePresetModel] — и затем
  /// разрешает возможности по новой модели.
  Future<void> setModel(
    String modelId, {
    bool vision = false,
    bool reasoning = false,
  }) async {
    _resolving = true;
    try {
      final owned = (_presetController.active?.model ?? '').trim();
      final incoming = modelId.trim();
      if (incoming.isNotEmpty && incoming != owned) {
        await _presetController.updateActivePresetModel(modelId);
        notifyListeners();
      }
      await _resolve(modelId, vision: vision, reasoning: reasoning);
    } finally {
      _resolving = false;
    }
  }

  /// Слушатель [PresetStore]: смена активного пресета либо модели внутри
  /// пресета обновляет возможности без ручных опросов.
  Future<void> _onPresetChanged() async {
    if (_resolving) return;
    final id = _presetController.active?.model ?? '';
    if (id.trim() == _resolvedFor) {
      notifyListeners();
      return;
    }
    await _resolve(id);
  }

  /// Разрешает возможности модели [modelId].
  ///
  /// Параметры: override пользователя, иначе курированный каталог
  /// (при необходимости каталог догружается лениво). [vision] и
  /// [reasoning] передаёт вызывающий код — из каталога модели или из
  /// настроек. Любая ошибка хранилища/ассетов не роняет вызов: модель
  /// останется с пустыми параметрами и видом по эвристике.
  Future<void> _resolve(
    String modelId, {
    bool vision = false,
    bool reasoning = false,
  }) async {
    _resolvedFor = modelId.trim();
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
    final kind = _resolveKind(params, reasoning);
    _current = ActiveModelCapabilities(
      modelId: modelId,
      normalizedId: norm,
      kind: kind,
      params: params,
      vision: vision,
      reasoning: reasoning,
      reasoningLevels: reasoning
          ? const <String>[
              'off', 'low', 'medium', 'high', 'xhigh', 'max',
            ]
          : const <String>[],
    );
    notifyListeners();
  }

  /// Вид модели по её параметрам:
  ///  1. параметров нет — текстовая (если известен reasoning), иначе unknown;
  ///  2. confidence 'skip' — служебная модель;
  ///  3. явный тип в параметрах ('image', 'video', 'live', 'text');
  ///  4. эвристика по наличию медиа-параметров: длительности — видео,
  ///     иначе пропорции/разрешения — изображение;
  ///  5. остальное — текстовая модель.
  ActiveModelKind _resolveKind(ModelParameters? p, bool reasoning) {
    if (p == null) {
      return reasoning ? ActiveModelKind.text : ActiveModelKind.unknown;
    }
    if (p.confidence == 'skip') return ActiveModelKind.skip;
    final type = p.type;
    if (type != null) {
      switch (type) {
        case 'image':
          return ActiveModelKind.image;
        case 'video':
          return ActiveModelKind.video;
        case 'live':
          return ActiveModelKind.live;
        case 'text':
          return ActiveModelKind.text;
      }
    }
    final hasMedia =
        p.aspectRatios.isNotEmpty || p.durations != null || p.resolutions.isNotEmpty;
    if (hasMedia) {
      return p.durations != null ? ActiveModelKind.video : ActiveModelKind.image;
    }
    return ActiveModelKind.text;
  }

  @override
  void dispose() {
    _presetController.removeListener(_onPresetChanged);
    super.dispose();
  }
}
