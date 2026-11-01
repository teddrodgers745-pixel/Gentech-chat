// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../models/model_config.dart';
import 'live_voice_input.dart';
import 'text_chat_input.dart';

/// Адаптивная нижняя панель чата: переключает интерфейс ввода
/// в зависимости от типа активной [ModelConfig] через [AnimatedSwitcher].
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
  });

  @override
  Widget build(BuildContext context) {
    final Widget child = switch (config) {
      final TextModelConfig textCfg => TextChatInput(
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
        ),
      final ImageGenModelConfig _ => TextChatInput(
          key: const ValueKey<String>('image_gen_input'),
          config: const TextModelConfig(
            supportsAttachments: false,
            supportsWebSearch: false,
          ),
          controller: controller,
          streaming: streaming,
          reasoningLevel: reasoningLevel,
          onCycleReasoning: onCycleReasoning,
          onToggleSearch: onToggleSearch,
          onToggleMic: onToggleMic,
          onAttach: onAttach,
          onSend: onSend,
          onStop: onStop,
        ),
      final LiveVoiceModelConfig liveCfg => LiveVoiceInput(
          key: const ValueKey<String>('live_voice_input'),
          config: liveCfg,
          onStartLive: onStartLive,
        ),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: child,
    );
  }
}
