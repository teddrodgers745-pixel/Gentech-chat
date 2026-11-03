// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/model_info.dart';
import '../providers/heuristic_rules.dart';
import 'active_jobs_store.dart';
import 'async_job_executor.dart';
import 'chat_completions_executor.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';

/// Фасад генерации: единая точка входа для запросов к модели.
///
/// Выбор исполнителя — по маршруту модели ([GenerationRoute]): чат-модели
/// идут через [ChatCompletionsExecutor], модели асинхронных видео-задач
/// (kling, veo, sora, wan ...) — через [AsyncJobExecutor]. Восстановление
/// незавершённых задач после перезапуска приложения — [restorePendingJobs]:
/// записи берутся из [ActiveJobsStore], опрос продолжается без повторного
/// создания задачи.
class GenerationService {
  final GenerationExecutor? _customExecutor;
  ChatCompletionsExecutor? _chatExecutor;
  AsyncJobExecutor? _asyncExecutor;

  /// Исполнитель можно подменить (например, в тестах); по умолчанию
  /// исполнитель выбирается по маршруту модели.
  GenerationService({GenerationExecutor? executor})
      : _customExecutor = executor;

  GenerationExecutor _executorFor(String modelId) {
    final custom = _customExecutor;
    if (custom != null) return custom;
    final route =
        HeuristicRules.inferRoute(HeuristicRules.normalize(modelId));
    if (route == GenerationRoute.asyncJob) {
      return _asyncExecutor ??= AsyncJobExecutor();
    }
    return _chatExecutor ??= ChatCompletionsExecutor();
  }

  /// Запускает генерацию по [request] и отдаёт поток событий.
  Stream<GenerationEvent> generate(GenerationRequest request) =>
      _executorFor(request.model).run(request);

  /// Восстановление незавершённых асинхронных задач (видео) после
  /// перезапуска приложения. Для каждой сохранённой [AsyncJobRecord]
  /// продолжается цикл опроса; ошибкам без привязки приписывается
  /// идентификатор задачи, чтобы интерфейс нашёл соответствующую
  /// PendingPart в чате. Сбой одной задачи не прерывает восстановление
  /// остальных.
  Stream<GenerationEvent> restorePendingJobs() async* {
    if (_customExecutor != null) return;
    final jobs = await ActiveJobsStore.instance.loadAll();
    for (final record in jobs) {
      final executor = AsyncJobExecutor();
      _asyncExecutor = executor;
      try {
        await for (final ev in executor.resume(record)) {
          if (ev is GenerationFailure && ev.jobId.isEmpty) {
            yield GenerationFailure(ev.error, jobId: record.jobId);
          } else {
            yield ev;
          }
        }
      } catch (_) {
        // Сетевая или иная трудность: запись остаётся в хранилище,
        // восстановление повторится при следующем запуске.
      } finally {
        if (identical(_asyncExecutor, executor)) _asyncExecutor = null;
      }
    }
  }

  /// Прерывает текущую генерацию: чат-исполнитель и все активные
  /// асинхронные задачи.
  void cancel() {
    _chatExecutor?.cancel();
    AsyncJobExecutor.cancelAll();
  }
}
