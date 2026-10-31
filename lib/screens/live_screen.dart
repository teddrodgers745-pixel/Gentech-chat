// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../app_state.dart';

/// Экран голосового Live-режима (Gemini Live API по WebSocket).
class LiveScreen extends StatefulWidget {
  final String? apiKey;

  const LiveScreen({super.key, this.apiKey});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen>
    with SingleTickerProviderStateMixin {
  static const String _wsBaseUrl =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent';

  static const String _defaultLiveModel = 'models/gemini-2.0-flash-exp';
  static const String _inputAudioMime = 'audio/pcm;rate=16000';
  static const String _outputAudioMime = 'audio/pcm;rate=24000';
  static const String _fallbackGeminiApiKey = '';

  late final AnimationController _pulseController;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<PlayerState>? _playerSub;

  final List<int> _incomingPcmBuffer = <int>[];
  bool _connected = false;
  bool _speaking = false;
  bool _muted = false;
  bool _closingManually = false;
  String _status = 'Подключение...';
  String? _errorDetails;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);

    _playerSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        if (_speaking) {
          setState(() {
            _speaking = false;
            if (_connected) {
              _status = _muted ? 'Микрофон выключен' : 'Слушаю...';
            }
          });
        }
      }
    });

    _startSession();
  }

  @override
  void dispose() {
    _closingManually = true;
    _stopSession();
    _playerSub?.cancel();
    _pulseController.dispose();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<String> _resolveApiKey() async {
    final direct = widget.apiKey?.trim() ?? '';
    if (direct.isNotEmpty) return direct;

    try {
      final f = File('gemini_api.txt');
      if (await f.exists()) {
        final txt = (await f.readAsString()).trim();
        if (txt.isNotEmpty) return txt;
      }
    } catch (e) {
      debugPrint('Gemini Live: не удалось прочитать gemini_api.txt: $e');
    }

    final cfgKey = effectiveConfig().apiKey.trim();
    if (cfgKey.isNotEmpty) return cfgKey;

    final settingsKey = settings.apiKey.trim();
    if (settingsKey.isNotEmpty) return settingsKey;

    return _fallbackGeminiApiKey;
  }

  String _resolveModel() {
    final raw = effectiveConfig().model.trim();
    if (raw.contains('gemini-2.0-flash-exp') || raw.contains('gemini-3.8-live')) {
      return raw.startsWith('models/') ? raw : 'models/$raw';
    }
    return _defaultLiveModel;
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
        combined.contains('model')) {
      if (combined.contains('not found') ||
          combined.contains('not_found') ||
          combined.contains('404') ||
          combined.contains('unsupported')) {
        return 'Ошибка: Модель не найдена';
      }
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
    if (st != null) {
      debugPrint(st.toString());
    }
    if (!mounted) return;
    setState(() {
      _connected = false;
      _speaking = false;
      _status = message;
      _errorDetails = rawError?.toString();
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _startSession() async {
    _closingManually = false;
    setState(() {
      _status = 'Подключение...';
      _errorDetails = null;
      _connected = false;
      _speaking = false;
    });

    try {
      final perm = await Permission.microphone.request();
      if (!perm.isGranted) {
        _reportError('Ошибка: Нет доступа к микрофону');
        return;
      }

      final key = await _resolveApiKey();
      if (key.isEmpty) {
        _reportError('Ошибка: Неверный ключ (API-ключ не задан в настройках)');
        return;
      }

      final url = '$_wsBaseUrl?key=${Uri.encodeQueryComponent(key)}';
      debugPrint('Gemini Live: подключение к $_wsBaseUrl');

      final ws = await WebSocket.connect(url).timeout(
        const Duration(seconds: 20),
      );
      _ws = ws;

      final modelName = _resolveModel();
      final setupMsg = <String, dynamic>{
        'setup': <String, dynamic>{
          'model': modelName,
          'generationConfig': <String, dynamic>{
            'responseModalities': <String>['AUDIO'],
          },
        },
      };
      debugPrint(
        'Gemini Live: отправка setup ($modelName, input=$_inputAudioMime, output=$_outputAudioMime)',
      );
      ws.add(jsonEncode(setupMsg));

      _wsSub = ws.listen(
        _onWsMessage,
        onError: (Object err, StackTrace st) {
          if (_closingManually) return;
          final msg = _formatReason(err, ws.closeReason, ws.closeCode);
          _reportError(msg, err, st);
        },
        onDone: () {
          if (_closingManually || !mounted) return;
          final code = ws.closeCode;
          final reason = ws.closeReason;
          debugPrint('Gemini Live: WebSocket закрыт (code=$code, reason=$reason)');
          if ((reason != null && reason.trim().isNotEmpty) ||
              (code != null && code != WebSocketStatus.normalClosure)) {
            final msg = _formatReason(
              reason ?? 'Код закрытия $code',
              reason,
              code,
            );
            _reportError(msg, 'code=$code, reason=$reason');
          } else {
            setState(() {
              _connected = false;
              _speaking = false;
              _status = 'Соединение завершено';
            });
          }
        },
        cancelOnError: false,
      );

      await _startMicStream();
      if (!mounted) return;
      setState(() {
        _connected = true;
        _status = 'Слушаю...';
      });
    } on TimeoutException catch (e, st) {
      _reportError('Ошибка: Таймаут подключения к серверу', e, st);
    } catch (e, st) {
      final msg = _formatReason(e);
      _reportError(msg, e, st);
    }
  }

  Future<void> _startMicStream() async {
    await _micSub?.cancel();
    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) return;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _micSub = stream.listen(
      (chunk) {
        final ws = _ws;
        if (_muted || !_connected || chunk.isEmpty || ws == null) return;
        final payload = <String, dynamic>{
          'realtimeInput': <String, dynamic>{
            'mediaChunks': <Map<String, dynamic>>[
              <String, dynamic>{
                'mimeType': _inputAudioMime,
                'data': base64Encode(chunk),
              },
            ],
          },
        };
        try {
          ws.add(jsonEncode(payload));
        } catch (e, st) {
          debugPrint('Gemini Live: ошибка отправки аудио: $e\n$st');
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('Gemini Live: ошибка потока микрофона: $e\n$st');
      },
    );
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

      final errorObj = decoded['error'];
      if (errorObj is Map) {
        final errMsg = errorObj['message']?.toString() ?? errorObj.toString();
        final formatted = _formatReason(errMsg);
        _reportError(formatted, errMsg);
        return;
      }

      final serverContent = decoded['serverContent'];
      if (serverContent is Map) {
        final modelTurn = serverContent['modelTurn'];
        if (modelTurn is Map && modelTurn['parts'] is List) {
          for (final part in (modelTurn['parts'] as List)) {
            if (part is! Map) continue;
            final inlineData = part['inlineData'];
            if (inlineData is Map) {
              final mime = (inlineData['mimeType'] as String?) ?? _outputAudioMime;
              final data = inlineData['data'];
              if (data is String &&
                  data.isNotEmpty &&
                  mime.startsWith('audio/pcm')) {
                _incomingPcmBuffer.addAll(base64Decode(data));
                if (mounted && !_speaking) {
                  setState(() {
                    _speaking = true;
                    _status = 'Говорю...';
                  });
                }
              }
            }
          }
        }
        if (serverContent['turnComplete'] == true &&
            _incomingPcmBuffer.isNotEmpty) {
          final bytes = Uint8List.fromList(_incomingPcmBuffer);
          _incomingPcmBuffer.clear();
          _playPcmBytes(bytes);
        }
      }
    } catch (e, st) {
      debugPrint('Gemini Live: ошибка разбора сообщения: $e\n$st');
    }
  }

  Future<void> _playPcmBytes(Uint8List pcmBytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/live_${DateTime.now().millisecondsSinceEpoch}.wav',
      );
      final wav = _buildWav(pcmBytes, sampleRate: 24000, channels: 1);
      await file.writeAsBytes(wav, flush: true);
      if (!mounted) return;
      setState(() {
        _speaking = true;
        _status = 'Говорю...';
      });
      await _player.setFilePath(file.path);
      await _player.play();
    } catch (e, st) {
      debugPrint('Gemini Live: ошибка воспроизведения PCM: $e\n$st');
      if (!mounted) return;
      setState(() {
        _speaking = false;
        if (_connected) _status = 'Слушаю...';
      });
    }
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
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, dataSize, Endian.little);

    final out = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(pcm);
    return out.toBytes();
  }

  Future<void> _stopSession() async {
    _closingManually = true;
    try {
      await _micSub?.cancel();
      _micSub = null;
      await _recorder.stop();
    } catch (e) {
      debugPrint('Gemini Live: ошибка остановки микрофона: $e');
    }
    try {
      await _wsSub?.cancel();
      _wsSub = null;
      final ws = _ws;
      _ws = null;
      if (ws != null) {
        await ws.close();
      }
    } catch (e) {
      debugPrint('Gemini Live: ошибка закрытия WebSocket: $e');
    }
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('Gemini Live: ошибка остановки плеера: $e');
    }
  }

  Future<void> _endCall() async {
    await _stopSession();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF1B1A19);
    const accent = Color(0xFFD99A6C);
    const text = Color(0xFFF5F0EB);
    const muted = Color(0xFFA8A096);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: text,
        title: const Text('Live-режим'),
      ),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SizedBox(height: 24),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, _) {
                    final t = _pulseController.value;
                    final scale = _connected ? (1.0 + t * 0.22) : 1.0;
                    final circleColor = _speaking
                        ? accent
                        : (_connected
                            ? accent.withValues(alpha: 0.75)
                            : muted.withValues(alpha: 0.35));
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 220,
                          height: 220,
                          child: Center(
                            child: Transform.scale(
                              scale: scale,
                              child: Container(
                                width: 150,
                                height: 150,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: circleColor.withValues(alpha: 0.2),
                                  border: Border.all(
                                    color: circleColor,
                                    width: 3,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: circleColor.withValues(alpha: 0.35),
                                      blurRadius: 32,
                                      spreadRadius: 6,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  _speaking
                                      ? Icons.graphic_eq_rounded
                                      : Icons.mic_rounded,
                                  size: 56,
                                  color: text,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          _status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: text,
                          ),
                        ),
                        if (_errorDetails != null &&
                            _errorDetails!.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            _errorDetails!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 13,
                              color: muted,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 36),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filled(
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
                      backgroundColor: const Color(0xFF2A2826),
                      foregroundColor: text,
                      minimumSize: const Size(60, 60),
                    ),
                    icon: Icon(_muted ? Icons.mic_off_rounded : Icons.mic_rounded),
                  ),
                  const SizedBox(width: 24),
                  IconButton.filled(
                    tooltip: 'Завершить',
                    onPressed: _endCall,
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFFB3261E),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(64, 64),
                    ),
                    icon: const Icon(Icons.call_end_rounded, size: 28),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
