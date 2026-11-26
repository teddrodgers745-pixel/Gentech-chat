// Copyright (c) 2026 Minkail. All rights reserved.

/// Типизированный медиа-результат модели-инструмента.
///
/// NOTE(heal1): постоянное место типа — core/models/message_part.dart
/// (рядом с MessagePart). По логу CI коммит R5 ссылался на ToolMedia,
/// но message_part.dart его не экспортирует (undefined_shown_name),
/// а сам файл не был прислан. Пока тип определён здесь; после появления
/// ToolMedia в message_part.dart импорты в chat_service/chat_screen
/// переключаются туда, а этот файл удаляется.
class ToolMedia {
  /// Ссылка на результат: локальный путь ('/…') либо http(s)/data URL.
  final String url;

  /// Вид результата: 'image' | 'video'.
  final String kind;

  const ToolMedia({required this.url, required this.kind});
}
