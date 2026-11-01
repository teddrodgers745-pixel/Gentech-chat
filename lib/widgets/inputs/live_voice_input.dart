// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models/model_config.dart';
import '../../screens/live_screen.dart';
import '../../services/tts_service.dart';
import '../../theme.dart';

/// Панель ввода для голосовых Live-моделей: крупная акцентная кнопка
/// «Начать голосовой чат», открывающая полноэкранный [LiveScreen].
class LiveVoiceInput extends StatelessWidget {
  final LiveVoiceModelConfig config;
  final VoidCallback? onStartLive;

  const LiveVoiceInput({
    super.key,
    this.config = const LiveVoiceModelConfig(),
    this.onStartLive,
  });

  void _openLive(BuildContext context) {
    if (onStartLive != null) {
      onStartLive!();
      return;
    }
    ttsService.stop();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LiveScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          child: Container(
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: p.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 15,
                  spreadRadius: 1,
                ),
              ],
            ),
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: () => _openLive(context),
                icon: Icon(
                  config.supportsVideoStream
                      ? Icons.videocam_rounded
                      : Icons.record_voice_over_rounded,
                  size: 22,
                ),
                label: Text(
                  'Начать голосовой чат',
                  style: fontStyle(
                    settings.bodyFont,
                    size: 16,
                    weight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
