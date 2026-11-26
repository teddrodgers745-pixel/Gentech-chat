// Copyright (c) 2026 Minkail. All rights reserved.

import '../../models/chat_message.dart' show toolStatusDone, toolStatusError, toolStatusRunning;
import '../models/gen_error.dart';
import '../models/gen_error_mapper.dart';
import '../../services/chat_service.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';

/// Исполнитель генерации поверх существующего [ChatService].
///
/// Оборачивает поток [StreamChunk] в поток [GenerationEvent]:
///  - куски текста/размышлений -> [GenerationDelta];
///  - начало вызова инструмента -> [ToolCallStarted];
///  - прогресс задачи инструмента-медиа (видео) -> [GenProgress];
///  - завершение вызова (с медиа-результатом, если инструмент
///    оказался медиа-моделью) -> [ToolCallFinished];
///  - источники (citations/annotations) -> [SourcesReceived];
///  - любая ошибка -> [GenerationFailure] (последнее событие).
class ChatCompletionsExecutor extends GenerationExecutor {
  final ChatService _service;

  /// Сервис можно передать снаружи (для тестов); по умолчанию
  /// создаётся собственный экземпляр.
  ChatCompletionsExecutor([ChatService? service])
      : _service = service ?? ChatService();

  @override
  Stream<GenerationEvent> run(GenerationRequest request) async* {
    // Один и тот же URL может прийти в нескольких чанках; потребитель
    // должен получить SourcesReceived только с новыми источниками.
    final seenSources = <String>{};
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
          // События вызова инструмента: статус running без задачи —
          // начало; running с jobId — прогресс видео-задачи инструмента;
          // done/error — завершение (с медиа, если инструмент медиа).
          if (chunk.toolStatus == toolStatusRunning) {
            final jobId = (chunk.toolJobId ?? '').trim();
            if (jobId.isNotEmpty) {
              yield GenProgress(
                jobId: jobId,
                percent: chunk.toolProgress ?? 0,
              );
            } else {
              yield ToolCallStarted(
                name: toolName,
                arguments: chunk.toolArgs ?? '',
              );
            }
          } else {
            yield ToolCallFinished(
              name: toolName,
              result: chunk.toolResult ?? '',
              ok: (chunk.toolStatus ?? toolStatusDone) != toolStatusError,
              media: chunk.toolMedia,
            );
          }
          continue;
        }
        // Источники — отдельное событие: чат-сцена собирает их
        // в TextPart.sources для отображения в интерфейсе.
        if (chunk.sources.isNotEmpty) {
          final fresh = <String>[];
          for (final raw in chunk.sources) {
            final url = raw.trim();
            if (url.isEmpty) continue;
            if (seenSources.add(url)) fresh.add(url);
          }
          if (fresh.isNotEmpty) {
            yield SourcesReceived(sources: fresh);
          }
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
  ///
  /// Для ChatServiceException используется общий mapper, который отдаёт
  /// приоритет HTTP-статусу, а не цифрам в произвольном тексте провайдера.
  static GenError _mapError(Object error) {
    if (error is GenerationFailureHolder) {
      return error.error;
    }
    if (error is ChatServiceException) {
      return GenErrorMapper.fromException(error);
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
