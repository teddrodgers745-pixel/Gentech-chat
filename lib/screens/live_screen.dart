// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../services/live/gemini_live_provider.dart';
import '../theme.dart';

/// Полноэкранный голосовой Live-режим.
/// Микрофон (record, PCM16 16 кГц, mono) -> [GeminiLiveProvider],
/// входящее аудио модели (PCM16 24 кГц, mono) -> SoLoud-поток (flutter_soloud).
class LiveScreen extends StatefulWidget {
  final String? apiKey;

  const LiveScreen({super.key, this.apiKey});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen>
    with SingleTickerProviderStateMixin {
  static const int _outputSampleRate = 24000;
  static const int _maxBufferBytes = 1024 * 1024 * 4;
  static const Duration _speechQuietGap = Duration(milliseconds: 900);

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;
  late final TextEditingController _keyController;

  final GeminiLiveProvider _provider = GeminiLiveProvider();
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<List<int>>? _audioSub;
  Timer? _speechTimer;

  SoLoud? _soloud;
  AudioSource? _soloudStream;
  SoundHandle? _playHandle;
  bool _soloudReady = false;

  bool _micActive = false;
  bool _muted = false;
  bool _running = false;
  bool _speaking = false;
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
  }

  @override
  void dispose() {
    unawaited(_stopSession());
    _pulseController.dispose();
    _keyController.dispose();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  String _resolveApiKey() =>
      _savedKey.isNotEmpty ? _savedKey : _keyController.text.trim();

  String _formatReason(Object error) {
    final combined = error.toString().toLowerCase();
    if (combined.contains('api_key_invalid') ||
        combined.contains('api key not valid') ||
        combined.contains('invalid api key') ||
        combined.contains('unauthenticated') ||
        combined.contains('permission_denied') ||
        combined.contains('401') ||
        combined.contains('403')) {
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
    final raw = error.toString().trim();
    return raw.isEmpty || raw == 'null'
        ? 'Ошибка соединения с Live API'
        : 'Ошибка: $raw';
  }

  void _reportError(String message, [Object? error]) {
    unawaited(_stopMic());
    if (!mounted) return;
    setState(() {
      _running = false;
      _speaking = false;
      _status = message;
      _errorDetails = error?.toString();
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ---------- микрофон ----------

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
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
      );
      _micActive = true;
      await _micSub?.cancel();
      _micSub = stream.listen(
        _onMicChunk,
        onError: (Object e) {
          debugPrint('LiveScreen: ошибка потока микрофона: $e');
          _micActive = false;
        },
        onDone: () {
          _micActive = false;
        },
      );
      return true;
    } catch (e) {
      _reportError('Ошибка: не удалось запустить микрофон', e);
      return false;
    }
  }

  Future<void> _stopMic() async {
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
    if (chunk.isEmpty || _muted || !_running) return;
    unawaited(_provider.sendAudio(chunk));
  }

  // ---------- воспроизведение (SoLoud) ----------

  Future<void> _initSoLoud() async {
    if (_soloudReady && _soloudStream != null) return;
    try {
      final sol = SoLoud.instance;
      if (!sol.isInitialized) {
        await sol.init();
      }
      final AudioSource stream = sol.setBufferStream(
        maxBufferSizeBytes: _maxBufferBytes,
        bufferingType: BufferingType.released,
        bufferingTimeNeeds: 0.05,
        sampleRate: _outputSampleRate,
        channels: Channels.mono,
        format: BufferType.s16le,
      );
      final SoundHandle handle = sol.play(stream);
      _soloud = sol;
      _soloudStream = stream;
      _playHandle = handle;
      _soloudReady = true;
    } catch (e) {
      debugPrint('LiveScreen: ошибка инициализации SoLoud: $e');
      _soloudReady = false;
      _soloudStream = null;
      _playHandle = null;
    }
  }

  void _feedAudio(List<int> bytes) {
    final sol = _soloud;
    final stream = _soloudStream;
    if (sol == null || stream == null || !_soloudReady || bytes.isEmpty) return;
    try {
      final Uint8List pcm =
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      sol.addAudioDataStream(stream, pcm);

      final SoundHandle? handle = _playHandle;
      if (handle == null || !sol.getIsValidVoiceHandle(handle)) {
        _playHandle = sol.play(stream);
      } else if (sol.getPause(handle)) {
        sol.setPause(handle, false);
      }
    } catch (e) {
      debugPrint('LiveScreen: ошибка добавления аудио в поток: $e');
      return;
    }
    if (!_speaking && mounted) {
      setState(() {
        _speaking = true;
        _status = 'Говорю...';
      });
    }
    _speechTimer?.cancel();
    _speechTimer = Timer(_speechQuietGap, () {
      if (!mounted || !_speaking) return;
      setState(() {
        _speaking = false;
        if (_running && !_muted) _status = 'Слушаю...';
      });
    });
  }

  // ---------- сессия ----------

  Future<void> _startSession() async {
    final key = _resolveApiKey();
    if (key.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Введите API-ключ')),
      );
      return;
    }
    setState(() {
      _running = true;
      _status = 'Подключение...';
      _errorDetails = null;
      _speaking = false;
    });

    try {
      final permission = await Permission.microphone.request();
      if (!mounted) return;
      if (!permission.isGranted) {
        _reportError('Ошибка: Нет доступа к микрофону');
        return;
      }

      await _initSoLoud();
      if (!mounted) return;

      await _audioSub?.cancel();
      _audioSub = _provider.audioStream.listen(
        _feedAudio,
        onError: (Object e) {
          _reportError('Ошибка: поток аудио прерван', e);
        },
        cancelOnError: false,
      );

      await _provider.connect(key);
      if (!mounted) {
        unawaited(_stopSession());
        return;
      }

      if (!await _startMic() || !mounted) {
        unawaited(_stopSession());
        return;
      }

      setState(() => _status = 'Слушаю...');
    } on TimeoutException {
      _reportError('Ошибка: Таймаут подключения к серверу');
    } catch (e) {
      _reportError(_formatReason(e), e);
    }
  }

  Future<void> _stopSession() async {
    _speechTimer?.cancel();
    _speechTimer = null;
    await _stopMic();

    final sub = _audioSub;
    _audioSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}

    try {
      await _provider.disconnect();
    } catch (_) {}

    final sol = _soloud;
    final handle = _playHandle;
    _playHandle = null;
    if (sol != null && handle != null && _soloudReady) {
      try {
        await sol.stop(handle);
      } catch (_) {}
    }
    final stream = _soloudStream;
    _soloudStream = null;
    if (sol != null && stream != null && _soloudReady) {
      try {
        await sol.disposeSource(stream);
      } catch (_) {}
    }
    _soloudReady = false;
    _soloud = null;

    if (mounted && _running) {
      setState(() {
        _running = false;
        _speaking = false;
        _status = 'Готов к запуску';
      });
    }
  }

  Future<void> _endCall() async {
    await _stopSession();
    if (mounted) Navigator.of(context).pop();
  }

  // ---------- интерфейс ----------

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
        final active = _running && !_muted;
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
                        if (_running && !_speaking) {
                          _status =
                              _muted ? 'Микрофон выключен' : 'Слушаю...';
                        }
                      });
                    }
                  : null,
              style: IconButton.styleFrom(
                backgroundColor:
                    _muted ? accent.withValues(alpha: 0.22) : cardBg,
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
