// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/widgets.dart';

import 'composer_mode.dart';
import 'modes/text_mode.dart';

/// Состояние панели ввода: текст поля, активный режим и флаг генерации.
/// ChangeNotifier: интерфейс подписывается и перерисовывается.
class ComposerController extends ChangeNotifier {
  ComposerController({ComposerMode? mode})
      : _mode = mode ?? const TextMode() {
    text.addListener(_onTextChanged);
  }

  /// Текст поля ввода. Контроллером владеет [ComposerController]
  /// и освобождает его в dispose.
  final TextEditingController text = TextEditingController();

  ComposerMode _mode;
  bool _streaming = false;
  bool _hasText = false;

  /// Активный режим композера.
  ComposerMode get mode => _mode;

  /// Идёт ли генерация ответа (кнопка отправки превращается в «стоп»).
  bool get streaming => _streaming;

  /// Есть ли непустой текст: кнопка отправки активна только с текстом.
  bool get hasText => _hasText;

  /// Смена режима. Повторная установка того же режима игнорируется.
  void setMode(ComposerMode newMode) {
    if (identical(newMode, _mode) || newMode.id == _mode.id) return;
    _mode = newMode;
    notifyListeners();
  }

  void setStreaming(bool value) {
    if (value == _streaming) return;
    _streaming = value;
    notifyListeners();
  }

  /// Очищает поле ввода.
  void clear() {
    if (text.text.isEmpty) return;
    text.clear();
  }

  /// Уведомляем слушателей только при реальном изменении «есть текст»,
  /// чтобы не перерисовывать панель на каждую букву.
  void _onTextChanged() {
    final now = text.text.trim().isNotEmpty;
    if (now == _hasText) return;
    _hasText = now;
    notifyListeners();
  }

  @override
  void dispose() {
    text.removeListener(_onTextChanged);
    text.dispose();
    super.dispose();
  }
}
