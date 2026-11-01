// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';

/// Конфигурация возможностей модели для адаптивного интерфейса ввода.
@immutable
sealed class ModelConfig {
  const ModelConfig();
}

/// Текстовая/мультимодальная чат-модель.
class TextModelConfig extends ModelConfig {
  final bool supportsAttachments;
  final bool supportsWebSearch;

  const TextModelConfig({
    this.supportsAttachments = true,
    this.supportsWebSearch = true,
  });
}

/// Модель генерации изображений.
class ImageGenModelConfig extends ModelConfig {
  final List<String> availableAspectRatios;
  final List<String> styles;

  const ImageGenModelConfig({
    this.availableAspectRatios = const <String>['1:1', '16:9', '9:16', '4:3'],
    this.styles = const <String>[],
  });
}

/// Модель голосового Live-общения в реальном времени.
class LiveVoiceModelConfig extends ModelConfig {
  final bool supportsVideoStream;

  const LiveVoiceModelConfig({
    this.supportsVideoStream = false,
  });
}
