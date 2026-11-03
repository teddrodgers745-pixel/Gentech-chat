// Copyright (c) 2026 Minkail. All rights reserved.

import '../../core/models/model_info.dart';

/// Инструменты, доступные панели ввода (композера).
/// Какой из них показывать, решает активный [ComposerMode].
enum ComposerTool {
  send,
  stop,
  attach,
  mic,
  search,
  reasoning,
  live,
}

/// Режим панели ввода: набор инструментов, доступных пользователю,
/// и название режима. Конкретные режимы (TextMode и будущие) реализуют
/// этот интерфейс и регистрируются в [ComposerModeRegistry].
abstract class ComposerMode {
  const ComposerMode();

  /// Стабильный идентификатор режима ('text', 'image', ...).
  String get id;

  /// Название режима по-русски.
  String get label;

  /// Поддерживает ли режим данный инструмент (показывать ли кнопку).
  bool supports(ComposerTool tool);

  /// Приоритет выбора режима: чем больше число, тем выше режим стоит
  /// при подборе под модель. По умолчанию 0.
  int get priority => 0;

  /// Подходит ли режим модели с данными модальностями выхода.
  /// По умолчанию — нет; конкретные режимы переопределяют.
  bool supportsModel(Set<Modality> outputModalities) => false;
}
