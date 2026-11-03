// Copyright (c) 2026 Minkail. All rights reserved.

import '../composer_mode.dart';

/// Один вариант выбора в режиме композера (например, пропорция изображения).
/// Нейтральные данные: идентификатор и подпись по-русски.
class ChoiceSpec {
  /// Стабильный идентификатор варианта ('1:1', '16:9', ...).
  final String id;

  /// Подпись для интерфейса.
  final String label;

  const ChoiceSpec(this.id, this.label);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ChoiceSpec && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ChoiceSpec($id)';
}

/// Режим композера для моделей генерации изображений: вместо обычного
/// поля сообщения — промпт и выбор пропорций. Пропорции заданы списком
/// [ChoiceSpec] и используются панелью ввода режима.
class ImageGenMode extends ComposerMode {
  static const String modeId = 'image';

  /// Доступные пропорции изображения.
  static const List<ChoiceSpec> aspectRatios = <ChoiceSpec>[
    ChoiceSpec('1:1', '1:1'),
    ChoiceSpec('16:9', '16:9'),
    ChoiceSpec('9:16', '9:16'),
  ];

  const ImageGenMode();

  @override
  String get id => modeId;

  @override
  String get label => 'Изображение';

  @override
  bool supports(ComposerTool tool) {
    switch (tool) {
      case ComposerTool.send:
      case ComposerTool.stop:
        return true;
      case ComposerTool.attach:
      case ComposerTool.mic:
      case ComposerTool.search:
      case ComposerTool.reasoning:
      case ComposerTool.live:
        return false;
    }
  }
}
