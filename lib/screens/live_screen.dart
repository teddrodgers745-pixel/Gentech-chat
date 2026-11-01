// Copyright (c) 2026 Minkail. All rights reserved.

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

class LiveScreen extends StatefulWidget {
  final String? apiKey;

  const LiveScreen({super.key, this.apiKey});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _PcmWavSource extends StreamAudioSource {
  final Uint8List wavBytes;

  _PcmWavSource(this.wavBytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = (start ?? 0).clamp(0, wavBytes.length);
    final to = (end ?? wavBytes.length).clamp(from, wavBytes.length);
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
  static const int _micChunkBytes = 960;
  static const double _silenceRmsThreshold = 350;
  static const Duration _silenceDuration = Duration(milliseconds: 1500);
  static const int _minPlaybackBytes = 4800;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;
  late final TextEditingController _keyController;
  late final Future<void> _playerReady;

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final List<int> _micBuffer = <int>[];
  final List<int> _incomingPcmBuffer = <int>[];
  final ConcatenatingAudioSource _audioQueue =
      ConcatenatingAudioSource(children: <AudioSource>[]);

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<PlayerState>? _playerSub;
  Timer? _audioDebugTimer;
  List<String> _debugLogs = [];
  bool _audioSentInInterval = false;

  DateTime _lastVoiceTime = DateTime.now();
  String? _sessionHandle;
  bool _streamEndSent = false;
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

  String get _savedKey {
    final passed = widget.apiKey?.trim() ?? '';
    return passed.isNotEmpty ? passed : effectiveConfig().apiKey.trim();
  }

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
    _playerReady = _initializePlayer();
    _playerSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed && _speaking) {
        setState(() {
          _speaking = false;
          if (_connected) _status = 'Слушаю...';
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

  Future<void> _initializePlayer() async {
    try {
      await _player.setAudioSource(_audioQueue);
    } catch (e) {
      debugPrint('Gemini Live: не удалось инициализировать плеер: $e');
    }
  }

  @override
  void dispose() {
    _closingManually = true;
    unawaited(_stopSession());
    _playerSub?.cancel();
    _pulseController.dispose();
    _keyController.dispose();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  String _resolveApiKey() =>
      _savedKey.isNotEmpty ? _savedKey : _keyController.text.trim();

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
    return raw.isEmpty || raw == 'null'
        ? 'Ошибка соединения с Live API'
        : 'Ошибка: $raw';
  }

  void _reportError(String message, [Object? error, StackTrace? stack]) {
    debugPrint('Gemini Live error: $message | raw: $error');
    if (stack != null) debugPrint(stack.toString());
    unawaited(_stopMic());
    if (!mounted) return;
    setState(() {
      _connected = false;
      _speaking = false;
      _status = message;
      _running = false;
      _errorDetails = error?.toString();
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

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
          _stopAudioDebugTimer();
        },
      );
      debugPrint('Gemini Live: микрофон запущен');
      return true;
    } catch (e, st) {
      _reportError('Ошибка: не удалось запустить микрофон', e, st);
      return false;
    }
  }

  Future<void> _stopMic() async {
    _micBuffer.clear();
    _stopAudioDebugTimer();
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
    if (chunk.isEmpty) return;
    if (_muted) {
      _micBuffer.clear();
      return;
    }
    if (!_connected) return;

    _analyzeMicLevel(chunk);
    _micBuffer.addAll(chunk);
    while (_micBuffer.length >= _micChunkBytes) {
      final piece = Uint8List.fromList(_micBuffer.sublist(0, _micChunkBytes));
      _micBuffer.removeRange(0, _micChunkBytes);
      final sent = _sendJson(<String, dynamic>{
        'realtimeInput': <String, dynamic>{
          'mediaChunks': <Map<String, dynamic>>[
            <String, dynamic>{
              'mimeType': _inputAudioMime,
              'data': base64Encode(piece),
            },
          ],
        },
      });
      if (sent) {
        _audioSentInInterval = true;
        _audioDebugTimer ??= Timer.periodic(
          const Duration(seconds: 2),
          (_) {
            if (!_micActive || !_connected || _muted) {
              _audioSentInInterval = false;
              return;
            }
            if (!_audioSentInInterval) return;
            _audioSentInInterval = false;
            _addDebugLog('Sending audio...');
          },
        );
      }
    }
  }

  void _analyzeMicLevel(Uint8List chunk) {
    var sumSquares = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < chunk.length; i += 2) {
      final sample = (chunk[i] | (chunk[i + 1] << 8)).toSigned(16);
      sumSquares += sample * sample;
      count++;
    }
    if (count == 0) return;

    final now = DateTime.now();
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
      debugPrint('Gemini Live => audioStreamEnd (тишина более 1,5 с)');
    }
  }

  bool _sendJson(Map<String, dynamic> payload) {
    final ws = _ws;
    if (ws == null) return false;
    try {
      ws.add(jsonEncode(payload));
      return true;
    } catch (e, st) {
      debugPrint('Gemini Live: ошибка отправки: $e\n$st');
      return false;
    }
  }

  void _stopAudioDebugTimer() {
    _audioDebugTimer?.cancel();
    _audioDebugTimer = null;
    _audioSentInInterval = false;
  }

  void _addDebugLog(String message) {
    if (!mounted) return;
    final clipped =
        message.length > 400 ? message.substring(0, 400) : message;
    setState(() => _debugLogs.add(clipped));
  }

  Future<void> _startSession() async {
    final key = _resolveApiKey();
    if (key.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Введите API-ключ')),
      );
      return;
    }
    if (mounted) {
      setState(() {
        _running = true;
        _status = 'Подключение...';
        _errorDetails = null;
        _connected = false;
        _speaking = false;
      });
    }

    try {
      final permission = await Permission.microphone.request();
      if (!mounted) return;
      if (!permission.isGranted) {
        _reportError('Ошибка: Нет доступа к микрофону');
        return;
      }

      // Поток записи остаётся запущенным на протяжении всей сессии.
      if (!await _startMic() || !mounted) return;
      final ws = await WebSocket.connect(
        '$_wsBaseUrl?key=${Uri.encodeQueryComponent(key)}',
      ).timeout(const Duration(seconds: 20));
      if (!mounted || _closingManually) {
        await ws.close();
        return;
      }
      _ws = ws;
      ws.pingInterval = const Duration(seconds: 15);

      // Сначала подписываемся, чтобы не пропустить быстрый setupComplete.
      _wsSub = ws.listen(
        _onWsMessage,
        onError: (Object error, StackTrace stack) {
          if (!_closingManually) {
            _reportError(
              _formatReason(error, ws.closeReason, ws.closeCode),
              error,
              stack,
            );
          }
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
      if (mounted) setState(() => _status = 'Настройка сессии...');
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
      _status = 'Слушаю...';
    });
    debugPrint('Gemini Live: setupComplete — микрофон продолжает работу');
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
    if (mounted && !_closingManually) await _startSession();
  }

  /// Приводит входящий кадр WebSocket к строке. Бинарные кадры (байты)
  /// декодируются через utf8; при неизвестном типе возвращает null.
  String? _frameToText(dynamic raw) {
    try {
      if (raw is String) return raw;
      if (raw is List<int>) return utf8.decode(raw, allowMalformed: true);
    } catch (e) {
      debugPrint('Gemini Live: не удалось декодировать кадр: $e');
    }
    debugPrint('Gemini Live: неизвестный тип кадра ${raw.runtimeType}');
    return null;
  }

  void _onWsMessage(dynamic raw) {
    final text = _frameToText(raw);
    if (text == null) return;
    // Логируем уже декодированный текст, а не байты-числа.
    debugPrint('Gemini Live <= $text');
    _addDebugLog('<= ${text.length > 300 ? text.substring(0, 300) : text}');
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      _addDebugLog('Keys: ${decoded.keys.toList()}');

      final error = decoded['error'];
      if (error != null) {
        final full = error.toString();
        debugPrint('Gemini Live: ошибка сервера полностью: $full');
        _addDebugLog('Server error: $full');
        final message = error is Map
            ? (error['message']?.toString() ?? full)
            : full;
        _reportError(_formatReason(message), full);
        return;
      }
      if (decoded.containsKey('setupComplete')) {
        _onSetupComplete();
        return;
      }

      final resumption = decoded['sessionResumptionUpdate'];
      if (resumption is Map) {
        final handle = resumption['newHandle'];
        if (resumption['resumable'] == true &&
            handle is String &&
            handle.isNotEmpty) {
          _sessionHandle = handle;
        }
      }
      if (decoded.containsKey('goAway')) {
        debugPrint('Gemini Live: goAway — переподключение');
        unawaited(_reconnect());
        return;
      }

      final content = decoded['serverContent'];
      if (content is! Map) return;

      if (content['interrupted'] == true) {
        debugPrint('Gemini Live: interrupted — очищаю очередь плеера');
        unawaited(_clearPlayback());
      }

      final turn = content['modelTurn'];
      final parts = turn is Map ? turn['parts'] : null;
      if (parts is List) {
        for (final part in parts) {
          if (part is! Map) continue;
          final inlineData = part['inlineData'];
          if (inlineData is! Map) continue;
          final mime = inlineData['mimeType'] as String? ?? _outputAudioMime;
          final data = inlineData['data'];
          if (data is! String || data.isEmpty || !mime.startsWith('audio/pcm')) {
            continue;
          }
          final bytes = base64Decode(data);
          _addDebugLog('Audio chunk received: ${bytes.length} bytes');
          _incomingPcmBuffer.addAll(bytes);
          if (mounted) {
            setState(() {
              _speaking = true;
              _status = 'Говорю...';
            });
          }
        }
        unawaited(_flushPcmToPlayer());
      }

      if (content['turnComplete'] == true) {
        unawaited(_flushPcmToPlayer(force: true));
        _lastVoiceTime = DateTime.now();
        _streamEndSent = false;
        _addDebugLog('TurnComplete received');
        debugPrint('Gemini Live: turnComplete — продолжаю слушать');
        if (mounted) {
          setState(() {
            _speaking = false;
            _status = 'Слушаю...';
          });
        }
      }
    } catch (e, st) {
      debugPrint('Gemini Live: ошибка разбора сообщения: $e\n$st');
    }
  }

