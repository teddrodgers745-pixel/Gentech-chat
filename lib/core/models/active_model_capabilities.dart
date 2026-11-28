// Copyright (c) 2026 Minkail. All rights reserved.

import 'param_spec.dart';

/// Вид активной модели: что она умеет делать.
///
///  - [text] — обычная текстовая (чат) модель;
///  - [image] — генератор изображений;
///  - [video] — генератор видео (асинхронная задача);
///  - [live] — голосовой realtime-режим;
///  - [skip] — служебная модель (озвучка, апскейл и т.п.), параметры
///    генерации ей не нужны;
///  - [unknown] — модель неизвестна каталогу и override.
enum ActiveModelKind { text, image, video, live, skip, unknown }

/// Центральный объект «что умеет активная модель».
///
/// Снимок возможностей: исходный и нормализованный идентификаторы,
/// вид модели, параметры генерации (пропорции, длительности, разрешения)
/// и флаги приёма изображений (vision) и размышлений (reasoning).
/// Объект неизменяемый: при смене модели контроллер создаёт новый.
class ActiveModelCapabilities {
  /// Идентификатор модели, как его понимает провайдер.
  final String modelId;

  /// Нормализованный идентификатор ([ModelIdNormalizer]): нижний регистр,
  /// без суффиксов '@provider=...' и ':free'.
  final String normalizedId;

  /// Вид модели.
  final ActiveModelKind kind;

  /// Параметры генерации; null — модель неизвестна каталогу и override.
  final ModelParameters? params;

  /// Принимает изображения на вход (мультимодальный ввод).
  final bool vision;

  /// Умеет «размышлять» (reasoning/thinking).
  final bool reasoning;

  /// Доступные уровни размышлений ('off', 'low', 'medium', 'high');
  /// пустой список — размышления не поддерживаются.
  final List<String> reasoningLevels;

  /// Уровень по умолчанию из каталога (default_effort).
  /// '' — каталог не сообщил; в этом случае используется первый
  /// допустимый уровень (после сохранённого пользовательского).
  final String reasoningDefault;

  /// Разрешено ли отключение размышлений ('none'/'off').
  /// false — mandatory: размышления включены всегда, каталог не разрешает
  /// выбрать none/off.
  final bool reasoningNoneAllowed;

  /// Умеет ли модель искать в интернете сама (нативный веб-поиск
  /// провайдера/модели). Определяется [SearchCapabilityResolver]
  /// по каталогу и fallback-префиксу; false — нативного поиска нет.
  final bool supportsNativeSearch;

  /// G2-media-references: максимум референсных изображений, который
  /// каталог разрешает передать медиа-модели (Polza parameters.images.max,
  /// например 7 у grok-imagine-video-1-5 на эндпоинте /api/v1/media).
  /// null — каталог не сообщил лимит: скрепка референсов в медиа-композере
  /// скрыта, изображения в запрос не передаются.
  final int? maxReferenceImages;

  const ActiveModelCapabilities({
    required this.modelId,
    required this.normalizedId,
    required this.kind,
    this.params,
    this.vision = false,
    this.reasoning = false,
    this.reasoningLevels = const [],
    this.reasoningDefault = '',
    this.reasoningNoneAllowed = true,
    this.supportsNativeSearch = false,
    this.maxReferenceImages,
  });

  /// Пустое состояние: модель ещё не выбрана.
  static const empty = ActiveModelCapabilities(
    modelId: '',
    normalizedId: '',
    kind: ActiveModelKind.unknown,
  );

  /// Модель ещё не разрешена (нет идентификатора и вид неизвестен).
  bool get isEmpty =>
      modelId.isEmpty && normalizedId.isEmpty && kind == ActiveModelKind.unknown;

  /// Есть ли у модели хоть один настраиваемый параметр генерации.
  bool get hasParams {
    final p = params;
    return p != null && p.hasAny;
  }

  /// G2-media-references: модель принимает референсные изображения
  /// (input.images POST /v1/media). true — скрепка и полоса миниатюр
  /// показываются в медиа-композере; false — скрыты.
  bool get supportsReferenceImages => (maxReferenceImages ?? 0) > 0;

  @override
  String toString() =>
      'ActiveModelCapabilities($modelId, ${kind.name}, '
      'vision: $vision, reasoning: $reasoning, '
      'default: ${reasoningDefault.isEmpty ? '-' : reasoningDefault}, '
      'noneAllowed: $reasoningNoneAllowed, '
      'maxRefs: ${maxReferenceImages ?? '-'})';
}
