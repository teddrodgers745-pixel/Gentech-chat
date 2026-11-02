// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'live_provider.dart';

/// Live-провайдер голосового режима на собственной реализации WebSocket
/// (BidiGenerateContent, Gemini Live API).
///
/// Протокол:
///  - connect: открываем WebSocket, отправляем setup с responseModalities AUDIO
///    и outputAudioTranscription; ждём setupComplete -> состояние 'listening';
///  - sendAudio: PCM16 16 кГц mono -> base64 -> realtimeInput.mediaChunks;
///    после 1.5 с тишины (RMS ниже порога) отправляем audioStreamEnd;
///  - приём: serverContent.modelTurn.parts[].inlineData.data (PCM16 24 кГц)
///    уходит в [audioStream]; turnComplete -> 'listening'. Микрофон не трогаем.
class GeminiLiveProvider extends LiveProvider {
  static const String _endpoint =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent';

  static const String modelName =
      'models/gemini-2.5-flash-native-audio-preview-12-2025';

  static const Duration _connectTimeout = Duration(seconds: 20);
  static const Duration _silenceForStreamEnd = Duration(milliseconds: 1500);
  static const double _silenceRms = 0.01;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  Completer<void>? _setupCompleter;
  bool _connected = false;
  String _apiKey = '';

  bool _streamEndSent = true;
  DateTime _lastVoiceAt = DateTime.now();

  final StreamController<List<int>> _audioController =
      StreamController<List<int>>.broadcast();

  /// Состояния сессии: 'listening' (готовность / конец хода модели),
  /// 'error' и 'closed' (соединение прервано).
  void Function(String state)? onState;

  /// Последняя ошибка в читаемом виде (без API-ключа).
  String lastError = '';

  @override
  Stream<List<int>> get audioStream => _audioController.stream;

