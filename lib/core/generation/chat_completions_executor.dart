// Copyright (c) 2026 Minkail. All rights reserved.

import '../../models/chat_message.dart' show toolStatusDone, toolStatusError, toolStatusRunning;
import '../models/gen_error.dart';
import '../../services/chat_service.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';

/// Исполнитель генерации поверх существующего [ChatService].
///
/// Оборачивает поток [StreamChunk] в поток [GenerationEvent]:
///  - куски текста/размышлений -> [GenerationDelta];
///  - начало вызова инструмента -> [ToolCallStarted];
///  - завершение вызова -> [ToolCallFinished];
///  - любая ошибка -> [GenerationFailure] (последнее событие).
/// Сам ChatService и экран чата не меняются: исполнитель — только
/// адаптер над работающим кодом.
class ChatCompletionsExecutor extends GenerationExecutor {
  final ChatService _service;

  /// Сервис можно передать снаружи (для тестов); по умолчанию
  /// создаётся собственный экземпляр.
  ChatCompletionsExecutor([ChatService? service])
      : _service = service ?? ChatService();

  @override
  Stream<GenerationEvent> run(GenerationRequest request) async* {
    try {
      await for (final chunk in _service.sendMessage(
        baseUrl: request.baseUrl,
        apiKey: request.apiKey,
        model: request.model,
        messages: request.messages,
        stream: request.stream,
        temperature: request.temperature,
        reasoningEffort: request.reasoningEffort,
        tools: request.tools,
      )) {
        final toolName = chunk.toolName;
        if (toolName != null) {
          // События вызова инструмента: статус running -> начало,
          // done/error -> завершение.
          if (chunk.toolStatus == toolStatusRunning) {
            yield ToolCallStarted(
              name: toolName,
              arguments: chunk.toolArgs ?? '',
            );
          } else {
            yield ToolCallFinished(
              name: toolName,
              result: chunk.toolResult ?? '',
              ok: (chunk.toolStatus ?? toolStatusDone) != toolStatusError,
            );
          }
          continue;
        }
        final delta = GenerationDelta(
          content: chunk.content,
          reasoning: chunk.reasoning,
        );
        if (!delta.isEmpty) yield delta;
      }
    } catch (e) {
      // Пользователь сам нажал «стоп» — это не ошибка генерации.
      if (_service.wasCancelled) return;
      yield GenerationFailure(_mapError(e));
    }
  }

  @override
  void cancel() => _service.cancel();

  /// Перевод исключений сервиса в типизированные [GenError].
  /// ChatServiceException несёт готовый текст с кодом ответа провайдера
  /// ('Неверный API-ключ (401)...'), распознаём код по подстроке;
  /// сетевые сбои и всё прочее относятся к сетевой/неизвестной ошибке.
  static GenError _mapError(Object error) {
    if (error is GenerationFailureHolder) {
      return error.error;
    }
    if (error is ChatServiceException) {
      final m = error.message;
      if (m.contains('401')) return AuthError(details: m);
      if (m.contains('402')) return InsufficientFunds(details: m);
      if (m.contains('429')) return RateLimited(details: m);
      if (m.contains('404')) {
        return ModelNotFoundError(details: m);
      }
      if (m.contains('400') || m.contains('422')) {
        return BadRequestError(details: m);
      }
      if (m.contains('Ошибка 5') || m.contains('502') ||
          m.contains('503') || m.contains('504')) {
        return ServerError(details: m);
      }
      return UnknownGenError(details: m);
    }
    return NetworkError(details: 'Ошибка соединения: $error');
  }
}

/// Внутренняя обёртка, чтобы [ChatCompletionsExecutor._mapError] можно
/// было расширять без изменения публичного контракта. Практически не
/// используется: ошибки приходят как исключения.
class GenerationFailureHolder {
  final GenError error;
  const GenerationFailureHolder(this.error);
}
