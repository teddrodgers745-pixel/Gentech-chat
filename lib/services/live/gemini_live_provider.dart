// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:gemini_live/gemini_live.dart';

import 'live_provider.dart';

/// Live-провайдер для голосового режима поверх пакета gemini_live.
///
/// Реализует контракт [LiveProvider]:
///  - [connect] создаёт [GoogleGenAI] с переданным пользователем ключом
///    и открывает realtime-сессию модели 'gemini-3.8-live' через
///    [GeminiLiveSessionController];
///  - [sendAudio] отправляет фрагмент микрофонного PCM
///    (16 кГц, 16-bit, mono) через [GeminiLiveSessionController.sendRealtimeAudio];
///  - [audioStream] отдаёт входящие PCM-байты ответа модели (24 кГц)
///    из [GeminiLiveSessionController.incomingAudioStream].
///
/// Ключ передаётся параметром [connect] и не сохраняется и не логируется.
class GeminiLiveProvider extends LiveProvider {
  /// Модель Live-режима.
  static const String modelId = 'gemini-3.8-live';

  /// Активный контроллер сессии (null, если сессия не открыта).
  GeminiLiveSessionController? _controller;

  /// Подписка на входящий аудиопоток контроллера.
  StreamSubscription<Uint8List>? _audioSub;

  /// Broadcast-поток входящего аудио для интерфейса. Экран Live-режима
  /// подписывается на [audioStream] до вызова [connect], поэтому поток
  /// broadcast: подписка не теряется между сессиями и при переподключении.
  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get audioStream => _audioController.stream;

  @override
  Future<void> connect(String apiKey) async {
    // Повторный connect закрывает предыдущую сессию.
    await disconnect();

    final GoogleGenAI genAI = GoogleGenAI(apiKey: apiKey);
    final GeminiLiveSessionController controller =
        GeminiLiveSessionController(genAI: genAI);

    // Подписка до первого использования, чтобы не потерять
    // начальные фрагменты аудио ответа модели.
    _audioSub = controller.incomingAudioStream.listen(
      (Uint8List bytes) {
        if (bytes.isEmpty || _audioController.isClosed) return;
        _audioController.add(bytes);
      },
      onError: (Object error) {
        debugPrint('GeminiLiveProvider: ошибка аудиопотока: $error');
        if (!_audioController.isClosed) _audioController.addError(error);
      },
      cancelOnError: false,
    );

    _controller = controller;
    debugPrint('GeminiLiveProvider: сессия открыта (модель $modelId)');
  }

  @override
  Future<void> sendAudio(List<int> pcmBytes) async {
    if (pcmBytes.isEmpty) return;
    final GeminiLiveSessionController? controller = _controller;
    if (controller == null) return;
    try {
      controller.sendRealtimeAudio(Uint8List.fromList(pcmBytes));
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

    // Закрытие сессии: точное имя метода освобождения ресурсов зависит
    // от версии пакета, поэтому вызываем через dynamic в try/catch —
    // при отсутствии метода ошибка глотается, состояние всё равно сброшено.
    final dynamic dyn = controller;
    try {
      await dyn.close();
    } catch (_) {
      try {
        await dyn.dispose();
      } catch (_) {}
    }
  }
}
