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

/// Адаптивная нижняя панель чата: активный режим ввода выбирается строго
/// по виду активной модели ([ActiveModelCapabilities.kind]):
///  - image -> только [ImageGenInput] (пропорции, без длительностей);
///  - video -> только [VideoGenInput] (пропорции, длительности, разрешения);
///  - live  -> [LiveVoiceInput];
///  - skip  -> панель ввода не показывается ([SizedBox.shrink]);
///  - text/unknown -> [TextChatInput] (с учётом ручного override типа).
/// Ключи [ValueKey] содержат capabilities.modelId: при смене модели
/// Flutter полностью пересоздаёт виджет и сбрасывает прежний State.
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
  /// Учитывается только для text/unknown-моделей: явные виды image/video
  /// и skip имеют приоритет.
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

  /// Режим по типу модели (только для text/unknown): явный override типа
  /// имеет приоритет, затем live-модель — голосовой режим из реестра,
  /// модель-картинка — режим генерации изображений, видео-модель
  /// (kling, veo, sora ...) — режим генерации видео, всё остальное —
  /// режим по умолчанию (текстовый).
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
    final kind = capabilities.kind;

    Widget child;
    if (kind == ActiveModelKind.skip) {
      // Служебная модель (озвучка, апскейл и т.п.): панель ввода не нужна.
      return const SizedBox.shrink();
    } else if (kind == ActiveModelKind.image) {
      // Генератор изображений: ТОЛЬКО ImageGenInput (пропорции,
      // размеры и качество — без длительностей и слайдеров).
      final cfg = config;
      final imageCfg = cfg is ImageGenModelConfig
          ? cfg
          : const ImageGenModelConfig(
              availableAspectRatios: <String>['1:1', '16:9', '9:16'],
            );
      child = ImageGenInput(
        key: ValueKey<String>('image_gen_${capabilities.modelId}'),
        config: imageCfg,
        capabilities: capabilities,
        controller: controller,
        streaming: streaming,
        onAspectRatioChanged: onAspectRatioChanged,
        onSend: onSend,
        onStop: onStop,
      );
    } else if (kind == ActiveModelKind.video) {
      // Генератор видео: ТОЛЬКО VideoGenInput (пропорции, длительности,
      // разрешения). Рендерится, только если у модели есть видеопараметры:
      // kind==video присваивается лишь при известных длительностях либо
      // явном типе 'video'.
      child = VideoGenInput(
        key: ValueKey<String>('video_gen_${capabilities.modelId}'),
        capabilities: capabilities,
        controller: controller,
        streaming: streaming,
        onSend: onSend,
        onStop: onStop,
      );
    } else if (kind == ActiveModelKind.live) {
      // Голосовой realtime-режим.
      final cfg = config;
      final liveCfg =
          cfg is LiveVoiceModelConfig ? cfg : const LiveVoiceModelConfig();
      child = LiveVoiceInput(
        key: const ValueKey<String>('live_voice_input'),
        config: liveCfg,
        onStartLive: onStartLive,
      );
    } else {
      // Текстовая либо неизвестная модель: прежняя цепочка выбора
      // (для обычных моделей даёт TextChatInput, ручной override типа
      // пользователя сохранён).
      child = _buildTextLike(reg);
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: child,
    );
  }

  /// Панель ввода для text/unknown-моделей: прежнее поведение с выбором
  /// режима по конфигу и ручному override типа.
  Widget _buildTextLike(ComposerModeRegistry reg) {
    final cfg = config;
    final mode =
        _resolveMode(cfg, reg, effectiveConfig().model, modelType);

    if (mode.id == LiveMode.modeId) {
      final liveCfg = cfg is LiveVoiceModelConfig
          ? cfg
          : const LiveVoiceModelConfig();
      return LiveVoiceInput(
        key: const ValueKey<String>('live_voice_input'),
        config: liveCfg,
        onStartLive: onStartLive,
      );
    }
    if (mode.id == ImageGenMode.modeId) {
      final imageCfg = cfg is ImageGenModelConfig
          ? cfg
          : const ImageGenModelConfig(
              availableAspectRatios: <String>['1:1', '16:9', '9:16'],
            );
      return ImageGenInput(
        key: ValueKey<String>('image_gen_${capabilities.modelId}'),
        config: imageCfg,
        capabilities: capabilities,
        controller: controller,
        streaming: streaming,
        onAspectRatioChanged: onAspectRatioChanged,
        onSend: onSend,
        onStop: onStop,
      );
    }
    if (mode.id == VideoGenMode.modeId) {
      return VideoGenInput(
        key: ValueKey<String>('video_gen_${capabilities.modelId}'),
        capabilities: capabilities,
        controller: controller,
        streaming: streaming,
        onSend: onSend,
        onStop: onStop,
      );
    }

    // Текстовый режим (а также генерация изображений: текстовый ввод
    // без вложений и поиска — прежнее поведение панели).
    final textCfg = cfg is TextModelConfig
        ? cfg
        : const TextModelConfig(
            supportsAttachments: false,
            supportsWebSearch: false,
          );
    return TextChatInput(
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
}
