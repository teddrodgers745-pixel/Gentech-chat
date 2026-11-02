// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gemini_live/gemini_live.dart';

import '../../app_state.dart';
import 'live_provider.dart';

/// Live-провайдер для голосового режима поверх пакета gemini_live.
///
/// Реализует контракт [LiveProvider]:
///  - [connect] создаёт [GoogleGenAI] с переданным пользователем ключом,
///    инициализирует [GeminiLiveSessionController] и открывает сессию;
///  - [sendAudio] отправляет фрагмент микрофонного PCM
///    (16 кГц, 16-bit, mono) через [GeminiLiveSessionController.sendRealtimeAudio];
///  - [audioStream] отдаёт входящие PCM-байты ответа модели (24 кГц)
///    из [GeminiLiveSessionController.incomingAudioStream].
class GeminiLiveProvider extends LiveProvider {
  /// Модель Live-режима по умолчанию, если в настройках не выбрана Live-модель.
  static const String defaultModelId =
      'gemini-2.5-flash-native-audio-preview-12-2025';

  GeminiLiveSessionController? _controller;
  StreamSubscription<Uint8List>? _audioSub;

  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get audioStream => _audioController.stream;

  String _resolveModel() {
    final configured = effectiveConfig()
        .model
        .trim()
        .replaceFirst(RegExp(r'^models/', caseSensitive: false), '');
    final lower = configured.toLowerCase();
    if (configured.isNotEmpty &&
        (lower.contains('live') || lower.contains('native-audio'))) {
      return configured;
    }
    return defaultModelId;
  }

  @override
  Future<void> connect(String apiKey) async {
    await disconnect();

    final String trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) {
      throw StateError('API-ключ не задан');
    }

    final String model = _resolveModel();
    final GoogleGenAI genAI = GoogleGenAI(apiKey: trimmedKey);
    final GeminiLiveSessionController controller = GeminiLiveSessionController(
      liveService: genAI.live,
    );

    _audioSub = controller.incomingAudioStream.listen(
      (Uint8List bytes) {
        if (bytes.isEmpty || _audioController.isClosed) return;
        _audioController.add(bytes);
      },
      onError: (Object error) {
        debugPrint('GeminiLiveProvider: ошибка аудиопотока: $error');
        if (!_audioController.isClosed) {
          _audioController.addError(error);
        }
      },
      cancelOnError: false,
    );

    _controller = controller;

    try {
      await controller.connect(
        LiveConnectParameters(
          model: model,
          config: GenerationConfig(
            responseModalities: [Modality.AUDIO],
          ),
        ),
      );
      debugPrint('GeminiLiveProvider: сессия открыта (модель $model)');
    } catch (e) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<void> sendAudio(List<int> pcmBytes) async {
    if (pcmBytes.isEmpty) return;
    final GeminiLiveSessionController? controller = _controller;
    if (controller == null) return;
    try {
      final Uint8List data =
          pcmBytes is Uint8List ? pcmBytes : Uint8List.fromList(pcmBytes);
      controller.sendRealtimeAudio(data);
    } catch (e) {
      debugPrint('GeminiLiveProvider: ошибка отправки аудио: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    final StreamSubscription<Uint8List>? sub = _audioSub;
    _audioSub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }

    final GeminiLiveSessionController? controller = _controller;
    _controller = null;
    if (controller == null) return;

    try {
      await controller.disconnect();
    } catch (_) {}
    try {
      controller.dispose();
    } catch (_) {}
  }
}
