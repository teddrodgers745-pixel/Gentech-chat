// Copyright (c) 2026 Minkail. All rights reserved.

import 'generation_event.dart';
import 'generation_request.dart';

/// Интерфейс исполнителя запроса на генерацию.
///
/// Исполнитель получает готовый неизменяемый [GenerationRequest]
/// и отдаёт поток [GenerationEvent]: дельты текста, события вызова
/// инструментов и финальная ошибка ([GenerationFailure]) — после неё
/// поток закрывается. Конкретные исполнители (например,
/// [ChatCompletionsExecutor]) оборачивают существующие сервисы.
abstract class GenerationExecutor {
  const GenerationExecutor();

  /// Запускает генерацию по [request].
  /// Поток одноразовый: один вызов — одна генерация.
  Stream<GenerationEvent> run(GenerationRequest request);

  /// Прерывает текущую генерацию, если она идёт.
  /// Безопасно вызывать, когда генерация не запущена.
  void cancel();
}
