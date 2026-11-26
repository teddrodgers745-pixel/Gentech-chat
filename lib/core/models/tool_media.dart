// Copyright (c) 2026 Minkail. All rights reserved.

/// TEMP-SHIM (R5-leftover-8): постоянное место типа [ToolMedia] —
/// core/models/message_part.dart (рядом с MessagePart), куда он теперь
/// добавлен. Раньше класс объявлялся здесь, но одновременное объявление
/// в двух библиотеках делает имя неоднозначным для chat_screen/chat_service,
/// которые импортируют оба файла. Реэкспорт сохраняет все существующие
/// импорты (`import '../core/models/tool_media.dart'`) рабочими и даёт
/// ровно тот же тип, что и прямой импорт message_part.dart. Файл можно
/// удалить отдельной задачей очистки вместе с правкой импортов.
export 'message_part.dart' show ToolMedia;