  @override
  Future<void> connect(String apiKey) async {
    await disconnect();
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw StateError('API-ключ не задан');
    }
    _apiKey = key;
    _streamEndSent = true;
    _lastVoiceAt = DateTime.now();
    lastError = '';
    final setup = Completer<void>();
    _setupCompleter = setup;
    try {
      final channel =
          WebSocketChannel.connect(Uri.parse('$_endpoint?key=$key'));
      _channel = channel;
      await channel.ready;
      _wsSub = channel.stream.listen(
        _onMessage,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: false,
      );
      channel.sink.add(jsonEncode(_setupMessage()));
      await setup.future.timeout(_connectTimeout);
      debugPrint('GeminiLiveProvider: сессия открыта');
    } on TimeoutException {
      await disconnect();
      rethrow;
    } catch (e) {
      await disconnect();
      throw StateError(_sanitize(e));
    }
  }

  static Map<String, dynamic> _setupMessage() => <String, dynamic>{
        'setup': <String, dynamic>{
          'model': modelName,
          'generationConfig': <String, dynamic>{
            'responseModalities': <String>['AUDIO'],
          },
          'outputAudioTranscription': const <String, dynamic>{},
        },
      };

  @override
  Future<void> sendAudio(List<int> pcmBytes) async {
    final channel = _channel;
    if (channel == null || !_connected || pcmBytes.isEmpty) return;
    final Uint8List bytes =
        pcmBytes is Uint8List ? pcmBytes : Uint8List.fromList(pcmBytes);
    final now = DateTime.now();
    if (_rms(bytes) >= _silenceRms) {
      _lastVoiceAt = now;
      _streamEndSent = false;
    }
    try {
      channel.sink.add(jsonEncode(<String, dynamic>{
        'realtimeInput': <String, dynamic>{
          'mediaChunks': <Map<String, String>>[
            <String, String>{
              'mimeType': 'audio/pcm;rate=16000',
              'data': base64Encode(bytes),
            },
          ],
        },
      }));
    } catch (e) {
      debugPrint('GeminiLiveProvider: ошибка отправки аудио: $e');
      return;
    }
    if (!_streamEndSent &&
        now.difference(_lastVoiceAt) >= _silenceForStreamEnd) {
      await sendAudioStreamEnd();
    }
  }

  /// Сообщает модели, что пользователь закончил говорить (audioStreamEnd).
  /// Повторная отправка до следующего громкого фрагмента не выполняется.
  Future<void> sendAudioStreamEnd() async {
    final channel = _channel;
    if (channel == null || !_connected || _streamEndSent) return;
    _streamEndSent = true;
    try {
      channel.sink.add(jsonEncode(<String, dynamic>{
        'realtimeInput': <String, dynamic>{'audioStreamEnd': true},
      }));
    } catch (e) {
      debugPrint('GeminiLiveProvider: ошибка audioStreamEnd: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    final sub = _wsSub;
    _wsSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    final setup = _setupCompleter;
    _setupCompleter = null;
    if (setup != null && !setup.isCompleted) {
      setup.completeError(StateError('Сессия закрыта'));
    }
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {}
    }
  }

  // ---------- приём ----------

  void _onMessage(dynamic raw) {
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      text = utf8.decode(raw, allowMalformed: true);
    } else {
      return;
    }
    if (text.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final msg = Map<String, dynamic>.from(decoded);

    if (msg.containsKey('setupComplete')) {
      _connected = true;
      final c = _setupCompleter;
      _setupCompleter = null;
      if (c != null && !c.isCompleted) c.complete();
      onState?.call('listening');
      return;
    }

    if (msg['error'] != null) {
      lastError = _sanitize(msg['error']);
      final c = _setupCompleter;
      _setupCompleter = null;
      if (c != null && !c.isCompleted) {
        c.completeError(StateError(lastError));
        return;
      }
      onState?.call('error');
      return;
    }

    final sc = msg['serverContent'];
    if (sc is! Map) return;
    final turn = sc['modelTurn'];
    if (turn is Map && turn['parts'] is List) {
      for (final part in (turn['parts'] as List)) {
        if (part is! Map) continue;
        final inline = part['inlineData'];
        if (inline is! Map) continue;
        final data = inline['data'];
        if (data is! String || data.isEmpty) continue;
        try {
          final pcm = base64Decode(data);
          if (pcm.isNotEmpty && !_audioController.isClosed) {
            _audioController.add(pcm);
          }
        } catch (e) {
          debugPrint('GeminiLiveProvider: битый аудиофрагмент: $e');
        }
      }
    }
    if (sc['turnComplete'] == true) {
      onState?.call('listening');
    }
  }

  void _onSocketError(Object error) {
    lastError = _sanitize(error);
    _failOrState('error');
  }

  void _onSocketDone() {
    final code = _channel?.closeCode;
    lastError =
        'Сервер закрыл соединение${code == null ? '' : ' (код $code)'}';
    _failOrState('closed');
  }

  void _failOrState(String state) {
    final c = _setupCompleter;
    _setupCompleter = null;
    if (c != null && !c.isCompleted) {
      c.completeError(StateError(lastError));
      return;
    }
    if (_connected) {
      _connected = false;
      onState?.call(state);
    }
  }

  // ---------- утилиты ----------

  /// Убирает API-ключ из текстов ошибок, чтобы он не попадал в интерфейс.
  String _sanitize(Object error) {
    final text = error.toString();
    if (_apiKey.isEmpty) return text;
    return text.replaceAll(_apiKey, '***');
  }

  /// RMS-уровень PCM16 little-endian, нормирован к диапазону 0..1.
  static double _rms(Uint8List bytes) {
    final n = bytes.lengthInBytes ~/ 2;
    if (n == 0) return 0;
    final view = ByteData.sublistView(bytes);
    double sum = 0;
    for (int i = 0; i < n; i++) {
      final s = view.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return math.sqrt(sum / n);
  }
}
