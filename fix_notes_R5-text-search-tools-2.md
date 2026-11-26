# fix_notes_R5-text-search-tools-2 (heal1)

## Диагноз (причина, не симптом)
Сборка упала на шаге 9 `flutter analyze` — 12 issues. Коммит R5 добавил в
`chat_service.dart` / `chat_screen.dart` / `images_api_executor.dart` использование
четырёх сущностей, которых в репозитории НЕТ (по каждой анализатор выдал ошибку):

1. `settings.providerSort` (геттер `AppSettings`) — images_api_executor.dart:87,
   chat_service.dart:663 (`undefined_getter`);
2. `ToolMedia` — импортируется из `core/models/message_part.dart`, но там НЕ
   экспортируется (`undefined_shown_name` + `non_type_as_type_argument` в
   chat_service.dart:46/93/95/413 и chat_screen.dart:1522);
3. `ModelToolRunner.runStream` (`undefined_method`, chat_service.dart:384);
4. события `ModelToolProgress` / `ModelToolDone` (`type_test_with_undefined_name`,
   chat_service.dart:385/394).

Причина — неполный коммит R5: правки `app_state.dart`, `core/models/message_part.dart`
и `services/model_tool.dart` (где всё это должно было появиться) не попали в репозиторий.
Репозиторий приватный (GitHub/raw — 404), перечисленные файлы в присланном коде
отсутствуют, поэтому недостающие определения добавлены НОВЫМИ файлами.

## Что поправлено (минимально)
- **НОВЫЙ** `lib/core/models/tool_media.dart` — тип `ToolMedia(url, kind)`.
- **НОВЫЙ** `lib/core/settings/provider_sort_ext.dart` — расширение
  `AppSettingsProviderSort` c `providerSort` (TEMP-SHIM: документированный дефолт
  `'price'` — «самый дешёвый»; конкретный провайдер по-прежнему НЕ закрепляется).
- **НОВЫЙ** `lib/services/model_tool_stream.dart` — `ModelToolProgress`,
  `ModelToolDone` и `ModelToolStreamRunner.run`: тип модели решает каталог
  (`ModelTypeOverrideStore.resolveType`), text → chat/completions, image →
  `ImagesApiExecutor`, video → `GenerationService` (прогресс jobId/percent,
  медиа — типизированным `ToolMedia`).
- `chat_service.dart`: вызов `ModelToolStreamRunner.run(...)` вместо
  `ModelToolRunner.runStream(...)`; `collected = ToolOutcome(ev.ok, ev.text, media: …)`;
  импорты новых файлов. Существующие импорты сохранены (правило проекта): сломанный
  `show ToolMedia`-импорт и `model_tool.dart` оставлены с `// ignore: unused_import, undefined_shown_name`.
- `images_api_executor.dart`, `chat_screen.dart`: добавлены ТОЛЬКО импорты
  (расширения / `tool_media.dart`). Логика не тронута.
- Трассировка пути инструмента: UI (Tool) → ChatService.sendMessage →
  ModelToolStreamRunner (каталог-тип) → ImagesApiExecutor/GenerationService → API →
  GenProgress/GenCompleted → StreamChunk.toolJobId/toolProgress/toolMedia →
  _upsertPendingToolMedia/_attachToolMedia → ImagePart/VideoPart в чате (все
  потребители события обновлены).

## Чего не хватило (проверить при ревью!)
- `lib/app_state.dart`, `lib/core/models/message_part.dart`,
  `lib/services/model_tool.dart`, тесты R5 — НЕ присланы. Правильные места:
  `ToolMedia` → message_part.dart, `runStream`+события → model_tool.dart
  (у `ModelToolRunner` уже есть логика вызова модели — моя реализация в
  `ModelToolStreamRunner` может её дублировать), `providerSort` → поле
  `AppSettings` (persist) — тогда расширение удалить.
- Риски компиляции (докажет/опровергнет CI): `GenerationRequest.estimatedUsd`
  передан `null` (если поле non-null — упадёт, поправлю в heal2); `routeHint`
  передан литералами `'image'/'video'` (константы `ModelTypes` мог быть в другом
  файле, чем `model_type_override_store.dart`).
- Значение `'price'` (sort) сверить с документацией Polza — взято из комментария
  самого кода R5 («по цене — самый дешёвый»).
- Тесты шага 10: если они ссылаются на `ModelToolRunner.runStream` или
  `settings.providerSort` — пришлите их лог, дотяну до зелёного.
- Участок TEMP-DIAG-UNMODIFIABLE в присланном коде не встречался — не трогал.

## Стоит улучшить рядом
- Медиа-параметры инструмента (aspect ratio/duration по `tool.parametersSchema`)
  сейчас не разбираются из аргументов вызова — только промпт; при необходимости
  добавить разбор.
- Аудио-модель (4-й тип) как инструмент сейчас уходит в текстовый путь —
  при появлении в каталоге типа 'audio' добавить ветку озвучки.
- После переноса `ToolMedia` в message_part.dart убрать `// ignore:`-хвосты
  и вернуть show-импорт к нормальному виду.
