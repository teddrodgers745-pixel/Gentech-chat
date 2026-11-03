// Copyright (c) 2026 Minkail. All rights reserved.

import 'chat_completions_executor.dart';
import 'generation_event.dart';
import 'generation_executor.dart';
import 'generation_request.dart';

/// Фасад генерации: единая точка входа для запросов к модели.
///
/// Скрывает выбор исполнителя от вызывающего кода: интерфейс работает
/// только с [GenerationRequest] и потоком [GenerationEvent]. Пока
/// используется [ChatCompletionsExecutor] поверх работающего ChatService;
/// новые маршруты (изображения, responses API) добавляются как отдельные
/// исполнители без изменения вызывающего кода.
class GenerationService {
  final GenerationExecutor _executor;

  /// Исполнитель можно подменить (например, в тестах);
  /// по умолчанию — исполнитель чат-комплешенов.
  GenerationService({GenerationExecutor? executor})
      : _executor = executor ?? ChatCompletionsExecutor();

  /// Запускает генерацию по [request] и отдаёт поток событий.
  Stream<GenerationEvent> generate(GenerationRequest request) =>
      _executor.run(request);

  /// Прерывает текущую генерацию (если исполнитель её поддерживает).
  void cancel() => _executor.cancel();
}
