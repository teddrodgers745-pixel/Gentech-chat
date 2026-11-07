// Copyright (c) 2026 Minkail. All rights reserved.

// Импорты сохранены намеренно (жёсткое правило проекта: не удалять импорты);
// они понадобятся при реализации modelAsTool через Function Calling.
// ignore: unused_import
import 'dart:convert';
// ignore: unused_import
import 'package:http/http.dart' as http;
// ignore: unused_import
import '../app_state.dart';

/// Обогащение тела запроса /chat/completions поиском.
///
/// Режимы ([searchMode]):
///  - 'provider' — серверный поиск провайдера: в тело добавляется
///    поле web_search = true;
///  - 'modelAsTool' — пре-запрос к поисковой модели ПЕРЕД каждым
///    сообщением пользователя УДАЛЁН: он сжигал токены и тормозил
///    даже на «Привет». Функционал будет реализован позже отдельной
///    задачей через Function Calling; сейчас режим просто не меняет
///    тело запроса;
///  - остальные режимы — тело не меняется.
///
/// Любая ошибка поиска не роняет основной запрос: возвращается
/// исходное тело без изменений.
Future<Map<String, dynamic>> enhanceRequestWithSearch(
  Map<String, dynamic> requestBody,
  String query,
  String searchMode,
  String? searchModelId,
) async {
  if (searchMode == 'provider') {
    requestBody['web_search'] = true;
    return requestBody;
  }
  // 'off', 'native', 'modelAsTool', 'customApi': тело не меняется.
  return requestBody;
}

/// Текст ответа /chat/completions: content первого выбора; '' — не найден.
/// Сохранён для будущей реализации modelAsTool (Function Calling).
// ignore: unused_element
String _answerText(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) return '';
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return '';
    }
    final msg = (choices.first as Map)['message'];
    if (msg is Map) {
      final c = msg['content'];
      if (c is String) return c.trim();
    }
  } catch (_) {}
  return '';
}
