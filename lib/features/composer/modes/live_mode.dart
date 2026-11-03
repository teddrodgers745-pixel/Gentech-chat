// Copyright (c) 2026 Minkail. All rights reserved.

import '../composer_mode.dart';

/// Режим композера для голосовых Live-моделей: вместо поля ввода
/// показывается кнопка запуска полноэкранного голосового чата.
class LiveMode extends ComposerMode {
  static const String modeId = 'live';

  const LiveMode();

  @override
  String get id => modeId;

  @override
  String get label => 'Голос';

  @override
  bool supports(ComposerTool tool) {
    switch (tool) {
      case ComposerTool.live:
        return true;
      case ComposerTool.send:
      case ComposerTool.stop:
      case ComposerTool.attach:
      case ComposerTool.mic:
      case ComposerTool.search:
      case ComposerTool.reasoning:
        return false;
    }
  }
}
