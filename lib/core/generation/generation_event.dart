// Copyright (c) 2026 Minkail. All rights reserved.

import '../models/gen_error.dart';

/// Событие генерации, приходящее из [GenerationExecutor] потоковым
/// образом. Sealed-тип: обработка switch исчерпывающая без default —
/// новые виды событий добавляются явно.
sealed class GenerationEvent {
  const GenerationEvent();
}

/// Дельта текста и/или размышлений модели. Поля дополняются
/// накопительно вызывающей стороной.
class GenerationDelta extends GenerationEvent {
  final String content;
  final String reasoning;

  const GenerationDelta({this.content = '', this.reasoning = ''});

  /// Пустая дельта ничего не меняет в интерфейсе.
  bool get isEmpty => content.isEmpty && reasoning.isEmpty;
}

/// Модель запросила вызов инструмента: начинается выполнение.
class ToolCallStarted extends GenerationEvent {
  final String name;
  final String arguments;

  const ToolCallStarted({required this.name, this.arguments = ''});
}

/// Выполнение инструмента завершилось (успешно либо с ошибкой).
class ToolCallFinished extends GenerationEvent {
  final String name;
  final String result;
  final bool ok;

  const ToolCallFinished({
    required this.name,
    required this.ok,
    this.result = '',
  });
}

/// Генерация завершена ошибкой; текст готов для показа пользователю.
/// Прилетает последним событием, после него поток закрывается.
class GenerationFailure extends GenerationEvent {
  final GenError error;

  const GenerationFailure(this.error);

  @override
  String toString() => 'GenerationFailure(${error.code})';
}

