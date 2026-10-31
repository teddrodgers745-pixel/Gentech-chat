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
import 'package:web_socket_channel/web_socket_channel.dart';

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
  static const String _wsEndpoint =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent';

  /// Константа ключа по умолчанию (если не передан через настройки).
  static const String _fallbackGeminiApiKey = '';

  late final AnimationController _pulseController;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<PlayerState>? _playerSub;

  final List<int> _incomingPcmBuffer = <int>[];
  bool _connected = false;
  bool _speaking = false;
  bool _muted = false;
  String _status = 'Подключение...';

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
            if (_connected) _status = 'Слушаю...';
          });
        }
      }
    });

    _startSession();
  }

  @override
  void dispose() {
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
    } catch (_) {}
    final cfgKey = effectiveConfig().apiKey.trim();
    if (cfgKey.isNotEmpty) return cfgKey;
    return _fallbackGeminiApiKey;
  }

  Future<void> _startSession() async {
    setState(() {
      _status = 'Подключение...';
      _connected = false;
      _speaking = false;
    });

    final perm = await Permission.microphone.request();
    if (!perm.isGranted) {
      if (!mounted) return;
      setState(() => _status = 'Нет доступа к микрофону');
      return;
    }

    final key = await _resolveApiKey();
    final uri = Uri.parse(
      key.isEmpty ? _wsEndpoint : '$_wsEndpoint?key=${Uri.encodeQueryComponent(key)}',
    );

    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _wsSub = channel.stream.listen(
        _onWsMessage,
        onError: (_) {
          if (!mounted) return;
          setState(() {
            _connected = false;
            _speaking = false;
            _status = 'Ошибка соединения';
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            _connected = false;
            _speaking = false;
            _status = 'Соединение закрыто';
          });
        },
      );

      final setupMsg = <String, dynamic>{
        'setup': <String, dynamic>{
          'model': 'models/gemini-2.0-flash-exp',
          'generationConfig': <String, dynamic>{
            'responseModalities': <String>['AUDIO'],
          },
        },
      };
      channel.sink.add(jsonEncode(setupMsg));

      await _startMicStream();
      if (!mounted) return;
      setState(() {
        _connected = true;
        _status = 'Слушаю...';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _status = 'Не удалось подключиться';
      });
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
    _micSub = stream.listen((chunk) {
      if (_muted || !_connected || chunk.isEmpty) return;
      final payload = <String, dynamic>{
        'realtimeInput': <String, dynamic>{
          'mediaChunks': <Map<String, dynamic>>[
            <String, dynamic>{
              'mimeType': 'audio/pcm;rate=16000',
              'data': base64Encode(chunk),
            },
          ],
        },
      };
      try {
        _channel?.sink.add(jsonEncode(payload));
      } catch (_) {}
    });
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
      final serverContent = decoded['serverContent'];
      if (serverContent is Map) {
        final modelTurn = serverContent['modelTurn'];
        if (modelTurn is Map && modelTurn['parts'] is List) {
          for (final part in (modelTurn['parts'] as List)) {
            if (part is! Map) continue;
            final inlineData = part['inlineData'];
            if (inlineData is Map) {
              final data = inlineData['data'];
              if (data is String && data.isNotEmpty) {
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
    } catch (_) {}
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
    } catch (_) {
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
    // "RIFF"
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataSize, Endian.little);
    // "WAVE"
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    // "fmt "
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little); // 16-bit
    // "data"
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
    try {
      await _micSub?.cancel();
      _micSub = null;
      await _recorder.stop();
    } catch (_) {}
    try {
      await _wsSub?.cancel();
      _wsSub = null;
      await _channel?.sink.close();
      _channel = null;
    } catch (_) {}
    try {
      await _player.stop();
    } catch (_) {}
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
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: text,
                        ),
                      ),
                    ],
                  );
                },
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
                    onPressed: () => Navigator.of(context).pop(),
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
