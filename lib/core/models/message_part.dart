// Copyright (c) 2026 Minkail. All rights reserved.

/// Часть составного сообщения: то, из чего состоит пользовательский запрос
/// или ответ модели. Базовый sealed-тип гарантирует, что switch по частям
/// будет исчерпывающим без default — новые типы добавляются явно.
/// Пока никем не подключён — фундамент для мультимодального ввода.
sealed class MessagePart {
  const MessagePart();

  /// Краткая человекочитаемая подпись части (для отладки и будущих UI).
  String get label;
}

/// Текстовая часть сообщения.
class TextPart extends MessagePart {
  final String text;

  const TextPart(this.text);

  @override
  String get label => text.trim().isEmpty ? '(пустой текст)' : text;

  @override
  String toString() => 'TextPart(${text.length} chars)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is TextPart && other.text == text);

  @override
  int get hashCode => text.hashCode;
}

/// Изображение: либо локальный файл (путь на устройстве), либо ссылка
/// (например, data URL либо https-адрес). Ровно один источник задан.
class ImagePart extends MessagePart {
  final String? localPath;
  final String? remoteUrl;

  const ImagePart({this.localPath, this.remoteUrl})
      : assert(
          (localPath != null && localPath!.isNotEmpty) ||
              (remoteUrl != null && remoteUrl!.isNotEmpty),
          'ImagePart: нужен localPath либо remoteUrl',
        );

  /// Удобный конструктор для файла на устройстве.
  const ImagePart.fromPath(String path)
      : localPath = path,
        remoteUrl = null;

  /// Удобный конструктор для ссылки (data URL либо https).
  const ImagePart.fromUrl(String url)
      : localPath = null,
        remoteUrl = url;

  bool get isLocal => (localPath ?? '').isNotEmpty;

  @override
  String get label =>
      isLocal ? 'изображение: ${localPath!}' : 'изображение: ${remoteUrl!}';

  @override
  String toString() => 'ImagePart(${isLocal ? localPath : remoteUrl})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImagePart &&
          other.localPath == localPath &&
          other.remoteUrl == remoteUrl);

  @override
  int get hashCode => Object.hash(localPath, remoteUrl);
}

/// Видео-фрагмент: локальный файл либо ссылка, как у [ImagePart].
class VideoPart extends MessagePart {
  final String? localPath;
  final String? remoteUrl;

  const VideoPart({this.localPath, this.remoteUrl})
      : assert(
          (localPath != null && localPath!.isNotEmpty) ||
              (remoteUrl != null && remoteUrl!.isNotEmpty),
          'VideoPart: нужен localPath либо remoteUrl',
        );

  /// Удобный конструктор для файла на устройстве.
  const VideoPart.fromPath(String path)
      : localPath = path,
        remoteUrl = null;

  /// Удобный конструктор для ссылки.
  const VideoPart.fromUrl(String url)
      : localPath = null,
        remoteUrl = url;

  bool get isLocal => (localPath ?? '').isNotEmpty;

  @override
  String get label => isLocal ? 'видео: ${localPath!}' : 'видео: ${remoteUrl!}';

  @override
  String toString() => 'VideoPart(${isLocal ? localPath : remoteUrl})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VideoPart &&
          other.localPath == localPath &&
          other.remoteUrl == remoteUrl);

  @override
  int get hashCode => Object.hash(localPath, remoteUrl);
}

/// Часть, которая ещё «в процессе»: например, вложение выбрано, но его
/// содержимое ещё не прочитано или ещё не загружено на провайдера.
class PendingPart extends MessagePart {
  /// Локальный путь файла, который обрабатывается (если известен).
  final String? localPath;

  /// Понятное имя (имя файла либо подпись операции).
  final String name;

  const PendingPart({required this.name, this.localPath});

  @override
  String get label => 'в обработке: $name';

  @override
  String toString() => 'PendingPart($name)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingPart &&
          other.name == name &&
          other.localPath == localPath);

  @override
  int get hashCode => Object.hash(name, localPath);
}
