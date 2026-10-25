// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Сервис озвучки ответов модели (TTS) поверх flutter_tts.
/// Озвучка идёт асинхронно и не блокирует интерфейс;
/// фактическое состояние отслеживается через [activeId].
class TtsService {
  FlutterTts? _tts;
  bool _configured = false;

  /// id сообщения, которое сейчас озвучивается (null — тишина).
  final ValueNotifier<String?> activeId = ValueNotifier<String?>(null);

  /// Ленивая инициализация движка: создаётся при первом нажатии,
  /// ошибки конфигурации не роняют приложение.
  Future<FlutterTts?> _ensure() async {
    if (_configured) return _tts;
    _configured = true;
    try {
      final t = FlutterTts();
      await t.setLanguage('ru-RU');
      await t.setSpeechRate(0.5);
      await t.setVolume(1.0);
      await t.setPitch(1.0);
      await t.awaitSpeakCompletion(false);
      t.setCompletionHandler(() => activeId.value = null);
      t.setCancelHandler(() => activeId.value = null);
      _tts = t;
    } catch (_) {
      _tts = null;
    }
    return _tts;
  }

  /// Кнопка динамика: если это сообщение уже звучит — стоп, иначе озвучка.
  Future<void> toggleSpeak(String id, String raw) async {
    if (activeId.value == id) {
      await stop();
      return;
    }
    await _start(id, raw);
  }

  /// Автоозвучка нового ответа: прерывает текущую озвучку, если была.
  Future<void> speakAuto(String id, String raw) async {
    if (activeId.value != null) await stop();
    await _start(id, raw);
  }

  Future<void> _start(String id, String raw) async {
    final text = plainForSpeech(raw);
    if (text.isEmpty) return;
    final engine = await _ensure();
    if (engine == null) return;
    try {
      if (activeId.value != null) await engine.stop();
      activeId.value = id;
      await engine.speak(text);
    } catch (_) {
      activeId.value = null;
    }
  }

  /// Остановить озвучку (при переходе на другой экран и т.п.).
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {
      // Движок недоступен — состояние всё равно сбрасываем.
    }
    activeId.value = null;
  }
}

/// Превращает markdown-ответ модели в текст, пригодный для чтения вслух:
/// блоки кода удаляются целиком, инлайн-код и ссылки остаются текстом,
/// служебные символы разметки убираются.
String plainForSpeech(String raw) {
  var s = raw;
  s = s.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  s = s.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1)!);
  s = s.replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!);
  s = s.replaceAll(RegExp(r'(^|\n)\s*#{1,6}\s*'), '\n');
  s = s.replaceAll(RegExp(r'^\s*[-+*]\s+', multiLine: true), '\n');
  s = s.replaceAll(RegExp(r'[*_~>|]'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  return s.trim();
}

/// Глобальный экземпляр TTS-сервиса.
final TtsService ttsService = TtsService();
