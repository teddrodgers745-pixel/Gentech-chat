// Copyright (c) 2026 Minkail. All rights reserved.

/// Диалект API генерации изображений у провайдера.
///
/// Провайдеры с OpenAI-совместимым API различаются тем, на какой эндпоинт
/// уходит запрос картинки:
///  - [openAiStandard] — POST {baseUrl}/images/generations (Polza и
///    большинство OpenAI-совместимых провайдеров);
///  - [shortImagesPath] — POST {baseUrl}/images (RouterAI);
///  - [openRouterChatImages] — POST {baseUrl}/chat/completions с полями
///    modalities и image_config (OpenRouter).
enum ImageApiDialect {
  openAiStandard,
  shortImagesPath,
  openRouterChatImages,
}

/// Определяет [ImageApiDialect] по адресу провайдера и его идентификатору.
/// Источник истины — Base URL пользователя; providerId используется как
/// дополнительная подсказка, если он известен (пресет).
abstract final class ImageDialectResolver {
  /// Диалект для комбинации baseUrl/providerId.
  /// Неизвестные провайдеры получают стандартный OpenAI-диалект.
  static ImageApiDialect resolve({
    required String baseUrl,
    String providerId = '',
  }) {
    final id = providerId.trim().toLowerCase();
    if (id == 'openrouter') return ImageApiDialect.openRouterChatImages;
    if (id == 'routerai') return ImageApiDialect.shortImagesPath;
    final host = (Uri.tryParse(baseUrl.trim())?.host ?? baseUrl.trim())
        .toLowerCase();
    if (host.contains('openrouter')) {
      return ImageApiDialect.openRouterChatImages;
    }
    if (host.contains('routerai')) return ImageApiDialect.shortImagesPath;
    return ImageApiDialect.openAiStandard;
  }

  /// Основной эндпоинт диалекта (путь после Base URL).
  static String primaryPath(ImageApiDialect dialect) => switch (dialect) {
        ImageApiDialect.openAiStandard => '/images/generations',
        ImageApiDialect.shortImagesPath => '/images',
        ImageApiDialect.openRouterChatImages => '/chat/completions',
      };

  /// Альтернативный REST-эндпоинт для автоматического фоллбэка
  /// (404/405 от основного). null — фоллбэка нет.
  static String? fallbackRestPath(ImageApiDialect dialect) => switch (dialect) {
        ImageApiDialect.openAiStandard => '/images',
        ImageApiDialect.shortImagesPath => '/images/generations',
        ImageApiDialect.openRouterChatImages => null,
      };
}
