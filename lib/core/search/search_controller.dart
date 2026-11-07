// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/foundation.dart';

/// Контроллер поиска текущего чата: включён ли поиск капсулой «Поиск».
///
/// Глобальный экземпляр [chatSearch] переключается из TextChatInput
/// (капсула поиска) и читается ChatService при сборке тела запроса:
/// когда поиск включён и модель поддерживает нативный веб-поиск,
/// в /chat/completions добавляется tools: [{'type': 'web_search'}].
class SearchController extends ChangeNotifier {
  bool _enabled = true;

  /// Включён ли поиск в текущем чате (по умолчанию — включён).
  bool get enabled => _enabled;

  void setEnabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    notifyListeners();
  }
}

/// Глобальный экземпляр контроллера поиска чата.
final SearchController chatSearch = SearchController();
