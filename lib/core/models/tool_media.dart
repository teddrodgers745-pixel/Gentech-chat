// Copyright (c) 2026 Minkail. All rights reserved.

/// Медиа-результат модели-инструмента (image/video): материализуется
/// в чате как ImagePart/VideoPart, а не «текст вместо картинки».
///
/// TEMP-SHIM (R6-leftover-6-heal2): коммит R6-leftover-6 заменил
/// объявление класса реэкспортом (`export 'message_part.dart'
/// show ToolMedia`), рассчитывая, что класс объявлен в
/// message_part.dart. По логу CI message_part.dart НЕ экспортирует
/// ToolMedia — класс туда не попал, из-за чего сломались все
/// потребители (generation_event, chat_service, chat_screen,
/// model_tool_stream): имя перестало быть типом. Класс восстановлен
/// здесь как единственное объявление. Пока message_part.dart не
/// экспортирует ToolMedia, неоднозначности имён для файлов,
/// импортирующих обе библиотеки (chat_service, chat_screen), нет.
/// Переносить класс в message_part.dart можно только отдельной
/// задачей ОДНОВРЕМЕННО с правкой всех show-импортов — иначе имя
/// снова станет неоднозначным.
class ToolMedia {
  /// Ссылка на медиа-результат: http(s)/data URL либо локальный путь
  /// (в том числе с префиксом file://).
  final String url;

  /// Тип медиа ('image'/'video'): определяет, в какую часть чата
  /// материализуется результат. Пустая строка — тип не уточнён,
  /// трактуется как изображение.
  final String kind;

  const ToolMedia({required this.url, this.kind = ''});
}
