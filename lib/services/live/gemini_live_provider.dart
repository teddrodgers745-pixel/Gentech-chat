// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'live_provider.dart';

/// Live-провайдер для Gemini Live API: прямой WebSocket
/// (BidiGenerateContent, v1beta).
///
/// Реализует контракт [LiveProvider]:
///  - [connect] открывает realtime-сессию с переданным ключом и отправляет
///    setup-сообщение (модель, режим ответа «только аудио»);
///  - [sendAudio] отправляет фрагмент микрофонного PCM (16 кГц, 16-bit, mono)
///    как realtimeInput-чанк в base64;
///  - [audioStream] отдаёт входящие PCM-байты ответа модели (24 кГц),
///    декодированные из serverContent.modelTurn.inlineData.
///
/// Ключ передаётся параметром [connect] и не сохраняется и не логируется.
class GeminiLiveProvider extends LiveProvider {
  /// Модель Live-режима (native-audio: вход PCM 16 кГц, выход PCM 24 кГц).
  static const String modelId = 'gemini-3.8-live';

  static const String _wsUrl =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.'
      'BidiGenerateContent';

  /// Активное соединение (null, если сессия не открыта).
  WebSocketChannel? _channel;

  /// Подписка на входящие сообщения сервера.
  StreamSubscription<dynamic>? _messageSub;

  /// Broadcast-поток входящего аудио для интерфейса. Экран Live-режима
  /// подписывается на [audioStream] до вызова [connect], поэтому поток
  /// broadcast: подписка не теряется между сессиями и при переподключении.
  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();

  /// Аудио-чанки, пришедшие до завершения setup: сервер принимает
  /// realtimeInput только после setupComplete, поэтому буферизуем.
  final List<Map<String, dynamic>> _pendingAudio = <Map<String, dynamic>>[];

  /// Станет true после ответа setupComplete от сервера.
  bool _setupComplete = false;

  @override
  Stream<List<int>> get audioStream => _audioController.stream;

  @override
  Future<void> connect(String apiKey) async {
    // Повторный connect закрывает предыдущую сессию.
    await disconnect();
    _setupComplete = false;
    _pendingAudio.clear();

    final Uri uri = Uri.parse('$_wsUrl?key=$apiKey');
    final WebSocketChannel channel = WebSocketChannel.connect(uri);

    // Готовность соединения с таймаутом: приложение никогда не зависает.
    try {
      await channel.ready.timeout(const Duration(seconds: 12));
    } catch (e) {
      debugPrint('GeminiLiveProvider: не удалось открыть сессию: $e');
      await _closeChannel(channel);
      if (!_audioController.isClosed) {
        _audioController.addError(
          StateError('Не удалось подключиться к Live-сессии'),
        );
      }
      return;
    }

    _channel = channel;

    _messageSub = channel.stream.listen(
      _onMessage,
      onError: (Object error) {
        debugPrint('GeminiLiveProvider: ошибка соединения: $error');
        if (!_audioController.isClosed) _audioController.addError(error);
      },
      onDone: () {
        debugPrint('GeminiLiveProvider: соединение закрыто');
      },
      cancelOnError: false,
    );

    // Setup: модель и режим ответа «только аудио».
    _sendSafe(<String, dynamic>{
      'setup': <String, dynamic>{
        'model': 'models/$modelId',
        'generationConfig': <String, dynamic>{
          'responseModalities': <String>['AUDIO'],
        },
      },
    });
    debugPrint('GeminiLiveProvider: сессия открыта (модель $modelId)');
  }

  @override
  Future<void> sendAudio(List<int> pcmBytes) async {
    if (pcmBytes.isEmpty) return;
    if (_channel == null) return;
    final String b64 = base64Encode(pcmBytes);
    final Map<String, dynamic> message = <String, dynamic>{
      'realtimeInput': <String, dynamic>{
        'mediaChunks': <Map<String, dynamic>>[
          <String, dynamic>{
            'mimeType': 'audio/pcm;rate=16000',
            'data': b64,
          },
        ],
      },
    };
    if (!_setupComplete) {
      // Буфер ограничен, чтобы не копить чанки при зависшем setup.
      if (_pendingAudio.length < 64) _pendingAudio.add(message);
      return;
    }
    _sendSafe(message);
  }

  @override
  Future<void> disconnect() async {
    final StreamSubscription<dynamic>? sub = _messageSub;
    _messageSub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    final WebSocketChannel? channel = _channel;
    _channel = null;
    if (channel != null) {
      // Вежливое завершение хода перед закрытием соединения.
      _sendOn(channel, <String, dynamic>{
        'clientContent': <String, dynamic>{
          'turns': <dynamic>[],
          'turningComplete': true,
        },
      });
      await _closeChannel(channel);
    }
  }

  /// Разбор входящего сообщения сервера: setupComplete, ошибки и аудио.
  void _onMessage(dynamic raw) {
    final String text = raw is List<int> ? utf8.decode(raw) : raw.toString();
    final dynamic decoded = _tryDecode(text);
    if (decoded is! Map<String, dynamic>) return;

    if (decoded.containsKey('setupComplete')) {
      _setupComplete = true;
      final List<Map<String, dynamic>> pending =
          List<Map<String, dynamic>>.of(_pendingAudio);
      _pendingAudio.clear();
      for (final Map<String, dynamic> m in pending) {
        _sendSafe(m);
      }
      return;
    }

    final dynamic err = decoded['error'];
    if (err is Map<String, dynamic>) {
      final String message =
          (err['message'] ?? 'Ошибка Live-сессии').toString();
      debugPrint('GeminiLiveProvider: сервер вернул ошибку: $message');
      if (!_audioController.isClosed) {
        _audioController.addError(StateError(message));
      }
      return;
    }

    final dynamic server = decoded['serverContent'];
    if (server is! Map<String, dynamic>) return;

    final dynamic turn = server['modelTurn'];
    if (turn is! Map<String, dynamic>) return;
    final dynamic parts = turn['parts'];
    if (parts is! List) return;
    for (final dynamic part in parts) {
      if (part is! Map<String, dynamic>) continue;
      final dynamic inline = part['inlineData'];
      if (inline is! Map<String, dynamic>) continue;
      final dynamic data = inline['data'];
      if (data is String &&
          data.isNotEmpty &&
          !_audioController.isClosed) {
        try {
          final List<int> bytes = base64Decode(data);
          if (bytes.isNotEmpty) _audioController.add(bytes);
        } catch (_) {
          // Некорректный base64 — пропускаем чанк.
        }
      }
    }
  }

  dynamic _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  void _sendSafe(Map<String, dynamic> message) {
    final WebSocketChannel? channel = _channel;
    if (channel == null) return;
    _sendOn(channel, message);
  }

  void _sendOn(WebSocketChannel channel, Map<String, dynamic> message) {
    try {
      channel.sink.add(jsonEncode(message));
    } catch (e) {
      debugPrint('GeminiLiveProvider: ошибка отправки: $e');
    }
  }

  Future<void> _closeChannel(WebSocketChannel channel) async {
    try {
      await channel.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      try {
        await channel.sink.close();
      } catch (_) {}
    }
  }
}
