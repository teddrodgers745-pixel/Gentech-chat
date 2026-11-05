// Copyright (c) 2026 Minkail. All rights reserved.

import 'gen_error.dart';

/// Часть составного сообщения: то, из чего состоит пользовательский запрос
/// или ответ модели. Базовый sealed-тип гарантирует, что switch по частям
/// будет исчерпывающим без default — новые типы добавляются явно.
/// Пока никем не подключён — фундамент для мультимодального ввода.
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
  /// Стоимость ответа в валюте [currency].
  final double cost;

  /// Код валюты ('USD', 'RUB' ...).
  final String currency;

  /// Токены входа (промпт).
  final int promptTokens;

  /// Токены выхода (ответ модели).
  final int completionTokens;

  const MessageCost({
    required this.cost,
    this.currency = 'USD',
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  /// Символ валюты для интерфейса.
  String get symbol => currency.trim().toUpperCase() == 'RUB' ? '₽' : r'$';

  /// Сумма в формате интерфейса: '0,42 ₽' (запятая как десятичный
  /// разделитель, как принято в русском тексте).
  String get formatted {
    final s = cost.toStringAsFixed(2);
    return '${s.replaceAll('.', ',')} $symbol';
  }

  /// Всего токенов (вход + выход).
  int get totalTokens => promptTokens + completionTokens;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cost': cost,
        'currency': currency,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
      };

  factory MessageCost.fromJson(Map<String, dynamic> j) => MessageCost(
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
        currency: (j['currency'] as String?) ?? 'USD',
        promptTokens: (j['promptTokens'] as num?)?.toInt() ?? 0,
        completionTokens: (j['completionTokens'] as num?)?.toInt() ?? 0,
      );

  /// Разбор статистики использования провайдера (usage из ответа
  /// /chat/completions): стоимость из полей cost/total_cost, валюта из
  /// currency, токены из prompt_tokens/completion_tokens.
  /// null — данных недостаточно, строку стоимости не показываем.
  static MessageCost? fromUsage(Map<String, dynamic>? usage) {
    final u = usage;
    if (u == null) return null;
    final cost = _num(u['cost']) ?? _num(u['total_cost']);
    final prompt = _num(u['prompt_tokens'])?.toInt() ?? 0;
    final completion = _num(u['completion_tokens'])?.toInt() ?? 0;
    if (cost == null && prompt == 0 && completion == 0) return null;
    final currency = (u['currency'] as String?) ?? 'USD';
    return MessageCost(
      cost: cost ?? 0,
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

  /// Диагностика зависшей задачи (показ в карточке — этап 2):
  /// последние события исполнителя ('create: ...',
  /// 'poll N (http=X): ...', 'file: <путь>') и путь JSONL-файла.
  final List<String>? debugSnippets;

  /// Путь к debug-файлу задачи; null — диагностика недоступна.
  final String? debugLogPath;

  const PendingPart({
    required this.name,
    this.localPath,
    this.jobId = '',
    this.progress = 0,
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
    this.retryParams = const <String, dynamic>{},
  });

  @override
  String get label => 'ошибка: ${error.code}';

  @override
  String toString() => 'ErrorPart(${error.code})';
}
