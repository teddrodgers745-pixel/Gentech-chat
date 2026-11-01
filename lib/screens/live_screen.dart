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
import '../theme.dart';

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

  static const String _liveModelId =
      'gemini-2.5-flash-native-audio-preview-12-2025';
  static const String _inputAudioMime = 'audio/pcm;rate=16000';
  static const String _outputAudioMime = 'audio/pcm;rate=24000';

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;
  late final TextEditingController _keyController;
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
  bool _running = false;
  bool _obscureKey = true;
  String _status = 'Готов к запуску';
  String? _errorDetails;

  @override
  void initState() {
    super.initState();
    final initialKey = (widget.apiKey != null && widget.apiKey!.trim().isNotEmpty)
        ? widget.apiKey!.trim()
        : effectiveConfig().apiKey.trim();
    _keyController = TextEditingController(text: initialKey);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnim = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOutSine,
    );

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

  Future<String> _resolveApiKey() async {
    final typed = _keyController.text.trim();
    if (typed.isNotEmpty) return typed;
    final passed = widget.apiKey?.trim() ?? '';
    if (passed.isNotEmpty) return passed;
    return effectiveConfig().apiKey.trim();
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

  Future<void> _startSession() async {
    final key = await _resolveApiKey();
    if (!mounted) return;
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

      final url = '$_wsBaseUrl?key=${Uri.encodeQueryComponent(key)}';
      final ws = await WebSocket.connect(url).timeout(
        const Duration(seconds: 20),
      );
      if (!mounted) {
        await ws.close();
        return;
      }
      _ws = ws;

      ws.add(jsonEncode(<String, dynamic>{
        'setup': <String, dynamic>{
          'model': 'models/$_liveModelId',
          'generationConfig': <String, dynamic>{
            'responseModalities': <String>['AUDIO'],
          },
        },
      }));
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

  Future<void> _onSetupComplete() async {
    if (_connected || !mounted) return;
    setState(() {
      _connected = true;
      _status = _muted ? 'Микрофон выключен' : 'Слушаю...';
    });
    try {
      await _startMicStream();
    } catch (e, st) {
      _reportError('Ошибка: не удалось запустить микрофон', e, st);
    }
  }

  Future<void> _startMicStream() async {
    await _micSub?.cancel();
    _micSub = null;
    final hasPerm = await _recorder.hasPermission();
    if (!mounted) return;
    if (!hasPerm) {
      _reportError('Ошибка: Нет доступа к микрофону');
      return;
    }

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
        try {
          ws.add(jsonEncode(<String, dynamic>{
            'realtimeInput': <String, dynamic>{
              'mediaChunks': <Map<String, dynamic>>[
                <String, dynamic>{
                  'mimeType': _inputAudioMime,
                  'data': base64Encode(chunk),
                },
              ],
            },
          }));
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
        _reportError(_formatReason(errMsg), errMsg);
        return;
      }

      if (decoded.containsKey('setupComplete')) {
        _onSetupComplete();
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
              final mime =
                  (inlineData['mimeType'] as String?) ?? _outputAudioMime;
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
    _running = false;
    _closingManually = true;
    try {
      await _micSub?.cancel();
      _micSub = null;
      await _recorder.stop();
    } catch (_) {}
    try {
      await _wsSub?.cancel();
      _wsSub = null;
      final ws = _ws;
      _ws = null;
      if (ws != null) await ws.close();
    } catch (_) {}
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> _endCall() async {
    await _stopSession();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

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
                      _buildKeyCard(cardBg, borderCol, accent, text, muted),
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

  Widget _buildKeyCard(
    Color cardBg,
    Color borderCol,
    Color accent,
    Color text,
    Color muted,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _keyController,
            obscureText: _obscureKey,
            autocorrect: false,
            enableSuggestions: false,
            cursorColor: accent,
            style: const TextStyle(color: Color(0xFFF5F0EB), fontSize: 15),
            decoration: InputDecoration(
              labelText: 'API-ключ',
              hintText: 'Введите или проверьте ключ Gemini',
              labelStyle: TextStyle(color: muted),
              hintStyle: TextStyle(color: muted.withValues(alpha: 0.6)),
              prefixIcon: Icon(Icons.key_rounded, color: accent, size: 20),
              suffixIcon: IconButton(
                tooltip: _obscureKey ? 'Показать ключ' : 'Скрыть ключ',
                icon: Icon(
                  _obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined,
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
          if (!_running) ...[
            const SizedBox(height: 14),
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
        ],
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
