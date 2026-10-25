// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Ошибка голосового ввода с готовым понятным сообщением для пользователя.
class SpeechServiceException implements Exception {
  final String message;
  SpeechServiceException(this.message);

  @override
  String toString() => message;
}

/// Сервис распознавания речи (Speech-to-Text) поверх speech_to_text.
/// Разрешение на микрофон запрашивается через permission_handler;
/// любые ошибки возвращаются текстом — приложение не падает.
/// Итог распознавания копится по предложениям и отдаётся через onText,
/// включая промежуточные (partial) результаты.
class SpeechService {
  SpeechToText? _stt;
  bool _initTried = false;
  bool _listening = false;

  String _finalText = '';
  String _partial = '';
  void Function(String text)? _onText;
  void Function(String message)? _onError;

  /// Идёт ли запись прямо сейчас (для пульсирующей иконки микрофона).
  final ValueNotifier<bool> listening = ValueNotifier<bool>(false);

  void _finish() {
    _listening = false;
    listening.value = false;
  }

  /// Ленивая инициализация распознавателя: выполняется один раз,
  /// ошибки конфигурации не роняют приложение.
  Future<bool> _ensureInit() async {
    if (_initTried) return _stt != null;
    _initTried = true;
    try {
      final stt = SpeechToText();
      final ok = await stt.initialize(
        onError: (e) {
          _finish();
          final network = e.errorMsg.toLowerCase().contains('network');
          _onError?.call(
            network
                ? 'Ошибка распознавания: проверьте интернет-соединение.'
                : 'Ошибка распознавания речи.',
          );
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') _finish();
        },
      );
      if (ok) _stt = stt;
    } catch (_) {
      _stt = null;
    }
    return _stt != null;
  }

  /// Запускает распознавание. Бросает [SpeechServiceException]
  /// с готовым сообщением, если нет разрешения или распознавание
  /// недоступно (в том числе без интернета для системного сервиса).
  Future<void> start({
    required String localeId,
    required void Function(String text) onText,
    void Function(String message)? onError,
  }) async {
    if (_listening) return;
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (status.isPermanentlyDenied || status.isRestricted) {
        throw SpeechServiceException(
          'Доступ к микрофону запрещён. Разрешите его в настройках приложения.',
        );
      }
      throw SpeechServiceException('Доступ к микрофону не получен.');
    }
    if (!await _ensureInit()) {
      throw SpeechServiceException(
        'Распознавание речи недоступно на этом устройстве.',
      );
    }
    _onText = onText;
    _onError = onError;
    _finalText = '';
    _partial = '';
    final stt = _stt!;
    try {
      _listening = true;
      listening.value = true;
      await stt.listen(
        onResult: _handleResult,
        localeId: localeId,
        listenOptions: const SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (_) {
      _finish();
      throw SpeechServiceException(
        'Не удалось запустить распознавание речи. '
        'Проверьте интернет-соединение.',
      );
    }
  }

  void _handleResult(SpeechRecognitionResult r) {
    if (!_listening) return;
    final w = r.recognizedWords.trim();
    if (r.finalResult) {
      // Финальный результат дублирует последний partial — не добавляем дважды.
      if (w.isNotEmpty && !_finalText.endsWith(w)) {
        _finalText = _finalText.isEmpty ? w : '$_finalText $w';
      }
      _partial = '';
    } else {
      _partial = w;
    }
    final full = _partial.isEmpty
        ? _finalText
        : (_finalText.isEmpty ? _partial : '$_finalText $_partial');
    final t = full.trim();
    if (t.isNotEmpty) _onText?.call(t);
  }

  /// Останавливает запись.
  Future<void> stop() async {
    try {
      await _stt?.stop();
    } catch (_) {
      // Движок недоступен — состояние всё равно сбрасываем.
    }
    _finish();
  }
}

/// Глобальный экземпляр сервиса голосового ввода.
final SpeechService speechService = SpeechService();