  Future<void> _flushPcmToPlayer({bool force = false}) async {
    if (_incomingPcmBuffer.isEmpty ||
        (!force && _incomingPcmBuffer.length < _minPlaybackBytes)) {
      return;
    }
    final pcm = Uint8List.fromList(_incomingPcmBuffer);
    _incomingPcmBuffer.clear();
    try {
      await _playerReady;
      if (_player.processingState == ProcessingState.completed) {
        await _audioQueue.clear();
        await _player.stop();
      }
      await _audioQueue.add(_PcmWavSource(_buildWav(pcm)));
      if (!_player.playing) unawaited(_player.play());
      if (mounted) {
        setState(() {
          _speaking = true;
          _status = 'Говорю...';
        });
      }
    } catch (e, st) {
      debugPrint('Gemini Live: ошибка воспроизведения PCM: $e\n$st');
    }
  }

  Future<void> _clearPlayback() async {
    _incomingPcmBuffer.clear();
    try {
      await _audioQueue.clear();
      await _player.stop();
    } catch (e) {
      debugPrint('Gemini Live: ошибка очистки плеера: $e');
    }
    if (mounted) {
      setState(() {
        _speaking = false;
        if (_connected) _status = 'Слушаю...';
      });
    }
  }

  Uint8List _buildWav(Uint8List pcm) {
    const sampleRate = 24000;
    const channels = 1;
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
    header.setUint32(28, sampleRate * channels * 2, Endian.little);
    header.setUint16(32, channels * 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint32(40, dataSize, Endian.little);
    return (BytesBuilder(copy: false)
          ..add(header.buffer.asUint8List())
          ..add(pcm))
        .toBytes();
  }

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
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const bgTop = Color(0xFF26221F);
    const bgMid = Color(0xFF1B1A19);
    const bgBottom = Color(0xFF141312);
    const cardBg = Color(0xFF242321);
    const border = Color(0xFF3A3733);
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
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(height: 12),
                    _pulseSection(accent, text, muted, cardBg, border),
                    if (!_running) _startArea(cardBg, border, accent, muted),
                    _debugPanel(cardBg, border, text, muted),
                    _bottomControls(cardBg, border, accent, text),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pulseSection(
    Color accent,
    Color text,
    Color muted,
    Color cardBg,
    Color border,
  ) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, _) {
        final t = _pulseAnim.value;
        final active = _connected && !_muted;
        final color = _speaking ? accent : accent.withValues(alpha: 0.65);
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
                    scale: 1 + t * (active ? 0.28 : 0.06),
                    child: Container(
                      width: 176,
                      height: 176,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color.withValues(alpha: active ? 0.09 : 0.04),
                        border: Border.all(
                          color: color.withValues(alpha: active ? 0.25 : 0.12),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: 1 + t * (active ? 0.14 : 0.03),
                    child: Container(
                      width: 146,
                      height: 146,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            color.withValues(alpha: 0.34),
                            color.withValues(alpha: 0.12),
                          ],
                        ),
                        border: Border.all(color: color, width: 2.5),
                        boxShadow: [
                          BoxShadow(
                            color: color.withValues(alpha: active ? 0.42 : 0.2),
                            blurRadius: active ? 36 : 20,
                            spreadRadius: active ? 6 : 2,
                          ),
                        ],
                      ),
                      child: Icon(
                        _speaking
                            ? Icons.graphic_eq_rounded
                            : (_muted
                                ? Icons.mic_off_rounded
                                : Icons.mic_rounded),
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
                color: cardBg.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: border),
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
                style: TextStyle(fontSize: 13, color: muted),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _startArea(
    Color cardBg,
    Color border,
    Color accent,
    Color muted,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_savedKey.isEmpty) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cardBg.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: border),
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
                  hintText: 'Введите ключ',
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
                    onPressed: () =>
                        setState(() => _obscureKey = !_obscureKey),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1B1A19),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(color: border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(color: border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(color: accent, width: 1.8),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],
          DecoratedBox(
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
          ),
        ],
      ),
    );
  }

  Widget _debugPanel(
    Color cardBg,
    Color border,
    Color text,
    Color muted,
  ) {
    return Container(
      width: double.infinity,
      height: 130,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cardBg.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: _debugLogs.isEmpty ? 1 : _debugLogs.length,
        itemBuilder: (context, index) {
          if (_debugLogs.isEmpty) {
            return Text(
              'Журнал соединения',
              style: TextStyle(fontSize: 11, color: muted),
            );
          }
          final log = _debugLogs[_debugLogs.length - 1 - index];
          return Text(
            log,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: text,
              fontFamily: 'JetBrains Mono',
              fontFamilyFallback: const ['monospace'],
            ),
          );
        },
      ),
    );
  }

  Widget _bottomControls(
    Color cardBg,
    Color border,
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
              onPressed: _running
                  ? () {
                      setState(() {
                        _muted = !_muted;
                        if (_connected && !_speaking) {
                          _status = _muted ? 'Микрофон выключен' : 'Слушаю...';
                        }
                      });
                    }
                  : null,
              style: IconButton.styleFrom(
                backgroundColor: _muted ? accent.withValues(alpha: 0.22) : cardBg,
                foregroundColor: _muted ? accent : text,
                side: BorderSide(color: _muted ? accent : border, width: 1.5),
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
              onPressed: _running ? _endCall : null,
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
