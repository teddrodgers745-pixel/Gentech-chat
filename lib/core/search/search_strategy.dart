// Copyright (c) 2026 Minkail. All rights reserved.

/// Режим поиска, выбираемый в настройках.
///
///  - [off] — поиск выключен, поле настроек скрыто;
///  - [native] — встроенный (нативный) поиск самой модели;
///  - [provider] — серверный поиск, предоставляемый провайдером
///    (для Polza — серверный инструмент polza:web_search);
///  - [modelAsTool] — поиск выполняет отдельная модель-инструмент;
///  - [customApi] — пользовательский поисковый API со своим ключом.
enum SearchMode { off, native, provider, modelAsTool, customApi }

/// Подписи и идентификаторы режима для интерфейса и хранилища.
extension SearchModeX on SearchMode {
  /// Стабильный строковый идентификатор (совпадает с именем enum).
  String get id => name;

  /// Короткая подпись для чипа выбора режима.
  String get label => switch (this) {
        SearchMode.off => 'Выключен',
        SearchMode.native => 'Нативный',
        SearchMode.provider => 'Провайдер',
        SearchMode.modelAsTool => 'Модель-инструмент',
        SearchMode.customApi => 'Свой API',
      };
}

/// Разбор и валидация строкового идентификатора режима поиска
/// (SharedPreferences хранит режим строкой, как и другие настройки).
abstract final class SearchModes {
  /// Режим по строковому идентификатору; неизвестное значение — off.
  static SearchMode fromId(String id) {
    final s = id.trim().toLowerCase();
    for (final m in SearchMode.values) {
      if (m.name.toLowerCase() == s) return m;
    }
    return SearchMode.off;
  }

  /// Известен ли идентификатор режима (валидация сохранённых настроек).
  static bool isKnownId(String id) {
    final s = id.trim().toLowerCase();
    for (final m in SearchMode.values) {
      if (m.name.toLowerCase() == s) return true;
    }
    return false;
  }
}

/// Один результат поиска: заголовок, ссылка и краткий фрагмент текста.
class SearchHit {
  final String title;
  final String url;
  final String snippet;

  const SearchHit({
    this.title = '',
    this.url = '',
    this.snippet = '',
  });

  bool get isEmpty => title.trim().isEmpty && url.trim().isEmpty;
}

/// Итог поиска по одному запросу: список находок либо текст ошибки.
/// [error] непустой — поиск не удался, интерфейс показывает сообщение.
class SearchResult {
  /// Исходный запрос.
  final String query;

  /// Найденные результаты (пустой список, если ничего не найдено).
  final List<SearchHit> hits;

  /// Текст ошибки для пользователя; null/пустая строка — ошибки нет.
  final String? error;

  const SearchResult({
    required this.query,
    this.hits = const <SearchHit>[],
    this.error,
  });

  /// Поиск завершился без ошибок.
  bool get ok => (error ?? '').trim().isEmpty;

  @override
  String toString() =>
      'SearchResult(query: $query, hits: ${hits.length}, error: $error)';
}

/// Интерфейс стратегии поиска: реализуется конкретными источниками
/// (нативный поиск модели, провайдерский поиск, модель-инструмент,
/// пользовательский API). Стратегия получает готовый запрос и возвращает
/// результат; ключи и адреса берёт из настроек пользователя сама.
abstract class SearchStrategy {
  const SearchStrategy();

  /// Выполняет поиск по [query]. Никогда не бросает исключений наружу:
  /// любая ошибка возвращается внутри [SearchResult.error].
  Future<SearchResult> search(String query);
}

/// Разбор источников (citations/annotations) из ответа провайдера.
///
/// Поддерживаются как плоские записи ({'url': ...}), так и вложенные
/// url_citation в стиле OpenAI/Perplexity:
/// [{'type': 'url_citation', 'url_citation': {'url': '...'}}].
/// Используется и для серверных инструментов Polza (polza:web_search /
/// polza:web_fetch), и для поиска моделью-инструментом.
abstract final class SearchSourceParser {
  /// Достаёт список URL из произвольного списка записей.
  /// Возвращает только http/https-ссылки, без дублей.
  static List<String> extractFromMap(Object? raw) {
    final out = <String>[];
    if (raw is! List) return out;
    for (final e in raw) {
      final url = _extractUrl(e);
      if (url == null) continue;
      final t = url.trim();
      if (t.isEmpty) continue;
      if (!t.startsWith('http://') && !t.startsWith('https://')) continue;
      if (!out.contains(t)) out.add(t);
    }
    return out;
  }

  /// Достаёт URL из одной записи-citation. Ладит и со строками,
  /// и с плоскими объектами, и с вложенными `url_citation`.
  static String? _extractUrl(Object? e) {
    if (e is String) return e;
    if (e is! Map) return null;
    final direct = e['url'] ?? e['uri'] ?? e['link'] ?? e['source'];
    if (direct is String && direct.isNotEmpty) return direct;
    final nested = e['url_citation'];
    if (nested is Map) {
      final u = nested['url'] ?? nested['uri'] ?? nested['link'];
      if (u is String && u.isNotEmpty) return u;
    }
    return null;
  }
}
