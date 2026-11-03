// Copyright (c) 2026 Minkail. All rights reserved.

import '../../core/models/model_info.dart';
import 'composer_mode.dart';
import 'modes/image_gen_mode.dart';

/// Режим композера для видео-моделей (kling, veo, sora, wan ...):
/// промпт, выбор пропорций и длительности, референсный кадр.
/// Модель маршрута [GenerationRoute.asyncJob] отдаёт видео
/// ([Modality.video]) — под неё режим и подбирается.
class VideoGenMode extends ComposerMode {
  static const String modeId = 'video_gen';

  /// Доступные пропорции видео.
  static const List<ChoiceSpec> aspectRatios = <ChoiceSpec>[
    ChoiceSpec('16:9', '16:9'),
    ChoiceSpec('9:16', '9:16'),
    ChoiceSpec('1:1', '1:1'),
  ];

  /// Доступные длительности ролика.
  static const List<ChoiceSpec> durations = <ChoiceSpec>[
    ChoiceSpec('5s', '5 с'),
    ChoiceSpec('10s', '10 с'),
  ];

  const VideoGenMode();

  @override
  String get id => modeId;

  @override
  String get label => 'Видео';

  /// Приоритет выше базовых режимов: видео-модель всегда получает
  /// видео-режим, а не текстовый.
  @override
  int get priority => 20;

  @override
  bool supportsModel(Set<Modality> outputModalities) =>
      outputModalities.contains(Modality.video);

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
