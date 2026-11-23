// Copyright (c) 2026 Minkail. All rights reserved.

// Частичное исправление: для Polza отклоняется запись, которая целиком
// получена из резервного источника. Это НЕ решает всю задачу: lookup может
// синтезировать тип и для записи подключения с пустым исходным type.
// ChatScreen, повтор, обновление каталога, параметры и диагностика
// исключения в этом результате не исправлены.

import '../../app_state.dart';
import '../auth/polza_auth_service.dart';
import '../catalog/provider_catalog_service.dart';
import '../models/gen_error.dart';
import 'active_jobs_store.dart';
import 'async_job_executor.dart';
import 'chat_completions_executor.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';
import 'images_api_executor.dart';

/// Фасад генерации. Вид модели определяется по типу записи каталога
/// активного подключения; неизвестный тип не направляется в текстовый чат.
class GenerationService {
  final GenerationExecutor? _customExecutor;
  final Set<GenerationExecutor> _running = <GenerationExecutor>{};
  int _cancelEpoch = 0;

  /// Исполнитель можно подменить, например, в тестах.
  GenerationService({GenerationExecutor? executor})
      : _customExecutor = executor;

  String? _connectionIdFor(GenerationRequest request) {
    final pr = presets.active;
    if (pr != null &&
        pr.id != PresetStore.defaultPresetId &&
        pr.baseUrl.trim().isNotEmpty &&
        pr.apiKey.trim().isNotEmpty) {
      return 'preset:${pr.id}';
    }

    final url = request.baseUrl.trim().toLowerCase();
    final key = request.apiKey.trim();
    if (url.isEmpty || key.isEmpty) {
      if (polzaAuth.isAuthenticated &&
          polzaAuth.accessToken.trim().isNotEmpty) {
        return 'polza';
      }
      return null;
    }
    if (url.contains('polza.ai')) return 'polza';
    if (url.contains('routerai')) return 'routerai';
    if (pr != null &&
        pr.baseUrl.trim().isNotEmpty &&
        pr.apiKey.trim().isNotEmpty) {
      return 'preset:${pr.id}';
    }
    return 'global';
  }

  Future<GenerationExecutor?> _executorFor(
    GenerationRequest request,
  ) async {
    final custom = _customExecutor;
    if (custom != null) return custom;

    final connectionId = _connectionIdFor(request);
    if (connectionId == null || request.model.trim().isEmpty) return null;

    final entry = await providerCatalog.lookup(connectionId, request.model);
    final isPolza = request.baseUrl.toLowerCase().contains('polza.ai') ||
        connectionId == 'polza';
    if (isPolza && entry.capabilitiesSource != CatalogSources.connection) {
      return null;
    }

    final type = entry.type.trim().toLowerCase();
    switch (type) {
      case 'image':
        return ImagesApiExecutor();
      case 'video':
        return AsyncJobExecutor();
      case 'chat':
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

  /// Прерывает текущие исполнители, включая запросы до получения jobId.
  void cancel() {
    _cancelEpoch++;
    for (final executor in List<GenerationExecutor>.of(_running)) {
      executor.cancel();
    }
    AsyncJobExecutor.cancelAll();
  }
}
