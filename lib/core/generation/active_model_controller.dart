// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';

import '../models/active_model_capabilities.dart';
import '../models/model_id_normalizer.dart';
import '../models/param_spec.dart';
import 'curated_parameter_catalog.dart';
import 'user_param_override_store.dart';

/// Реактивный контроллер «что умеет активная модель».
///
/// Хранит снимок возможностей активной модели ([current]): нормализованный
/// идентификатор, вид (текст/изображение/видео/live/skip/unknown),
/// параметры генерации и флаги vision/reasoning. При каждом изменении
/// вызывается notifyListeners — интерфейс подписывается и перерисовывается
/// без ручных опросов.
///
/// Источник параметров: пользовательский override
/// ([UserParamOverrideStore]) имеет приоритет над курированным каталогом
/// ([CuratedParameterCatalog]).
class ActiveModelController extends ChangeNotifier {
  /// [overrides] можно подменить (например, в тестах); по умолчанию
  /// используется глобальное хранилище override.
  ///
  /// Каталог параметров отдельным параметром не принимается:
  /// [CuratedParameterCatalog] — справочник без экземпляров
  /// (abstract final class только со статическими методами), его статики
  /// вызываются напрямую.
  ActiveModelController({UserParamOverrideStore? overrides})
      : _overrides = overrides ?? userParamOverrideStore;

  final UserParamOverrideStore _overrides;

  ActiveModelCapabilities _current = ActiveModelCapabilities.empty;

  /// Текущие возможности активной модели (никогда не null).
  ActiveModelCapabilities get current => _current;

  /// Разрешает возможности модели [modelId].
  ///
  /// Параметры: override пользователя, иначе курированный каталог
  /// (при необходимости каталог догружается лениво). [vision] и
  /// [reasoning] передаёт вызывающий код — из каталога модели или из
  /// настроек. Любая ошибка хранилища/ассетов не роняет вызов: модель
  /// останется с пустыми параметрами и видом по эвристике.
  Future<void> setModel(
    String modelId, {
    bool vision = false,
    bool reasoning = false,
  }) async {
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
}
