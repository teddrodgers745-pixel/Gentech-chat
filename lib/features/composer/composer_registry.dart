// Copyright (c) 2026 Minkail. All rights reserved.

import 'composer_mode.dart';
import 'modes/live_mode.dart';
import 'modes/text_mode.dart';

/// Реестр режимов композера: список доступных режимов, режим по
/// умолчанию и поиск по стабильному идентификатору. Новые режимы
/// добавляются списком в конструктор; остальной код работает только
/// через контракт [ComposerMode] и не знает о конкретных реализациях.
class ComposerModeRegistry {
  final List<ComposerMode> _modes;

  /// По умолчанию зарегистрированы текстовый и голосовой режимы;
  /// будущие режимы (изображения, поиск и т.п.) добавляются сюда.
  /// Первый режим в списке считается режимом по умолчанию.
  ComposerModeRegistry({List<ComposerMode>? modes})
      : _modes = modes ?? const <ComposerMode>[TextMode(), LiveMode()];

  /// Все зарегистрированные режимы (только для чтения).
  List<ComposerMode> get modes => List.unmodifiable(_modes);

  /// Режим по умолчанию (первый в списке).
  ComposerMode get defaultMode => _modes.first;

  /// Режим по идентификатору; null — режим не зарегистрирован.
  ComposerMode? byId(String id) {
    for (final m in _modes) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Зарегистрирован ли режим с таким идентификатором.
  bool contains(String id) => byId(id) != null;
}
