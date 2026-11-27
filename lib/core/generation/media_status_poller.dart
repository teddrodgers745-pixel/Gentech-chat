// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

/// Отмена опроса из интерфейса (кнопка «стоп», смена чата).
class PollCancelled implements Exception {
  const PollCancelled();
}

/// Устойчивый сбой опроса: сеть недоступна [MediaStatusPoller.maxTransientRetries]
/// раз подряд в рамках попытки. Задача не отменена и не удалена — её статус
/// неизвестен, запись сохраняется для возобновления без повторной оплаты.
class PollTransientFailure implements Exception {
  final String message;

  const PollTransientFailure(this.message);

  @override
  String toString() => 'PollTransientFailure: $message';
}

/// Общий каркас цикла опроса статуса медиа-задачи (R6-audio-robustness-3,
/// п.8): единый для внутреннего цикла видео-задачи и публичного опроса
/// медиа-задачи инструмента в [AsyncJobExecutor]. Каркас отвечает за
/// интервалы между попытками, лимит попыток, транзиентные повторы
/// с нарастающей паузой и отмену; разбор ответа провайдера и превращение
/// его в [T] остаётся у вызывающей стороны через [attemptFn].
///
/// Контракт исключений:
/// - [PollCancelled] — внешняя отмена (isCancelled вернул true);
/// - [PollTransientFailure] — сеть недоступна, повторы исчерпаны
///   (бросается повторно после исчерпания [maxTransientRetries]);
/// - любые прочие исключения ([GenError], Exception) — фатальные для
///   попытки, транзитом передаются вызывающему без повторов.
class MediaStatusPoller<T> {
  /// Пауза между логическими попытками (успешными и «ещё не готово»).
  final Duration interval;

  /// Максимальное число логических попыток.
  final int maxAttempts;

  /// Сколько раз повторить при транзиентном сетевом сбое одной попытки.
  final int maxTransientRetries;

  /// База нарастающей паузы между транзиентными повторами (x1, x2, ...).
  final Duration transientBackoffBase;

  /// Внешний признак отмены (кнопка «стоп»); null — отмена не отслеживается.
  final bool Function()? isCancelled;

  /// Колбэк транзиентного повтора: (попытка, номер повтора, сообщение).
  final void Function(int attempt, int retry, String message)?
      onTransientRetry;

  const MediaStatusPoller({
    required this.interval,
    required this.maxAttempts,
    required this.maxTransientRetries,
    required this.transientBackoffBase,
    this.isCancelled,
    this.onTransientRetry,
  });

  /// Выполняет [attemptFn] по циклу опроса; каждое значение стрима —
  /// результат попытки, давшей статус (фатальный код, готовый URL
  /// либо «ещё выполняется» — решает вызывающая сторона).
  Stream<T> poll(Future<T> Function(int attempt) attemptFn) async* {
    for (var n = 1; n <= maxAttempts; n++) {
      var retry = 0;
      while (true) {
        if (isCancelled?.call() ?? false) {
          throw const PollCancelled();
        }
        try {
          yield await attemptFn(n);
          break;
        } on PollTransientFailure catch (e) {
          retry++;
          onTransientRetry?.call(n, retry, e.message);
          if (retry > maxTransientRetries) rethrow;
          await Future<void>.delayed(transientBackoffBase * retry);
        }
      }
      if (n < maxAttempts) {
        await Future<void>.delayed(interval);
      }
    }
  }
}
