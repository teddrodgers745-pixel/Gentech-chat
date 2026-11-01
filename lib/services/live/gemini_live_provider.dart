// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'live_provider.dart';

/// Live-провайдер для Gemini Live API (BidiGenerateContent over WebSocket).
///
/// Реализует контракт [LiveProvider]:
///  - [connect] открывает WebSocket-сессию и отправляет setup для модели
///    'gemini-2.5-flash-native-audio-preview-12-2025' с модальностью AUDIO;
///  - [sendAudio] отправляет фрагмент микрофонного PCM (16 кГц, 16-bit, mono)
///    в realtimeInput.mediaChunks (base64);
///  - [audioStream] отдаёт входящие PCM-байты ответа модели (24 кГц),
///    извлечённые из serverContent.modelTurn.parts[].inlineData.
///
/// Ключ передаётся параметром [connect] и не сохраняется и не логируется.
class GeminiLiveProvider extends LiveProvider {
  static const String _wsBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent';

  /// Модель Live-режима: native-audio, вход PCM 16 кГц, выход PCM 24 кГц.
  static const String modelId =
      'gemini-2.5-flash-native-audio-preview-12-2025';

  static const String _inputAudioMime = 'audio/pcm;rate=16000';
  static const String _outputAudioMime = 'audio/pcm;rate=24000';
  static const Duration _connectTimeout = Duration(seconds: 20);
  static const Duration _closeTimeout = Duration(seconds: 2);

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();

  /// true после начала закрытия сессии: входящие кадры игнорируются.
  bool _closing = false;

  @override
  Stream<List<int>> get audioStream => _audioController.stream;

  @override
  Future<void> connect(String apiKey) async {
    // Повторный connect закрывает предыдущую сессию.
    await disconnect();
    _closing = false;

    final ws = await WebSocket.connect(
      '$_wsBaseUrl?key=${Uri.encodeQueryComponent(apiKey)}',
    ).timeout(_connectTimeout);
    _ws = ws;
    ws.pingInterval = const Duration(seconds: 15);

    _wsSub = ws.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        debugPrint('GeminiLiveProvider: ошибка соединения: $error\n$stack');
      },
      onDone: () {
        debugPrint('GeminiLiveProvider: соединение закрыто');
      },
      cancelOnError: false,
    );

    final sent = _sendJson(<String, dynamic>{
      'setup': <String, dynamic>{
        'model': 'models/$modelId',
        'generationConfig': <String, dynamic>{
          'responseModalities': <String>['AUDIO'],
        },
      },
    });
    if (!sent) {
      await disconnect();
      throw StateError('GeminiLiveProvider: не удалось отправить setup');
    }
    debugPrint('GeminiLiveProvider: setup отправлен (модель $modelId)');
  }

  @override
  Future<void> sendAudio(List<int> pcmBytes) async {
    if (pcmBytes.isEmpty) return;
    // Отправляем фрагмент как есть: размер куска определяет вызывающий код
    // (поток микрофона уже приходит небольшими фрагментами).
    _sendJson(<String, dynamic>{
      'realtimeInput': <String, dynamic>{
        'mediaChunks': <Map<String, dynamic>>[
          <String, dynamic>{
            'mimeType': _inputAudioMime,
            'data': base64Encode(pcmBytes),
          },
        ],
      },
    });
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    final sub = _wsSub;
    _wsSub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      try {
        await ws.close().timeout(_closeTimeout);
      } catch (_) {}
    }
  }

  bool _sendJson(Map<String, dynamic> payload) {
    final ws = _ws;
    if (ws == null) return false;
    try {
      ws.add(jsonEncode(payload));
      return true;
    } catch (e) {
      debugPrint('GeminiLiveProvider: ошибка отправки: $e');
      return false;
    }
  }

  /// Приводит входящий кадр к строке: текстовые кадры — как есть,
  /// бинарные декодируются через utf8 (протокол шлёт JSON-текст).
  String? _frameToText(dynamic raw) {
    try {
      if (raw is String) return raw;
      if (raw is List<int>) return utf8.decode(raw, allowMalformed: true);
    } catch (_) {}
    return null;
  }

  void _onMessage(dynamic raw) {
    if (_closing) return;
    final text = _frameToText(raw);
    if (text == null) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final map = Map<String, dynamic>.from(decoded);

    final error = map['error'];
    if (error != null) {
      debugPrint('GeminiLiveProvider: ошибка сервера: $error');
      return;
    }
    // setupComplete и прочие служебные кадры аудио не несут — пропускаем.

    final content = map['serverContent'];
    if (content is! Map) return;
    final turn = content['modelTurn'];
    final parts = turn is Map ? turn['parts'] : null;
    if (parts is! List) return;

    for (final part in parts) {
      if (part is! Map) continue;
      final inline = part['inlineData'];
      if (inline is! Map) continue;
      final mime = (inline['mimeType'] as String?) ?? _outputAudioMime;
      final data = inline['data'];
      if (data is! String || data.isEmpty) continue;
      if (!mime.startsWith('audio/pcm')) continue;
      try {
        final bytes = base64Decode(data);
        if (bytes.isNotEmpty && !_audioController.isClosed) {
          _audioController.add(bytes);
        }
      } catch (e) {
        debugPrint('GeminiLiveProvider: битый аудио-фрагмент: $e');
      }
    }
  }
}
