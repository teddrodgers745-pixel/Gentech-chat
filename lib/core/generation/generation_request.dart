// Copyright (c) 2026 Minkail. All rights reserved.

import '../../models/tool.dart';

/// Параметры одного запроса на генерацию. Собирается из EffectiveConfig
/// (lib/app_state.dart) и контекста чата; исполнители не читают настройки
/// напрямую, а получают готовый неизменяемый запрос.
class GenerationRequest {
  /// Адрес провайдера (Base URL без завершающего слэша).
  final String baseUrl;

  /// API-ключ пользователя.
  final String apiKey;

  /// Идентификатор модели, как его понимает провайдер.
  final String model;

  /// Сообщения в формате OpenAI API: {'role': ..., 'content': ...}.
  final List<Map<String, dynamic>> messages;

  /// SSE-стриминг ответа.
  final bool stream;

  /// Температура сэмплирования; null — параметр не отправляется.
  final double? temperature;

  /// Уровень размышлений ('medium', 'high' ...); null — не задан.
  final String? reasoningEffort;

  /// Инструменты, разрешённые модели (function calling).
  final List<Tool> tools;

  /// Предварительная оценка стоимости запроса в USD (для Artifact.cost);
  /// null — оценить не удалось.
  final double? estimatedUsd;

  /// Параметры генерации, собранные интерфейсом (aspect_ratio, duration,
  /// resolution ...). Нормализуются под конкретную модель через
  /// [ParameterTranslator] в исполнителе; пустая карта — параметров нет.
  final Map<String, dynamic> parameters;

  const GenerationRequest({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.messages,
    this.stream = true,
    this.temperature,
    this.reasoningEffort,
    this.tools = const <Tool>[],
    this.estimatedUsd,
    this.parameters = const <String, dynamic>{},
  });

  @override
  String toString() =>
      'GenerationRequest(model: $model, messages: ${messages.length}, '
      'stream: $stream, tools: ${tools.length})';
}

