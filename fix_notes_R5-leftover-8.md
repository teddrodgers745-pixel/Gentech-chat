# R5-leftover-8-heal1 — разбор упавшей сборки

## Что было не так
- CI упал на шаге `flutter analyze` (fatal-infos): `unnecessary_import` в
  `lib/screens/chat_screen.dart` — импорт `../core/models/tool_media.dart`
  избыточен, потому что `message_part.dart` уже реэкспортирует `ToolMedia`
  (все использования — `List<ToolMedia>` в `_attachToolMedia`, `ch.toolMedia`
  — резолвятся через этот реэкспорт).
- Это НЕ `unused_import` из правила проекта «не удалять импорты»: `unnecessary_import`
  означает дублирующий путь импорта того же символа, удаление не меняет поведение.

## Что поправил
- Удалил единственную строку `import '../core/models/tool_media.dart';` из
  `chat_screen.dart` (строка 31). Ни один другой файл и символ не тронуты;
  полный путь UI → сервис → исполнитель → API → ответ → UI не затронут.

## Что стоит улучшить рядом
- В `message_part.dart` стоит явно задокументировать реэкспорт `tool_media.dart`
  (barrel-файл), чтобы новые импорты `ToolMedia` сразу шли через него и
  такие предупреждения не появлялись.
- Рассмотреть прагматику CI: `flutter analyze --no-fatal-infos` либо явный
  `// ignore: unnecessary_import` не рекомендую — лучше держать импорты
  каноническими; правило проекта про «не удалять unused_import» стоит уточнить,
  чтобы отделять его от `unnecessary_import`, который роняет analyze.
