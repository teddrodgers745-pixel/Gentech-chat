// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../models/model_config.dart';
import '../../widgets/inputs/live_voice_input.dart';
import '../../widgets/inputs/text_chat_input.dart';
import 'composer_mode.dart';
import 'composer_registry.dart';
import 'modes/live_mode.dart';

/// Адаптивная нижняя панель чата: активный режим ввода выбирается через
/// [ComposerModeRegistry] по типу [ModelConfig], панель переключается
/// плавно через [AnimatedSwitcher].
///
/// Текстовый режим рендерит прежний [TextChatInput] (поведение поля ввода
/// не меняется), голосовой — [LiveVoiceInput].
class AdaptiveChatInputBar extends StatelessWidget {
  final ModelConfig config;
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

  /// Реестр режимов композера; null — стандартный реестр
  /// (текстовый и голосовой режимы).
  final ComposerModeRegistry? registry;

  const AdaptiveChatInputBar({
    super.key,
    required this.config,
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
    this.registry,
  });

  /// Режим по типу модели: live-модель — голосовой режим из реестра,
  /// всё остальное — режим по умолчанию (текстовый).
  static ComposerMode _resolveMode(
    ModelConfig config,
    ComposerModeRegistry reg,
  ) {
    if (config is LiveVoiceModelConfig) {
      final live = reg.byId(LiveMode.modeId);
      if (live != null) return live;
    }
    return reg.defaultMode;
  }

  @override
  Widget build(BuildContext context) {
    final reg = registry ?? ComposerModeRegistry();
    final mode = _resolveMode(config, reg);
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
