# R6-leftover-6-heal2 — замечания

## Причина (не симптом)
Коммит R6-leftover-6 превратил `lib/core/models/tool_media.dart` в TEMP-SHIM с реэкспортом
`export 'message_part.dart' show ToolMedia`, рассчитывая, что класс `ToolMedia` объявлен в
`message_part.dart`. По логу analyzer класс там ОТСУТСТВУЕТ («doesn't export a member with
the shown name 'ToolMedia'» на все три show-импорта и на сам export) — 11 ошибок
`non_type_as_type_argument` и 6 предупреждений во всех потребителях
(generation_event, chat_service, chat_screen, model_tool_stream).

## Что исправлено
1. `lib/core/models/tool_media.dart` — класс `ToolMedia` восстановлен здесь как ЕДИНСТВЕННОЕ
   объявление (минимальный контракт по фактическому использованию: `url` (required), `kind`
   (default '')). Реэкспорт убран — он ссылался на несуществующее имя.
2. `lib/core/generation/generation_event.dart` — show-импорт из message_part.dart заменён на
   импорт `tool_media.dart` (message_part в этом файле больше ничем не используется).
3. `lib/services/chat_service.dart` — снят битый `show ToolMedia` с импорта message_part.dart
   (импорт сохранён по правилам проекта, помечен `// ignore: unused_import`); импорт
   tool_media.dart теперь реально используется — ignore-комментарий убран.
4. `lib/screens/chat_screen.dart` — добавлен импорт `tool_media.dart` (использовался
   `ToolMedia` в `_attachToolMedia` без импорта источника типа).
5. `lib/services/model_tool_stream.dart` — НЕ менялся: все его ошибки/предупреждения
   лечатся восстановлением класса.

## Чего не хватило
- `lib/core/models/message_part.dart` не был прислан. Именно он — «постоянное место»
  ToolMedia по замыслу R5-leftover-8. Рекомендую отдельной задачей очистки перенести класс
  в message_part.dart (рядом с MessagePart) и удалить shim-файл, ОДНОВРЕМЕННО поправив все
  show-импорты — иначе имя снова станет неоднозначным для файлов, импортирующих обе
  библиотеки (chat_service, chat_screen).

## Стоит улучшить рядом
- `flutter analyze` в CI считает warnings фатальными — не оставлять show-импорты по именам,
  которых библиотека не экспортирует: это маскируется под «unused import», а фактически
  ломает тип.
- Смоук-тест компиляции `ToolMedia` (тривиальный usage-тест) спас бы от такого каскада:
  сейчас ошибка всплыла только на этапе Analyze, а не в тестах.
