// Copyright (c) 2026 Minkail. All rights reserved.

// just_audio помечает StreamAudioSource как экспериментальный; предупреждение
// подавляем осознанно: PCM воспроизводится из памяти без записи на диск.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../theme.dart';

/// Экран голосового Live-режима (Gemini Live API по WebSocket).
/// Микрофон пишется непрерывно от «Запустить» до «Завершить».
/// Ответы модели проигрываются по мере прихода; turnComplete возвращает
/// статус к «Слушаю...», но микрофон не останавливается.
class LiveScreen extends StatefulWidget {
  final String? apiKey;

  const LiveScreen({super.key, this.apiKey});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

/// Источник WAV из памяти: PCM ответа модели отдаётся плееру без записи на диск.
class _PcmWavSource extends StreamAudioSource {
  final Uint8List wavBytes;
  _PcmWavSource(this.wavBytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = (start ?? 0).clamp(0, wavBytes.length);
    var to = end ?? wavBytes.length;
    if (to < from) to = from;
    if (to > wavBytes.length) to = wavBytes.length;
    return StreamAudioResponse(
      sourceLength: wavBytes.length,
      contentLength: to - from,
      offset: from,
      contentType: 'audio/wav',
      stream: Stream<List<int>>.value(wavBytes.sublist(from, to)),
    );
  }
}

class _LiveScreenState extends State<LiveScreen>
    with SingleTickerProviderStateMixin {
  static const String _wsBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent';

  static const String _liveModelId =
      'gemini-2.5-flash-native-audio-preview-12-2025';
  static const String _inputAudioMime = 'audio/pcm;rate=16000';
  static const String _outputAudioMime = 'audio/pcm;rate=24000';

  /// 30 мс PCM 16-bit mono 16 кГц = 16000 * 2 * 0.03 = 960 байт.
  static const int _micChunkBytes = 960;

  /// Порог тишины (RMS по шкале 16-bit) и пауза, после которой уходит audioStreamEnd.
  static const double _silenceRmsThreshold = 350;
  static const Duration _silenceDuration = Duration(milliseconds: 1500);

  /// Минимальный объём PCM перед добавлением в плеер (24 кГц * 2 байта * 0.1 с).
  static const int _minPlaybackBytes = 4800;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;
  late final TextEditingController _keyController;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<PlayerState>? _playerSub;

  /// Входящий PCM ответа модели (накапливается между base64-частями).
  final List<int> _incomingPcmBuffer = <int>[];

  /// Очередь воспроизведения: чанки ответа добавляются непрерывно,
  /// очищается только при 'interrupted' или завершении.
  final ConcatenatingAudioSource _audioQueue = ConcatenatingAudioSource(
    children: <AudioSource>[],
  );

  /// Буфер микрофона: чанки record режем на порции по [_micChunkBytes].
  final List<int> _micBuffer = <int>[];

  DateTime _lastVoiceTime = DateTime.now();
  bool _streamEndSent = false;
  String? _sessionHandle;
  bool _reconnecting = false;
  bool _connected = false;
  bool _speaking = false;
  bool _muted = false;
  bool _closingManually = false;
  bool _running = false;
  bool _micActive = false;
  bool _obscureKey = true;
  String _status = 'Готов к запуску';
  String? _errorDetails;

  /// Ключ из настроек (или переданный извне). Если он есть, поле ввода скрыто.
  String get _savedKey {
    final passed = widget.apiKey?.trim() ?? '';
    return passed.isNotEmpty ? passed : effectiveConfig().apiKey.trim();
  }

  bool get _hasSavedKey => _savedKey.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnim = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOutSine,
    );

    () async {
      try {
        await _player.setAudioSource(_audioQueue);
      } catch (e) {
        debugPrint('Gemini Live: не удалось инициализировать плеер: $e');
      }
    }();

