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

  const ActiveModelCapabilities({
    required this.modelId,
    required this.normalizedId,
    required this.kind,
    this.params,
    this.vision = false,
    this.reasoning = false,
    this.reasoningLevels = const [],
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

  @override
  String toString() =>
      'ActiveModelCapabilities($modelId, ${kind.name}, '
      'vision: $vision, reasoning: $reasoning)';
}
