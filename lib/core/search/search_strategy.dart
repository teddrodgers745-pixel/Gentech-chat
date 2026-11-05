// Copyright (c) 2026 Minkail. All rights reserved.

/// Режим поиска, выбираемый в настройках.
///
///  - [off] — поиск выключен, поле настроек скрыто;
///  - [native] — встроенный (нативный) поиск самой модели;
///  - [provider] — серверный поиск, предоставляемый провайдером;
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
      if (m.name == s) return m;
    }
    return SearchMode.off;
  }

  /// Известен ли идентификатор режима (валидация сохранённых настроек).
  static bool isKnownId(String id) {
    final s = id.trim().toLowerCase();
    for (final m in SearchMode.values) {
      if (m.name == s) return true;
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
      'SearchResult(query: $query, hits: ${hits.length}, ok: $ok)';
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
