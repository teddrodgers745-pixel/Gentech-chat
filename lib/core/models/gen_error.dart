// Copyright (c) 2026 Minkail. All rights reserved.

/// Ошибка генерации, распознанная по ответу провайдера. Sealed-тип:
/// интерфейс и сервисы смогут обрабатывать все подтипы исчерпывающим
/// switch без default. Тексты — по-русски, готовые для показа пользователю.
/// Пока никем не подключён — фундамент для следующих этапов.
sealed class GenError implements Exception {
  const GenError();

  /// Понятное сообщение для пользователя.
  String get message;

  /// Короткий машинный код ошибки ('auth', 'funds', 'rate_limit', ...).
  String get code;

  @override
  String toString() => '$GenError($code): $message';
}

/// Неверный или отсутствующий API-ключ (401/403).
class AuthError extends GenError {
  const AuthError({this.details = ''});

  /// Дополнительные сведения от провайдера (без ключа).
  final String details;

  @override
  String get code => 'auth';

  @override
  String get message => details.trim().isEmpty
      ? 'Неверный API-ключ. Проверьте его в настройках.'
      : 'Неверный API-ключ. $details';
}

/// Недостаточно средств на балансе провайдера (402).
class InsufficientFunds extends GenError {
  const InsufficientFunds({this.details = ''});

  final String details;

  @override
  String get code => 'funds';

  @override
  String get message => details.trim().isEmpty
      ? 'Недостаточно средств на балансе провайдера.'
      : 'Недостаточно средств на балансе провайдера. $details';
}

/// Слишком много запросов (429). Может содержать рекомендованную паузу.
class RateLimited extends GenError {
  const RateLimited({this.retryAfter, this.details = ''});

  /// Рекомендованная пауза из заголовка Retry-After (секунды), если есть.
  final Duration? retryAfter;

  final String details;

  @override
  String get code => 'rate_limit';

  @override
  String get message {
    final base = 'Слишком много запросов. Подождите немного и повторите.';
    final wait = retryAfter;
    if (wait != null && wait.inSeconds > 0) {
      return '$base Повторите через ${wait.inSeconds} с.';
    }
    return details.trim().isEmpty ? base : '$base $details';
  }
}

/// Модель не найдена у провайдера (404) либо не поддерживает запрос.
class ModelNotFoundError extends GenError {
  const ModelNotFoundError({this.modelId = '', this.details = ''});

  final String modelId;
  final String details;

  @override
  String get code => 'model_not_found';

  @override
  String get message => modelId.trim().isEmpty
      ? 'Модель не найдена у провайдера.'
      : 'Модель «$modelId» не найдена у провайдера.';
}

/// Сервер провайдера недоступен или ответил ошибкой 5xx.
class ServerError extends GenError {
  const ServerError({this.statusCode, this.details = ''});

  final int? statusCode;
  final String details;

  @override
  String get code => 'server';

  @override
  String get message {
    final sc = statusCode;
    final prefix = sc != null ? 'Ошибка сервера провайдера ($sc).' : 'Ошибка сервера провайдера.';
    return details.trim().isEmpty ? prefix : '$prefix $details';
  }
}

/// Проблема с сетью: таймаут, обрыв соединения, DNS и т.п.
class NetworkError extends GenError {
  const NetworkError({this.details = ''});

  final String details;

  @override
  String get code => 'network';

  @override
  String get message => details.trim().isEmpty
      ? 'Ошибка соединения. Проверьте интернет и повторите.'
      : 'Ошибка соединения. $details';
}

/// Запрос отклонён провайдером по содержимому либо неверным параметрам (400/422).
class BadRequestError extends GenError {
  const BadRequestError({this.details = ''});

  final String details;

  @override
  String get code => 'bad_request';

  @override
  String get message => details.trim().isEmpty
      ? 'Запрос отклонён провайдером.'
      : 'Запрос отклонён провайдером. $details';
}

/// Любая неопознанная ошибка генерации.
class UnknownGenError extends GenError {
  const UnknownGenError({this.details = ''});

  final String details;

  @override
  String get code => 'unknown';

  @override
  String get message => details.trim().isEmpty
      ? 'Неизвестная ошибка генерации.'
      : 'Неизвестная ошибка генерации. $details';
}
