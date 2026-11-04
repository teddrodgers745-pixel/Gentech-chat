// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/active_model_capabilities.dart';
import '../../core/providers/heuristic_rules.dart';
import '../../models/model_config.dart';
import '../../widgets/inputs/image_gen_input.dart';
import '../../widgets/inputs/live_voice_input.dart';
import '../../widgets/inputs/text_chat_input.dart';
import 'composer_mode.dart';
import 'modes/image_gen_mode.dart';
import 'composer_registry.dart';
import 'modes/live_mode.dart';
import 'video_gen_input.dart';
import 'video_gen_mode.dart';

/// Адаптивная нижняя панель чата: активный режим ввода выбирается через
/// [ComposerModeRegistry] по типу [ModelConfig], панель переключается
/// плавно через [AnimatedSwitcher].
///
/// Текстовый режим рендерит прежний [TextChatInput] (поведение поля ввода
/// не меняется), голосовой — [LiveVoiceInput].
class AdaptiveChatInputBar extends StatelessWidget {
  final ModelConfig config;

  /// Возможности активной модели (вид, параметры генерации, vision,
  /// reasoning): пробрасываются в активную панель ввода.
  final ActiveModelCapabilities capabilities;
  final TextEditingController? controller;
  final bool streaming;
  final int reasoningLevel;
  final VoidCallback? onCycleReasoning;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onToggleMic;
  final VoidCallback? onAttach;
  final VoidCallback? onSend;
  final VoidCallback? onStop;
  final VoidCallback? onStartLive;

  /// Смена выбранной пропорции в режиме генерации изображений.
  final ValueChanged<String>? onAspectRatioChanged;

  /// Реестр режимов композера; null — стандартный реестр
  /// (текстовый и голосовой режимы).
  final ComposerModeRegistry? registry;

  /// Ручной override типа модели: '' (авто), 'text', 'image' либо 'video'.
  /// Задан — режим панели выбирается по нему, а не по эвристике.
  final String modelType;

  const AdaptiveChatInputBar({
    super.key,
    required this.config,
    required this.capabilities,
    this.controller,
    this.streaming = false,
    this.reasoningLevel = 0,
    this.onCycleReasoning,
    this.onToggleSearch,
    this.onToggleMic,
    this.onAttach,
    this.onSend,
    this.onStop,
    this.onStartLive,
    this.onAspectRatioChanged,
    this.registry,
    this.modelType = '',
  });

  /// Режим по типу модели: явный override типа имеет приоритет, затем
  /// live-модель — голосовой режим из реестра, модель-картинка — режим
  /// генерации изображений, видео-модель (kling, veo, sora ...) — режим
  /// генерации видео, всё остальное — режим по умолчанию (текстовый).
  static ComposerMode _resolveMode(
    ModelConfig config,
    ComposerModeRegistry reg,
    String modelId,
    String modelType,
  ) {
    if (config is LiveVoiceModelConfig) {
      final live = reg.byId(LiveMode.modeId);
      if (live != null) return live;
    }
    if (modelType == 'image') {
      final image = reg.byId(ImageGenMode.modeId);
      if (image != null) return image;
    }
    if (modelType == 'video') {
      final video = reg.byId(VideoGenMode.modeId);
      if (video != null) return video;
    }
    if (modelType == 'text') return reg.defaultMode;
    if (config is ImageGenModelConfig) {
      final image = reg.byId(ImageGenMode.modeId);
      if (image != null) return image;
    }
    final video = reg.byId(VideoGenMode.modeId);
    if (video != null &&
        video.supportsModel(HeuristicRules.build(modelId).outputModalities)) {
      return video;
    }
    return reg.defaultMode;
  }

  @override
  Widget build(BuildContext context) {
    final reg = registry ?? ComposerModeRegistry();
    final mode =
        _resolveMode(config, reg, effectiveConfig().model, modelType);
    final cfg = config;

    final Widget child;
    if (mode.id == LiveMode.modeId) {
      final liveCfg = cfg is LiveVoiceModelConfig
          ? cfg
          : const LiveVoiceModelConfig();
      child = LiveVoiceInput(
        key: const ValueKey<String>('live_voice_input'),
        config: liveCfg,
        onStartLive: onStartLive,
      );
    } else if (mode.id == ImageGenMode.modeId) {
      final imageCfg = cfg is ImageGenModelConfig
          ? cfg
          : const ImageGenModelConfig(
              availableAspectRatios: <String>['1:1', '16:9', '9:16'],
            );
      child = ImageGenInput(
        key: const ValueKey<String>('image_gen_input'),
        config: imageCfg,
        capabilities: capabilities,
        controller: controller,
        streaming: streaming,
        onAspectRatioChanged: onAspectRatioChanged,
        onSend: onSend,
        onStop: onStop,
      );
    } else if (mode.id == VideoGenMode.modeId) {
      child = VideoGenInput(
        key: const ValueKey<String>('video_gen_input'),
        capabilities: capabilities,
        controller: controller,
        streaming: streaming,
        onSend: onSend,
        onStop: onStop,
      );
    } else {
      // Текстовый режим (а также генерация изображений: текстовый ввод
      // без вложений и поиска — прежнее поведение панели).
      final textCfg = cfg is TextModelConfig
          ? cfg
          : const TextModelConfig(
              supportsAttachments: false,
              supportsWebSearch: false,
            );
      child = TextChatInput(
        key: const ValueKey<String>('text_chat_input'),
        config: textCfg,
        capabilities: capabilities,
        controller: controller,
        streaming: streaming,
        reasoningLevel: reasoningLevel,
        onCycleReasoning: onCycleReasoning,
        onToggleSearch: onToggleSearch,
        onToggleMic: onToggleMic,
        onAttach: onAttach,
        onSend: onSend,
        onStop: onStop,
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: child,
    );
  }
}
