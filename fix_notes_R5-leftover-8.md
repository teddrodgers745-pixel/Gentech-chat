# fix_notes — R5-leftover-8

## Что сделано
Сверил все 8 незакоммиченных файлов первой попытки R5 с планом R5 (6 пунктов)
и с закоммиченным кодом R5-2/heal1 (chat_screen, chat_service,
images_api_executor, tool_media, provider_sort_ext, model_tool_stream).
Коммитятся 7 файлов + 3 точечные правки уже закоммиченных файлов.

## Возвращены (план R5 подтверждён в коде)
1. lib/app_state.dart — пункт 6 (provider sort): реальное поле
   AppSettings.providerSort ('price'|'latency'|'throughput'), валидация,
   персист в SharedPreferences, сеттер setProviderSort.
2. lib/core/generation/async_job_executor.dart — provider: {sort} в тело
   Polza /media (пункт 6), GenFailure с jobId, JobStatusUnknown/JobTimeout.
   Участок TEMP-DIAG-UNMODIFIABLE сохранён дословно, не тронут.
3. lib/core/generation/chat_completions_executor.dart — типизированный
   медиа-результат инструмента в ToolCallFinished, дедуп источников
   (SourcesReceived), статусная маршрутизация tool-чанков (пункт 3).
4. lib/core/generation/generation_event.dart — ToolCallStarted/
   ToolCallFinished с List<ToolMedia>? media (пункт 3).
5. lib/core/models/gen_error.dart — InsufficientFunds: «оплата или лимит
   (402)», без утверждения о балансе (пункт 5); полный набор sealed-подтипов.
6. lib/core/models/message_part.dart — ToolMedia (пункт 3), TextPart.sources,
   PendingPart с debug-полями, ErrorPart.
7. lib/features/chat/widgets/error_bubble.dart — исчерпывающие switch по
   всем 11 подтипам GenError, JobStatusUnknown показывает полное
   сообщение («повтор без новой оплаты»), 402 — «Ошибка оплаты или лимита»
   (пункт 5, соответствует тесту r4_402_mapper_widget_test).

## НЕ возвращён (останется незакоммиченным — пользователь откатит сам)
- lib/services/model_tool.dart. Причины:
  1) ДУБЛИРУЕТ закоммиченный services/model_tool_stream.dart (heal1):
     тот же функционал runStream уже живёт в ModelToolStreamRunner, и
     закоммиченный chat_service.dart вызывает именно его.
  2) КОНФЛИКТУЕТ: model_tool.dart объявляет ModelToolProgress/ModelToolDone,
     и model_tool_stream.dart объявляет те же имена; chat_service.dart
     импортирует ОБЕ библиотеки и ссылается на эти имена — коммит дал бы
     ошибку «имя неоднозначно» и красную сборку.
  Пункт 3 плана R5 (модель-как-инструмент с типизированным медиа) уже
  полностью покрыт закоммиченным model_tool_stream.dart. Консолидация
  (перенос в ModelToolRunner + удаление stream-версии) — отдельная задача.

## Точечные правки уже закоммиченных файлов (чтобы сборка осталась зелёной)
- lib/core/models/tool_media.dart: класс ToolMedia заменён на реэкспорт
  `export 'message_part.dart' show ToolMedia;`. Без этого ToolMedia был бы
  объявлен в двух библиотеках, а chat_screen/chat_service импортируют обе —
  неоднозначность имени = ошибка компиляции. С реэкспортом оба импорта дают
  ровно один и тот же тип; все вызовы ToolMedia(url:, kind:) совместимы.
  Это ровно шаг, который shim сам документировал («после появления ToolMedia
  в message_part.dart…»). Файл не удалял — правила запрещают удалять
  импорты/файлы без согласования.
- lib/services/chat_service.dart и lib/core/generation/images_api_executor.dart:
  добавлен `// ignore: unused_import` над импортом provider_sort_ext.dart.
  Причина: теперь AppSettings имеет реальное поле providerSort, которое
  затеняет extension-геттер — extension никогда не применяется, и анализатор
  пометил бы оба импорта как unused_import (warning = красный flutter
  analyze). Импорты сохранены (по правилам проекта их не удаляем).
  Также убран устаревший комментарий `// ignore: undefined_shown_name,
  unused_import` над импортом message_part.dart в chat_service: ToolMedia
  теперь реально определён и используется (сам импорт сохранён).
  Никакой логики в этих двух файлах не менялось.

## Что было не так в предыдущих попытках
- Первая попытка R5 применила 10 файлов, но упала на finish_reason=length и
  не закоммитила ничего; повтор R5-2 закоммитил только 3 файла, а heal1 —
  ещё 3 shim'а. R5-2 писал свои правки поверх изменённых версий этих 8
  файлов, поэтому часть их содержимого уже «предполагалась» закоммиченным
  кодом (например, chat_service ссылался на ToolMedia и settings.providerSort).

## Что стоит улучшить рядом (не чиня сейчас)
1. Удалить tech-debt: provider_sort_ext.dart (extension больше не нужен —
   поле в AppSettings есть) вместе с двумя его импортами; затем
   tool_media.dart (реэкспорт) с переключением импортов в chat_screen/
   chat_service/model_tool_stream на message_part.dart.
2. Консолидировать model_tool_stream.dart в services/model_tool.dart
   (версия из рабочего дерева функционально шире: поддерживает responses
   API, медиа-параметры из аргументов, валидацию заголовков) и переключить
   chat_service на ModelToolRunner.runStream с удалением дублей имён.
3. Проверить, что gen_error_mapper.dart (не прислан) не делает
   исчерпывающий switch по подтипам GenError с иным набором, чем эти 11 —
   иначе правка gen_error.dart потребует синхронной правки mapper.
4. model_tool_stream передаёт только prompt без медиа-параметров
   (aspect_ratio/duration) из аргументов вызова инструмента — можно
   прокинуть, как это сделано в невозвращённом model_tool.dart
   (_mediaParamsFromArgs).

## Как проверить живым тестом (пользователь, после зелёной сборки)
1. T-R5-SORT-PRICE: в настройках не трогаем sort (по умолчанию price),
   генерируем видео Polza-моделью; в логе тела запроса /media видно
   "provider": {"sort": "price"}.
2. T-R5-SORT-SWITCH: в настройках переключить сортировку на latency,
   сгенерировать видео/картинку — в теле "sort": "latency"; перезапуск
   приложения — настройка сохранилась.
3. T-R5-TOOL-MEDIA: в чате текстовой моделью включить инструмент-модель,
   настроенный на медиа-модель каталога; просим «нарисуй/сними …» —
   в ответе появляется ImagePart/VideoPart (медиа в чате, не текст),
   карточка инструмента done.
4. T-R5-TOOL-VIDEO-RESUME: во время генерации видео инструментом убить
   приложение, открыть заново — карточка ожидания с jobId продолжает
   прогресс и завершается видео (без новой задачи).
5. T-R5-402: искусственно вызвать 402 (лимит ключа) — карточка «Ошибка
   оплаты или лимита», текст причины провайдера, без «Недостаточно средств».
6. T-R5-INCOMPLETE: оборвать сеть во время стриминга — частичный текст
   показывается, неполные tool calls не исполняются, в карточке/снеке
   причина (finish_reason / «поток оборван»).
Приёмка: зелёный CI (flutter analyze + flutter test + build apk), затем
живые прогоны R1–R5 на телефоне.
