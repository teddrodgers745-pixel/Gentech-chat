```dart
// Copyright (c) 2026 Minkail. All rights reserved.

import 'gen_error.dart';

/// Часть составного сообщения: то, из чего состоит пользовательский запрос
/// или ответ модели. Базовый sealed-тип гарантирует, что switch по частям
/// будет исчерпывающим без default — новые типы добавляются явно.
sealed class MessagePart {
  const MessagePart();

  /// Краткая человекочитаемая подпись части (для отладки и будущих UI).
  String get label;
}

/// Стоимость ответа модели: сумма, валюта и счётчики токенов.
/// Данные приходят из статистики использования (usage) провайдера,
/// которую ChatService отдаёт в [StreamChunk.usage] при стриминге
/// (stream_options.include_usage) и в непотоковом ответе.
class MessageCost {
  /// Стоимость ответа в валюте [currency]; null — провайдер не сообщил
  /// сумму (известны только счётчики токенов). Неизвестная сумма НЕ
  /// заменяется нулём и НЕ переводится в другую валюту наугад:
  /// «нет данных» и «ноль» — разные вещи (R4/R6, честная стоимость).
  final double? cost;

  /// Код валюты ('USD', 'RUB' ...). Пустая строка — валюта неизвестна
  /// либо противоречива (суммы раундов в разных валютах не складываются).
  /// Пустая валюта НЕ означает 'USD'.
  final String currency;

  /// Токены входа (промпт).
  final int promptTokens;

  /// Токены выхода (ответ модели).
  final int completionTokens;

  const MessageCost({
    this.cost,
    this.currency = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  /// Символ валюты для интерфейса. Известная валюта не выдумывается:
  /// пустая (неизвестная) валюта даёт пустой символ, а не доллар.
  String get symbol {
    final cur = currency.trim().toUpperCase();
    if (cur == 'RUB') return '₽';
    if (cur == 'USD') return r'$';
    return cur;
  }

  /// Сумма в формате интерфейса с сохранением фактической точности
  /// ('1,875 ₽' — дробные копейки не отбрасываются; '0,42 ₽' — запятая
  /// как десятичный разделитель). Стоимость неизвестна (null) —
  /// возвращается 'Стоимость неизвестна', ноль не подставляется.
  String get formatted {
    final c = cost;
    if (c == null) return 'Стоимость неизвестна';
    var text = c.toStringAsFixed(8);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
    text = text.replaceAll('.', ',');
    final sym = symbol;
    return sym.isEmpty ? text : '$text $sym';
  }

  /// Всего токенов (вход + выход).
  int get totalTokens => promptTokens + completionTokens;

  Map<String, dynamic> toJson() => {
        'cost': cost,
        'currency': currency,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
      };

  /// Терпимый разбор сохранённой стоимости: отсутствие полей не
  /// подменяется значениями по умолчанию (cost не становится 0,
  /// валюта не становится 'USD') — нулевой списание и неизвестная
  /// сумма различимы.
  factory MessageCost.fromJson(Map j) => MessageCost(
        cost: _num(j['cost']),
        currency: j['currency'] is String
            ? (j['currency'] as String).trim()
            : '',
        promptTokens: _num(j['promptTokens'])?.toInt() ?? 0,
        completionTokens: _num(j['completionTokens'])?.toInt() ?? 0,
      );

  /// Разбор статистики использования провайдера.
  ///
  /// Если присутствует cost_rub, это фактическая сумма в рублях и она
  /// имеет приоритет над cost/total_cost, а валюта — 'RUB'. Сумма без
  /// валюты провайдера ('cost' без 'currency') не считается долларом:
  /// валюта остаётся пустой. Для ответов без cost_rub прежний порядок
  /// разбора сохранён.
  static MessageCost? fromUsage(Map? usage) {
    final u = usage;
    if (u == null) return null;
    final costRub = _num(u['cost_rub']);
    final cost = costRub ?? _num(u['cost']) ?? _num(u['total_cost']);
    final prompt = _num(u['prompt_tokens'])?.toInt() ?? 0;
    final completion = _num(u['completion_tokens'])?.toInt() ?? 0;
    if (cost == null && prompt == 0 && completion == 0) return null;
    final rawCurrency = u['currency'] is String
        ? (u['currency'] as String).trim()
        : '';
    final currency = costRub != null ? 'RUB' : rawCurrency;
    return MessageCost(
      cost: cost,
      currency: currency,
      promptTokens: prompt,
      completionTokens: completion,
    );
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
    return null;
  }
}

/// Текстовая часть сообщения.
class TextPart extends MessagePart {
  final String text;

  /// Стоимость ответа (из usage провайдера); null — стоимости нет.
  final MessageCost? cost;

  /// Ссылки-источники из ответа провайдера (citations/annotations).
  /// Пустой список — источников нет.
  final List<String> sources;

  const TextPart(this.text, {this.cost, this.sources = const <String>[]});

  @override
  String get label => text.trim().isEmpty ? '(пустой текст)' : text;

  @override
  String toString() => 'TextPart(${text.length} chars)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TextPart && other.text == text && other.cost == cost);

  @override
  int get hashCode => Object.hash(text, cost);
}

/// Изображение: либо локальный файл (путь на устройстве), либо ссылка
/// (например, data URL либо https-адрес). По договорённости ровно один
/// источник должен быть задан; конструкторы .fromPath/.fromUrl это
/// гарантируют, явная проверка в assert невозможна в const-конструкторе.
class ImagePart extends MessagePart {
  final String? localPath;
  final String? remoteUrl;

  const ImagePart({this.localPath, this.remoteUrl});

  /// Удобный конструктор для файла на устройстве.
  const ImagePart.fromPath(String path)
      : localPath = path,
        remoteUrl = null;

  /// Удобный конструктор для ссылки (data URL либо https).
  const ImagePart.fromUrl(String url)
      : localPath = null,
        remoteUrl = url;

  /// Задан ли локальный источник (иначе считается, что ссылка).
  bool get isLocal => (localPath ?? '').isNotEmpty;

  @override
  String get label =>
      isLocal ? 'изображение: $localPath' : 'изображение: $remoteUrl';

  @override
  String toString() => 'ImagePart(${isLocal ? localPath : remoteUrl})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImagePart &&
          other.localPath == localPath &&
          other.remoteUrl == remoteUrl);

  @override
  int get hashCode => Object.hash(localPath, remoteUrl);
}

/// Видео-фрагмент: локальный файл либо ссылка, как у [ImagePart].
class VideoPart extends MessagePart {
  final String? localPath;
  final String? remoteUrl;

  const VideoPart({this.localPath, this.remoteUrl});

  /// Удобный конструктор для файла на устройстве.
  const VideoPart.fromPath(String path)
      : localPath = path,
        remoteUrl = null;

  /// Удобный конструктор для ссылки.
  const VideoPart.fromUrl(String url)
      : localPath = null,
        remoteUrl = url;

  /// Задан ли локальный источник (иначе считается, что ссылка).
  bool get isLocal => (localPath ?? '').isNotEmpty;

  @override
  String get label => isLocal ? 'видео: $localPath' : 'видео: $remoteUrl';

  @override
  String toString() => 'VideoPart(${isLocal ? localPath : remoteUrl})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VideoPart &&
          other.localPath == localPath &&
          other.remoteUrl == remoteUrl);

  @override
  int get hashCode => Object.hash(localPath, remoteUrl);
}

/// Часть, которая ещё «в процессе»: например, вложение выбрано, но его
/// содержимое ещё не прочитано, либо выполняется асинхронная задача
/// генерации (видео) с прогрессом и идентификатором у провайдера.
class PendingPart extends MessagePart {
  /// Локальный путь файла, который обрабатывается (если известен).
  final String? localPath;

  /// Понятное имя (имя файла либо подпись операции).
  final String name;

  /// Идентификатор асинхронной задачи у провайдера ('' — пока не известен).
  final String jobId;

  /// Прогресс задачи в процентах (0..100).
  final double progress;

  /// true — провайдер не сообщил числовой прогресс, но задача «в
  /// процессе»: интерфейс должен показывать неопределённую индикацию,
  /// а не выдуманный процент (R6, п.8). По умолчанию false — процент
  /// известен и лежит в [progress].
  final bool indeterminate;

  /// Диагностика зависшей задачи (показ в карточке — этап 2):
  /// последние события исполнителя ('create: ...',
  /// 'poll N (http=X): ...', 'file: ') и путь JSONL-файла.
  final List<String>? debugSnippets;

  /// Путь к debug-файлу задачи; null — диагностика недоступна.
  final String? debugLogPath;

  const PendingPart({
    required this.name,
    this.localPath,
    this.jobId = '',
    this.progress = 0,
    this.indeterminate = false,
    this.debugSnippets,
    this.debugLogPath,
  });

  @override
  String get label => 'в обработке: $name';

  @override
  String toString() => 'PendingPart($name, $jobId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingPart &&
          other.name == name &&
          other.localPath == localPath &&
          other.jobId == jobId);

  @override
  int get hashCode => Object.hash(name, localPath, jobId);
}

/// Часть-ошибка: генерация ответа завершилась ошибкой [GenError].
/// Хранит исходный промпт пользователя и параметры для повторной
/// попытки; отображается через ErrorBubble.
class ErrorPart extends MessagePart {
  final GenError error;

  /// Промпт, на который не удалось получить ответ (для «Повторить»).
  final String originalPrompt;

  /// Параметры повторной попытки (модель, температура и т.п.).
  final Map<String, dynamic> retryParams;

  const ErrorPart({
    required this.error,
    this.originalPrompt = '',
    this.retryParams = const {},
  });

  @override
  String get label => 'ошибка: ${error.code}';

  @override
  String toString() => 'ErrorPart(${error.code})';
}

/// Часть неизвестного приложению типа: встречается при чтении истории,
/// записанной более новой версией приложения (partSchemaVersion выше
/// текущей), либо содержащей незнакомый тип части. Метка типа ([kind])
/// и сырые данные ([raw]) сохраняются при повторной сериализации —
/// часть не превращается в пустой текст и не теряется (R6, п.7).
///
/// ОТДЕЛЬНЫЙ лист sealed-иерархии [MessagePart] (не подтип TextPart):
/// исчерпывающие switch по частям (MessageView._partsWidgets и другие)
/// обязаны иметь явную ветку `case UnknownPart():`. В ленте чата часть
/// не рендерится (данные сохраняются при round-trip), но теперь она
/// типизирована честно: `is TextPart` больше не ловит UnknownPart.
class UnknownPart extends MessagePart {
  /// Метка исходного типа части ('audio', 'video_url', ...).
  final String kind;

  /// Сырые данные части в том виде, как они были сохранены.
  final Map<String, dynamic> raw;

  const UnknownPart({this.kind = '', this.raw = const <String, dynamic>{}});

  @override
  String get label =>
      kind.isEmpty ? 'неизвестная часть' : 'неизвестная часть: $kind';

  @override
  String toString() => 'UnknownPart($kind)';
}
```
