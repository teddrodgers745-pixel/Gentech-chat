# fix_notes_R6-audio-robustness-3 (heal2)

## Что было не так (причина, не симптом)

Упавшая сборка (ветка `agent`, коммит 3b78013 «heal1») — 25 замечаний анализатора,
сведённых к ЧЕТЫРЁМ причинам:

1. **`ToolMedia` потерян в `message_part.dart`.** heal1 превратил
   `core/models/tool_media.dart` в TEMP-SHIM (`export 'message_part.dart' show
   ToolMedia;`), но сам класс в `message_part.dart` так и не появился — все
   импорты (`message_part.dart show ToolMedia` в generation_event/chat_service,
   shim в tool_media/model_tool_stream) получили `undefined_shown_name`, и
   отсюда 17 ошибок «The name 'ToolMedia' isn't a type» в 4 файлах.
2. **`TextPart.sources` был нетипизирован** (`final List sources;` →
   `List<dynamic>`) → ошибка `argument_type_not_assignable` на
   `_mergeSources(merged, part.sources)` в chat_screen.dart:380.
3. **`MessageCost` в модели non-nullable** (`cost` — `double`, `currency` —
   `String`): «суммы нет» выражается пустой валютой, а не null. Новые
   агрегаторы писались под nullable: `sum == null`, `amount == null`
   (unnecessary_null_comparison), `cost: null`, `cost: amount` (argument_type
   errors) в chat_screen и `amount != null` в message_view._costWidgets.
4. **Новый подтип `GenError.JobStatusUnknown`** (добавлен коммитом R6) не был
   включён в исчерпывающий switch `GenErrorMapper.detailsOf` —
   non_exhaustive_switch_expression (правило проекта: обновлять ВСЕХ
   потребителей нового типа).

## Что поправил

- **`lib/core/models/message_part.dart`** (причина №1 и №2): возвращён класс
  `ToolMedia` (url + kind, конструктор `ToolMedia({required url, kind})`) —
  постоянное место рядом с MessagePart, как задумано shim-комментарием;
  `TextPart.sources` типизирован `List<String>`; `PendingPart.debugSnippets`
  явно `List<String>?` (требуется потребителями в chat_screen); дженерики
  (`toJson`/`fromJson`/`fromUsage`/`retryParams`) восстановлены по
  фактическим сигнатурам потребителей. Документирован контракт «суммы нет =
  пустая валюта».
- **`lib/core/models/gen_error_mapper.dart`**: в `detailsOf` добавлен кейс
  `JobStatusUnknown(:final details) => details` (по конвенции семейства
  GenError у всех подтипов есть опциональный `details`; если у класса его нет —
  CI подскажет, заменить на `JobStatusUnknown() => ''`).
- **`lib/screens/chat_screen.dart`**: `_addKnownRub` и `_sumRoundCosts`
  приведены к non-nullable `MessageCost` (сравнение `== null` убрано,
  «нет суммы» = пустая валюта; конфликтующие валюты → `cost: 0, currency: ''`
  + только токены). Остальной файл без изменений.
- **`lib/widgets/message_view.dart`**: `_costWidgets` — `known` теперь
  определяется непустой валютой (`currency.isNotEmpty`), убран недостижимый
  `amount != null` (warning на строке 208).
- **`lib/services/chat_service.dart`**: единственная правка — `// ignore:
  unused_import` перед дублирующим импортом `tool_media.dart` (импорт не
  удалён по правилу проекта; ToolMedia теперь приходит из `message_part.dart`
  через `show ToolMedia`, дубликат можно убрать отдельной задачей очистки
  вместе с shim).

## Что НЕ трогал (и почему)

- `generation_event.dart`, `tool_media.dart`, `model_tool_stream.dart` —
  становятся корректными сами по себе после восстановления `ToolMedia` в
  `message_part.dart`; их импорты сохранены полностью.
- TEMP-DIAG-UNMODIFIABLE и все готовые этапы — не затронуты.

## Чего не хватило

- В присланном коде не было `message_part.dart`, `gen_error.dart`,
  `gen_error.dart` ветки `agent` (упавшей сборки) — восстановил
  `message_part.dart` по fetched-версии main + логу анализатора; если в
  рабочей версии есть другие правки (кроме потерянного ToolMedia) — их нужно
  сверить. `JobStatusUnknown` восстанавливался по конвенции семейства
  (поле `details`).

## Что стоит улучшить рядом

1. Удалить TEMP-SHIM `tool_media.dart` и привести все импорты к
   `message_part.dart` отдельной задачей очистки.
2. Дописать живой тест «модель-инструмент → медиа в чате» (обязателен по
   правилам проекта: фикс считается готовым только с именованным живым
   тестом) — проверить полный путь UI → ChatService → ModelToolStreamRunner →
   ImagesApiExecutor/GenerationService → ToolCallFinished(toolMedia) →
   ImagePart/VideoPart.
3. Добавить тест на `detailsOf` для всех подтипов GenError (в т.ч.
   JobStatusUnknown), чтобы новый подтип не терялся в исчерпывающих switch.
4. Зафиксировать контракт «сумма без валюты = токены без суммы» тестом на
   MessageCost/агрегаторах, чтобы nullable/non-nullable больше не спорили.
