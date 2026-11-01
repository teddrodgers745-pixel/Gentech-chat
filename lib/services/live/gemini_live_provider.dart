// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gemini_live/gemini_live.dart';

import 'live_provider.dart';

/// Live-провайдер для Gemini Live API на базе пакета gemini_live.
///
/// Реализует контракт [LiveProvider]:
///  - [connect] создаёт [GeminiLiveSessionController] для модели
///    'gemini-3.8-live' и открывает realtime-сессию с переданным ключом;
///  - [sendAudio] отправляет фрагмент микрофонного PCM (16 кГц, 16-bit, mono)
///    через sendRealtimeAudio контроллера;
///  - [audioStream] отдаёт входящие PCM-байты ответа модели
///    (24 кГц) из incomingAudioStream контроллера.
///
/// Ключ передаётся параметром [connect] и не сохраняется и не логируется.
class GeminiLiveProvider extends LiveProvider {
  /// Модель Live-режима (native-audio: вход PCM 16 кГц, выход PCM 24 кГц).
  static const String modelId = 'gemini-3.8-live';

  GeminiLiveSessionController? _controller;

  /// Подписка на пересылку входящего аудио контроллера в общий поток.
  StreamSubscription<List<int>>? _forwardSub;

  /// Broadcast-поток входящего аудио для интерфейса. Экран Live-режима
  /// подписывается на [audioStream] до вызова [connect], поэтому данные
  /// из incomingAudioStream контроллера пересылаются сюда: подписка
  /// не теряется между сессиями и при повторном подключении.
  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get audioStream => _audioController.stream;

  @override
  Future<void> connect(String apiKey) async {
    // Повторный connect закрывает предыдущую сессию.
    await disconnect();

    final controller = GeminiLiveSessionController(model: modelId);
    _controller = controller;

    _forwardSub = controller.incomingAudioStream.listen(
      (List<int> chunk) {
        if (!_audioController.isClosed && chunk.isNotEmpty) {
          _audioController.add(chunk);
        }
      },
      onError: (Object error) {
        if (!_audioController.isClosed) _audioController.addError(error);
      },
      cancelOnError: false,
    );

    // В зависимости от версии пакета connect может вернуть Future либо void:
    // обрабатываем оба варианта без привязки к типу результата.
    final dynamic connectResult = controller.connect(apiKey);
    if (connectResult is Future) await connectResult;
    debugPrint('GeminiLiveProvider: сессия открыта (модель $modelId)');
  }

  @override
  Future<void> sendAudio(List<int> pcmBytes) async {
    if (pcmBytes.isEmpty) return;
    final controller = _controller;
    if (controller == null) return;
    try {
      controller.sendRealtimeAudio(pcmBytes);
    } catch (e) {
      debugPrint('GeminiLiveProvider: ошибка отправки аудио: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    final sub = _forwardSub;
    _forwardSub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      try {
        final dynamic result = controller.disconnect();
        if (result is Future) await result;
      } catch (e) {
        debugPrint('GeminiLiveProvider: ошибка закрытия сессии: $e');
      }
    }
  }
}