    // Конец очереди: возвращаем статус к слушанию, микрофон не трогаем.
    _playerSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed && _speaking) {
        setState(() {
          _speaking = false;
          if (_connected) {
            _status = _muted ? 'Микрофон выключен' : 'Слушаю...';
          }
        });
      }
    });

    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        debugPrint('Gemini Live: ошибка плеера: $e\n$st');
      },
    );
  }

  @override
  void dispose() {
    _closingManually = true;
    _stopSession();
    _playerSub?.cancel();
    _pulseController.dispose();
    _keyController.dispose();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  String _resolveApiKey() {
    if (_hasSavedKey) return _savedKey;
    return _keyController.text.trim();
  }

  String _formatReason(Object error, [String? closeReason, int? closeCode]) {
    final combined = '${error.toString()} ${closeReason ?? ''}'.toLowerCase();
    if (combined.contains('api_key_invalid') ||
        combined.contains('api key not valid') ||
        combined.contains('invalid api key') ||
        combined.contains('unauthenticated') ||
        combined.contains('permission_denied') ||
        combined.contains('401') ||
        combined.contains('403') ||
        closeCode == 1008) {
      return 'Ошибка: Неверный ключ';
    }
    if (combined.contains('not found') ||
        combined.contains('not_found') ||
        combined.contains('404') ||
        combined.contains('unsupported')) {
      return 'Ошибка: Модель не найдена';
    }
    if (combined.contains('quota') ||
        combined.contains('resource_exhausted') ||
        combined.contains('429')) {
      return 'Ошибка: Превышен лимит запросов (429)';
    }
    if (closeReason != null && closeReason.trim().isNotEmpty) {
      return 'Ошибка: ${closeReason.trim()}';
    }
    final raw = error.toString().trim();
    if (raw.isNotEmpty && raw != 'null') {
      return 'Ошибка: $raw';
    }
    return 'Ошибка соединения с Gemini Live API';
  }

  void _reportError(String message, [Object? rawError, StackTrace? st]) {
    debugPrint('Gemini Live error: $message | raw: $rawError');
    if (st != null) debugPrint(st.toString());
    unawaited(_stopMic());
    if (!mounted) return;
    setState(() {
      _connected = false;
      _speaking = false;
      _status = message;
      _running = false;
      _errorDetails = rawError?.toString();
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ---------- микрофон (непрерывный поток) ----------

  /// Запускает поток записи PCM 16 кГц. Работает до [_stopMic].
  /// Возвращает false, если запись невозможна (ошибка уже показана).
  Future<bool> _startMic() async {
    if (_micActive) return true;
    try {
      if (!await _recorder.hasPermission()) {
        _reportError('Ошибка: Нет доступа к микрофону');
        return false;
      }
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _micActive = true;
      _micBuffer.clear();
      _lastVoiceTime = DateTime.now();
      _streamEndSent = false;
      await _micSub?.cancel();
      _micSub = stream.listen(
        _onMicChunk,
        onError: (Object e, StackTrace st) {
          debugPrint('Gemini Live: ошибка потока микрофона: $e\n$st');
        },
        onDone: () {
          debugPrint('Gemini Live: поток микрофона завершён');
          _micActive = false;
        },
      );
      debugPrint('Gemini Live: микрофон запущен (PCM 16-bit, 16 кГц, mono)');
      return true;
    } catch (e, st) {
      _reportError('Ошибка: не удалось запустить микрофон', e, st);
      return false;
    }
  }

  Future<void> _stopMic() async {
    _micBuffer.clear();
    final sub = _micSub;
    _micSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    if (_micActive) {
      _micActive = false;
      try {
        await _recorder.stop();
      } catch (_) {}
    }
  }

  void _onMicChunk(Uint8List chunk) {
    if (_muted) {
      _micBuffer.clear();
      return;
    }
    if (!_connected || chunk.isEmpty) return;
    _analyzeMicLevel(chunk);
    _micBuffer.addAll(chunk);
    while (_micBuffer.length >= _micChunkBytes) {
      final piece = Uint8List.fromList(_micBuffer.sublist(0, _micChunkBytes));
      _micBuffer.removeRange(0, _micChunkBytes);
      _sendJson(<String, dynamic>{
        'realtimeInput': <String, dynamic>{
          'mediaChunks': <Map<String, dynamic>>[
            <String, dynamic>{
              'mimeType': _inputAudioMime,
              'data': base64Encode(piece),
            },
          ],
        },
      });
    }
  }

  /// RMS-анализ: при тишине дольше [_silenceDuration] отправляем audioStreamEnd.
  void _analyzeMicLevel(Uint8List chunk) {
    final now = DateTime.now();
    var sumSquares = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      final sample = (chunk[i] | (chunk[i + 1] << 8)).toSigned(16);
      sumSquares += sample * sample;
      count++;
    }
    if (count == 0) return;
    final rms = math.sqrt(sumSquares / count);
    if (rms > _silenceRmsThreshold) {
      _lastVoiceTime = now;
      _streamEndSent = false;
    } else if (!_streamEndSent &&
        now.difference(_lastVoiceTime) >= _silenceDuration) {
      _streamEndSent = true;
      _sendJson(<String, dynamic>{
        'realtimeInput': <String, dynamic>{'audioStreamEnd': true},
      });
      debugPrint('Gemini Live => audioStreamEnd (пауза 1.5 с)');
    }
  }

  // ---------- WebSocket ----------

  void _sendJson(Map<String, dynamic> payload) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(jsonEncode(payload));
    } catch (e, st) {
      debugPrint('Gemini Live: ошибка отправки: $e\n$st');
    }
  }

  Future<void> _startSession() async {
    final key = _resolveApiKey();
    if (key.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Введите API-ключ')),
      );
      return;
    }
    _closingManually = false;
    setState(() {
      _running = true;
      _status = 'Подключение...';
      _errorDetails = null;
      _connected = false;
      _speaking = false;
    });

    try {
      final perm = await Permission.microphone.request();
      if (!mounted) return;
      if (!perm.isGranted) {
        _reportError('Ошибка: Нет доступа к микрофону');
        return;
      }
      // Запись стартует сразу по «Запустить»; чанки уходят после setupComplete.
      final micOk = await _startMic();
      if (!mounted || !micOk) return;

      final url = '$_wsBaseUrl?key=${Uri.encodeQueryComponent(key)}';
      final ws = await WebSocket.connect(url).timeout(
        const Duration(seconds: 20),
      );
      if (!mounted || _closingManually) {
        await ws.close();
        return;
      }
      _ws = ws;
      // Пинг каждые 15 секунд, чтобы соединение не рвалось по простою.
      ws.pingInterval = const Duration(seconds: 15);

      final handle = _sessionHandle;
      _sendJson(<String, dynamic>{
        'setup': <String, dynamic>{
          'model': 'models/$_liveModelId',
          'generationConfig': <String, dynamic>{
            'responseModalities': <String>['AUDIO'],
          },
          'sessionResumption': <String, dynamic>{
            if (handle != null && handle.isNotEmpty) 'handle': handle,
          },
        },
      });
      debugPrint('Gemini Live => setup отправлен');
      setState(() => _status = 'Настройка сессии...');

      _wsSub = ws.listen(
        _onWsMessage,
        onError: (Object err, StackTrace st) {
          if (_closingManually) return;
          _reportError(_formatReason(err, ws.closeReason, ws.closeCode), err, st);
        },
        onDone: () {
          if (_closingManually || !mounted) return;
          final code = ws.closeCode;
          final reason = ws.closeReason;
          debugPrint('Gemini Live: соединение закрыто (code=$code)');
          if ((reason != null && reason.trim().isNotEmpty) ||
              (code != null && code != WebSocketStatus.normalClosure)) {
            _reportError(
              _formatReason(reason ?? 'Код закрытия $code', reason, code),
              'code=$code, reason=$reason',
            );
          } else {
            setState(() {
              _connected = false;
              _speaking = false;
              _status = 'Соединение завершено';
              _running = false;
            });
            unawaited(_stopMic());
          }
        },
        cancelOnError: false,
      );
    } on TimeoutException catch (e, st) {
      _reportError('Ошибка: Таймаут подключения к серверу', e, st);
    } catch (e, st) {
      _reportError(_formatReason(e), e, st);
    }
  }

  void _onSetupComplete() {
    if (_connected || !mounted) return;
    _lastVoiceTime = DateTime.now();
    _streamEndSent = false;
    setState(() {
      _connected = true;
      _status = _muted ? 'Микрофон выключен' : 'Слушаю...';
    });
    debugPrint('Gemini Live: setupComplete — отправляю микрофон');
  }

  Future<void> _closeSocket() async {
    try {
      await _wsSub?.cancel();
    } catch (_) {}
    _wsSub = null;
    final old = _ws;
    _ws = null;
    if (old != null) {
      try {
        await old.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  Future<void> _reconnect() async {
    if (_reconnecting || _closingManually || !mounted) return;
    _reconnecting = true;
    setState(() {
      _connected = false;
      _speaking = false;
      _status = 'Переподключение...';
    });
    await _closeSocket();
    _reconnecting = false;
    if (!mounted || _closingManually) return;
    await _startSession();
  }

  void _onWsMessage(dynamic raw) {
    try {
      final String text;
      if (raw is String) {
        text = raw;
      } else if (raw is List<int>) {
        text = utf8.decode(raw, allowMalformed: true);
      } else {
        return;
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      debugPrint('Gemini Live <= ${decoded.keys.join(', ')}');

      final errorObj = decoded['error'];
      if (errorObj is Map) {
        final errMsg = errorObj['message']?.toString() ?? errorObj.toString();
        _reportError(_formatReason(errMsg), errMsg);
        return;
      }

      if (decoded.containsKey('setupComplete')) {
        _onSetupComplete();
        return;
      }

      final resumption = decoded['sessionResumptionUpdate'];
      if (resumption is Map) {
        final newHandle = resumption['newHandle'];
        if (resumption['resumable'] == true &&
            newHandle is String &&
            newHandle.isNotEmpty) {
          _sessionHandle = newHandle;
        }
      }

      if (decoded.containsKey('goAway')) {
        debugPrint('Gemini Live: goAway — переподключаюсь');
        _reconnect();
        return;
      }

      final serverContent = decoded['serverContent'];
      if (serverContent is Map) {
        if (serverContent['interrupted'] != null) {
          debugPrint('Gemini Live <= interrupted: очищаю плеер');
          _clearPlayback();
        }
        final modelTurn = serverContent['modelTurn'];
        if (modelTurn is Map && modelTurn['parts'] is List) {
          for (final part in (modelTurn['parts'] as List)) {
            if (part is! Map) continue;
            final inlineData = part['inlineData'];
            if (inlineData is! Map) continue;
            final mime = (inlineData['mimeType'] as String?) ?? _outputAudioMime;
            final data = inlineData['data'];
            if (data is String && data.isNotEmpty && mime.startsWith('audio/pcm')) {
              _incomingPcmBuffer.addAll(base64Decode(data));
              if (mounted && !_speaking) {
                setState(() {
                  _speaking = true;
                  _status = 'Говорю...';
                });
              }
            }
          }
          _flushPcmToPlayer();
        }
        if (serverContent['turnComplete'] == true) {
          // Конец реплики: дожимаем буфер, статус «Слушаю...»,
          // микрофон продолжает писать.
          _flushPcmToPlayer(force: true);
          _lastVoiceTime = DateTime.now();
          _streamEndSent = false;
          debugPrint('Gemini Live <= turnComplete: жду следующую фразу');
          if (mounted) {
            setState(() {
              _speaking = false;
              _status = _muted ? 'Микрофон выключен' : 'Слушаю...';
            });
          }
        }
      }
    } catch (e, st) {
      debugPrint('Gemini Live: ошибка разбора сообщения: $e\n$st');
    }
  }

  // ---------- воспроизведение ----------

  /// Передаёт накопленный PCM в очередь плеера (WAV из памяти).
  Future<void> _flushPcmToPlayer({bool force = false}) async {
    if (_incomingPcmBuffer.isEmpty) return;
    if (!force && _incomingPcmBuffer.length < _minPlaybackBytes) return;
    final pcm = Uint8List.fromList(_incomingPcmBuffer);
    _incomingPcmBuffer.clear();
    try {
      if (_player.processingState == ProcessingState.completed) {
        await _audioQueue.clear();
        await _player.stop();
      }
      final wav = _buildWav(pcm, sampleRate: 24000, channels: 1);
      await _audioQueue.add(_PcmWavSource(wav));
      if (!_player.playing) {
        unawaited(_player.play());
      }
      if (!mounted) return;
      setState(() {
        _speaking = true;
        _status = 'Говорю...';
      });
    } catch (e, st) {
      debugPrint('Gemini Live: ошибка воспроизведения PCM: $e\n$st');
    }
  }

  /// Полная очистка воспроизведения — при 'interrupted'.
  Future<void> _clearPlayback() async {
    _incomingPcmBuffer.clear();
    try {
      await _audioQueue.clear();
      await _player.stop();
    } catch (e) {
      debugPrint('Gemini Live: ошибка очистки плеера: $e');
    }
    if (!mounted) return;
    setState(() {
      _speaking = false;
      if (_connected) {
        _status = _muted ? 'Микрофон выключен' : 'Слушаю...';
      }
    });
  }

  Uint8List _buildWav(
    Uint8List pcm, {
    required int sampleRate,
    required int channels,
  }) {
    final byteRate = sampleRate * channels * 2;
    final blockAlign = channels * 2;
    final dataSize = pcm.length;
    final header = ByteData(44);
    const riff = [0x52, 0x49, 0x46, 0x46];
    const wave = [0x57, 0x41, 0x56, 0x45];
    const fmt = [0x66, 0x6D, 0x74, 0x20];
    const data = [0x64, 0x61, 0x74, 0x61];
    for (var i = 0; i < 4; i++) {
      header.setUint8(i, riff[i]);
      header.setUint8(8 + i, wave[i]);
      header.setUint8(12 + i, fmt[i]);
      header.setUint8(36 + i, data[i]);
    }
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint32(40, dataSize, Endian.little);

    final out = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(pcm);
    return out.toBytes();
  }

  // ---------- завершение ----------

  Future<void> _stopSession() async {
    _running = false;
    _connected = false;
    _closingManually = true;
    await _stopMic();
    await _closeSocket();
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> _endCall() async {
    await _stopSession();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ---------- интерфейс ----------

  @override
  Widget build(BuildContext context) {
    const bgTop = Color(0xFF26221F);
    const bgMid = Color(0xFF1B1A19);
    const bgBottom = Color(0xFF141312);
    const cardBg = Color(0xFF242321);
    const borderCol = Color(0xFF3A3733);
    const accent = Color(0xFFD99A6C);
    const text = Color(0xFFF5F0EB);
    const muted = Color(0xFFA8A096);

    return Scaffold(
      backgroundColor: bgMid,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome, size: 18, color: accent),
            const SizedBox(width: 8),
            Text(
              'Live-режим',
              style: fontStyle(
                settings.bodyFont,
                size: 19,
                weight: FontWeight.w600,
                color: text,
              ),
            ),
          ],
        ),
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgTop, bgMid, bgBottom],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox(height: 12),
                      _buildPulseSection(accent, text, muted),
                      _buildStartArea(cardBg, borderCol, accent, muted),
                      _buildBottomControls(cardBg, borderCol, accent, text),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPulseSection(Color accent, Color text, Color muted) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, _) {
        final t = _pulseAnim.value;
        final active = _connected && !_muted;
        final outerScale = active ? (1.0 + t * 0.28) : (1.0 + t * 0.06);
        final innerScale = active ? (1.0 + t * 0.14) : (1.0 + t * 0.03);
        final coreColor = _speaking
            ? accent
            : (_connected
                ? (_muted ? muted.withValues(alpha: 0.45) : accent)
                : accent.withValues(alpha: 0.65));

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 230,
              height: 230,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: outerScale,
                    child: Container(
                      width: 176,
                      height: 176,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: coreColor.withValues(alpha: active ? 0.09 : 0.04),
                        border: Border.all(
                          color: coreColor.withValues(alpha: active ? 0.25 : 0.12),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: innerScale,
                    child: Container(
                      width: 146,
                      height: 146,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            coreColor.withValues(alpha: 0.34),
                            coreColor.withValues(alpha: 0.12),
                          ],
                        ),
                        border: Border.all(color: coreColor, width: 2.5),
                        boxShadow: [
                          BoxShadow(
                            color: coreColor.withValues(alpha: active ? 0.42 : 0.2),
                            blurRadius: active ? 36 : 20,
                            spreadRadius: active ? 6 : 2,
                          ),
                        ],
                      ),
                      child: Icon(
                        _speaking
                            ? Icons.graphic_eq_rounded
                            : (_muted ? Icons.mic_off_rounded : Icons.mic_rounded),
                        size: 54,
                        color: text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF242321).withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF3A3733)),
              ),
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: fontStyle(
                  settings.bodyFont,
                  size: 18,
                  weight: FontWeight.w600,
                  color: text,
                ),
              ),
            ),
            if (_errorDetails != null && _errorDetails!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _errorDetails!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFFA8A096)),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Зона запуска: если ключ сохранён — только кнопка «Запустить».
  /// Если ключа нет — поле ввода и кнопка.
  Widget _buildStartArea(Color cardBg, Color borderCol, Color accent, Color muted) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_hasSavedKey) ...[
            _buildKeyField(cardBg, borderCol, accent, muted),
            if (!_running) const SizedBox(height: 14),
          ],
          if (!_running) _buildStartButton(accent),
        ],
      ),
    );
  }

  Widget _buildKeyField(Color cardBg, Color borderCol, Color accent, Color muted) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderCol),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: TextField(
        controller: _keyController,
        obscureText: _obscureKey,
        autocorrect: false,
        enableSuggestions: false,
        cursorColor: accent,
        style: const TextStyle(color: Color(0xFFF5F0EB), fontSize: 15),
        decoration: InputDecoration(
          labelText: 'API-ключ',
          hintText: 'Введите ключ Gemini',
          labelStyle: TextStyle(color: muted),
          hintStyle: TextStyle(color: muted.withValues(alpha: 0.6)),
          prefixIcon: Icon(Icons.key_rounded, color: accent, size: 20),
          suffixIcon: IconButton(
            tooltip: _obscureKey ? 'Показать ключ' : 'Скрыть ключ',
            icon: Icon(
              _obscureKey
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              color: muted,
              size: 20,
            ),
            onPressed: () => setState(() => _obscureKey = !_obscureKey),
          ),
          filled: true,
          fillColor: const Color(0xFF1B1A19),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: borderCol),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: borderCol),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: accent, width: 1.8),
          ),
        ),
      ),
    );
  }

  Widget _buildStartButton(Color accent) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.32),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: _startSession,
        icon: const Icon(Icons.play_arrow_rounded, size: 22),
        label: Text(
          'Запустить',
          style: fontStyle(
            settings.bodyFont,
            size: 16,
            weight: FontWeight.w600,
            color: const Color(0xFF1B1A19),
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF1B1A19),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls(
    Color cardBg,
    Color borderCol,
    Color accent,
    Color text,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24, top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: IconButton.filled(
              tooltip: _muted ? 'Включить микрофон' : 'Выключить микрофон',
              onPressed: () {
                setState(() {
                  _muted = !_muted;
                  if (_connected && !_speaking) {
                    _status = _muted ? 'Микрофон выключен' : 'Слушаю...';
                  }
                });
              },
              style: IconButton.styleFrom(
                backgroundColor: _muted ? accent.withValues(alpha: 0.22) : cardBg,
                foregroundColor: _muted ? accent : text,
                side: BorderSide(color: _muted ? accent : borderCol, width: 1.5),
                minimumSize: const Size(62, 62),
              ),
              icon: Icon(
                _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                size: 26,
              ),
            ),
          ),
          const SizedBox(width: 28),
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFB3261E).withValues(alpha: 0.45),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: IconButton.filled(
              tooltip: 'Завершить',
              onPressed: _endCall,
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFB3261E),
                foregroundColor: Colors.white,
                minimumSize: const Size(66, 66),
              ),
              icon: const Icon(Icons.call_end_rounded, size: 28),
            ),
          ),
        ],
      ),
    );
  }
}
