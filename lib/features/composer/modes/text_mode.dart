// Copyright (c) 2026 Minkail. All rights reserved.

import '../composer_mode.dart';

/// Обычный текстовый режим композера: поле ввода сообщения,
/// отправка и остановка генерации, голосовой ввод и вложения.
/// Серверные инструменты (поиск, размышления, live) не показывает:
/// они добавляются отдельными режимами на следующих этапах.
class TextMode extends ComposerMode {
  const TextMode();

  @override
  String get id => 'text';

  @override
  String get label => 'Текст';

  @override
  bool supports(ComposerTool tool) {
    switch (tool) {
      case ComposerTool.send:
      case ComposerTool.stop:
      case ComposerTool.attach:
      case ComposerTool.mic:
        return true;
      case ComposerTool.search:
      case ComposerTool.reasoning:
      case ComposerTool.live:
        return false;
    }
  }
}
