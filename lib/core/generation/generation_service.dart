// Copyright (c) 2026 Minkail. All rights reserved.

import '../../app_state.dart';
import '../catalog/provider_catalog_service.dart';
import '../models/gen_error.dart';
import 'active_jobs_store.dart';
import 'async_job_executor.dart';
import 'chat_completions_executor.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';
import 'images_api_executor.dart';
import 'model_type_override_store.dart';

/// Фасад генерации. Ручной выбор типа имеет приоритет над каталогом.
class GenerationService {
  final GenerationExecutor? _customExecutor;
  final Set<GenerationExecutor> _running = <GenerationExecutor>{};
  int _cancelEpoch = 0;

  /// Исполнитель можно подменить, например, в тестах.
  GenerationService({GenerationExecutor? executor})
      : _customExecutor = executor;

  String? _connectionIdFor(GenerationRequest request) {
    return ModelTypeOverrideStore.resolveConnectionId(
      baseUrl: request.baseUrl,
      apiKey: request.apiKey,
    );
  }

  Future<GenerationExecutor?> _executorFor(
    GenerationRequest request,
  ) async {
    final custom = _customExecutor;
    if (custom != null) return custom;

    final modelId = request.model.trim();
    if (modelId.isEmpty) return null;

    // Маршрут из снимка повтора: воспроизводим исходный исполнитель,
    // не полагаясь на текущее состояние каталога или ручного override.
    // Так повтор видео гарантированно идёт в /v1/media, а не в текстовый
    // чат, даже если каталог/override с тех пор изменились.
    final hint = (request.routeHint ?? '').trim().toLowerCase();
    if (hint == ModelTypes.image) return ImagesApiExecutor();
    if (hint == ModelTypes.video) return AsyncJobExecutor();
    if (hint == ModelTypes.text) return ChatCompletionsExecutor();

    final connectionId = _connectionIdFor(request);
    if (connectionId == null) return null;

    final type = await ModelTypeOverrideStore.instance.resolveType(
      modelId,
      connectionId: connectionId,
    );
    switch (type) {
      case ModelTypes.image:
        return ImagesApiExecutor();
      case ModelTypes.video:
        return AsyncJobExecutor();
      case ModelTypes.text:
        return ChatCompletionsExecutor();
      default:
        return null;
    }
  }

  /// Запускает генерацию по [request] и отдаёт поток событий.
  Stream<GenerationEvent> generate(GenerationRequest request) async* {
    final epoch = _cancelEpoch;
    GenerationExecutor? executor;
    try {
      executor = await _executorFor(request);
    } catch (_) {
      executor = null;
    }

    if (epoch != _cancelEpoch) return;
    if (executor == null) {
      yield const GenerationFailure(
        BadRequestError(
          details: 'Не удалось определить тип модели по каталогу. '
              'Обновите каталог и повторите запрос.',
        ),
      );
      return;
    }

    _running.add(executor);
    try {
      yield* executor.run(request);
    } finally {
      _running.remove(executor);
    }
  }

  /// Продолжает опрос сохранённых видео-задач без повторного создания.
  Stream<GenerationEvent> restorePendingJobs() async* {
    if (_customExecutor != null) return;
    final jobs = await ActiveJobsStore.instance.loadAll();
    for (final record in jobs) {
      final executor = AsyncJobExecutor();
      _running.add(executor);
      try {
        await for (final ev in executor.resume(record)) {
          if (ev is GenerationFailure && ev.jobId.isEmpty) {
            yield GenerationFailure(ev.error, jobId: record.jobId);
          } else {
            yield ev;
          }
        }
      } catch (_) {
        // Запись остаётся в хранилище для следующего восстановления.
      } finally {
        _running.remove(executor);
      }
    }
  }

  /// Возобновляет ранее созданную задачу по её jobId. Если запись
  /// отсутствует в ActiveJobsStore, используется переданный fallback.
  Stream<GenerationEvent> resumeJob(
    String jobId, {
    String baseUrl = '',
    String apiKey = '',
    String model = '',
    String prompt = '',
  }) async* {
    final id = jobId.trim();
    if (id.isEmpty) {
      yield const GenerationFailure(
        UnknownGenError(details: 'Не указан идентификатор задачи.'),
      );
      return;
    }
    AsyncJobRecord? record;
    try {
      final jobs = await ActiveJobsStore.instance.loadAll();
      for (final r in jobs) {
        if (r.jobId == id) {
          record = r;
          break;
        }
      }
    } catch (_) {}
    final rec = record ??
        AsyncJobRecord(
          jobId: id,
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
          prompt: prompt,
        );
    if (rec.baseUrl.trim().isEmpty || rec.apiKey.trim().isEmpty) {
      yield const GenerationFailure(
        UnknownGenError(
          details: 'Не удалось восстановить данные задачи. '
              'Отправьте запрос заново.',
        ),
      );
      return;
    }
    final executor = AsyncJobExecutor();
    _running.add(executor);
    try {
      await for (final ev in executor.resume(rec)) {
        if (ev is GenerationFailure && ev.jobId.isEmpty) {
          yield GenerationFailure(ev.error, jobId: rec.jobId);
        } else {
          yield ev;
        }
      }
    } catch (_) {
      // Запись остаётся в хранилище для следующего восстановления.
    } finally {
      _running.remove(executor);
    }
  }

  /// Прерывает текущие исполнители, включая запросы до получения jobId.
  void cancel() {
    _cancelEpoch++;
    for (final executor in List<GenerationExecutor>.of(_running)) {
      executor.cancel();
    }
    AsyncJobExecutor.cancelAll();
  }
}
