// Copyright (c) 2026 Minkail. All rights reserved.

/// Нарушение комбинации параметров генерации, известной из ограничений
/// модели ([ModelParameters.constraints], например '1080p only with 6s').
/// Бросается при сборке тела запроса в
/// [ParameterTranslator.toImageBody]/[ParameterTranslator.toVideoBody];
/// исполнители превращают его в BadRequestError (карточка ошибки в чате).
class ParameterValidationException implements Exception {
  final String message;

  const ParameterValidationException(this.message);

  @override
  String toString() => message;
}
