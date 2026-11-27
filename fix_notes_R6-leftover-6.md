# fix_notes_R6-leftover-6.md

## Что сделано
Сверил все 6 незакоммиченных файлов первой попытки R6-2 с планом R6-audio-robustness-3 и с закоммиченным кодом R6-3/heal1/heal2. Все 6 реализуют пункты плана (не устарели, не дублируют закоммиченный код), поэтому возвращены и закоммичены БЕЗ изменений:

1. `provider_catalog_service.dart` — п.3: дисковый кэш по identity подключения (FNV-1a отпечаток адрес+хеш ключа, schemaVersion=2, уникальный тег файла по исходному id). Не конфликтует с committed chat_screen (использует `providerCatalog.lookup`), тест `provider_catalog_parser_test.dart` компилируется против этой версии.
2. `active_jobs_store.dart` — п.4: сериализация read-modify-write очередью `_synchronized` (гонки ActiveJobsStore).
3. `active_model_controller.dart` — п.1 (служебные/аудио типы не маскируются под текст: `isCurrentTypeUnsupported`, `_lastCatalogType`), п.2 (`_resolveGuarded` — не терять события во время резолва; публикация merged-параметров только по ПОЛНОМУ id), задача 4 (`ChatService.reasoningMandatoryProbe`). Совместим с committed `chat_service.dart` (поле `reasoningMandatoryProbe` есть).
4. `images_api_executor.dart` — п.5 (глобальный blacklist параметров убран; `translateWithCatalog`), п.8 (единый опрос через `MediaStatusPoller`, HTTP-коды через `GenErrorMapper.fromStatusCode`), выбор провайдера через `settings.providerSort` (без захардкоженного провайдера). Все символы (`MediaStatusPoller`, `PollCancelled`, `PollTransientFailure`, `JobStatusUnknown`) есть в закоммиченных файлах.
5. `cost_estimate.dart` — консервативный оценщик по сырым ценам каталога (`modelPricingRaw`/`providerPricingRaw`), unknown-условия не угадываются. Совместим с committed `chat_screen.dart` (`_estimateWithCatalog`).
6. `chat_message.dart` — п.7: round-trip сериализации частей (`partSchemaVersion = 2`, типизированное восстановление ErrorPart по коду, unknown-части не превращаются в пустой текст).

Файлы, НЕ вошедшие в коммит: нет — вошли все 6.

## Что было не так / что важно знать

1. **Прямая зависимость от R6-fix-analyze-4.** `chat_message.dart` использует `UnknownPart` и `PendingPart.indeterminate`, которых НЕТ в текущей (heal2) версии `message_part.dart`. При этом закоммиченный `chat_screen.dart` ТОЖЕ передаёт `indeterminate:` в `PendingPart` (`_onRestoredEvent`, `_updateVideoPending`) — то есть несоответствие message_part ↔ chat_screen уже существует в дереве независимо от этого коммита. R6-fix-analyze-4 должен: (а) вернуть поле `indeterminate` в `PendingPart`; (б) добавить класс `UnknownPart` в `message_part.dart` (sealed MessagePart); (в) добавить `case UnknownPart():` в switch `_partsWidgets` в `message_view.dart` (sealed-тип — switch станет неисчерпывающим без этого). Пока это не сделано, `flutter analyze`/сборка будет красной — независимо от данного коммита.
2. **Асимметрия round-trip в chat_message.dart (не чинил, чтобы не конфликтовать со следующим таском):** `_encodePart` кодирует TextPart с `cost`/`sources`, но `_decodePart` не имеет `case 'text'` — после перезапуска такой TextPart восстановится как UnknownPart('text'), и стоимость/источники потеряются. Рекомендация: добавить в `_decodePart` case `'text'`, восстанавливающий `TextPart(text, cost: MessageCost.fromJson(...), sources: [...])`.
3. **Тест r4_honest_cost_estimator_test.dart противоречит heal2-версии MessageCost:** `T2-UNIT-COST-TOKENS-ONLY` ожидает `cost.cost isNull`, а `T2-UNIT-COST-UNSCOPED-ALIAS` — что `currency != 'USD'` при отсутствии валюты. Heal2-версия message_part.dart — non-nullable `cost` (default 0) и дефолт `'USD'` в `fromUsage` — оба теста упадут. Следующий таск должен согласовать либо тесты, либо MessageCost (это и есть предмет R6-fix-analyze-4).

## Что стоит улучшить рядом (не чиня сейчас)
- Определить один источник правды для `MessageCost` (nullable-контракт суммы vs non-nullable + пустая валюта) и зафиксировать его в тестах.
- `_upsertPendingToolMedia` в chat_screen не передаёт `indeterminate` — после восстановления поля проверить консистентность.
- `cost_estimate.dart`: параметр `pricing` объявлен, но не используется — убрать в отдельной очистке после проверки всех потребителей.

## Как проверить живым тестом (пользователь)
1. **Перезапуск/возобновление (п.7 + ActiveJobsStore):** отправить видео-запрос, убить приложение во время генерации, открыть заново — карточка «Генерация видео» возобновляет ТУ ЖЕ задачу (тот же jobId в отладке), прогресс продолжается, новой оплаты не происходит.
2. **Кэш по identity (п.3):** в пресете сменить API-ключ на другой валидный → каталог пересинхронизируется (лог `[caps] ... моделей N`); записи старого подключения не подмешиваются к новому. После перезапуска с другим ключом кэш старого ключа не используется.
3. **Неизвестный/служебный тип (п.1):** выбрать tts/stt-модель → панель ввода показывает «неподдерживаемый тип», отправка блокируется понятной ошибкой, а не уходит в текстовый чат.
4. **Round-trip ошибок (п.7):** вызвать ошибку генерации (например, неверный ключ), закрыть и открыть приложение — карточка ошибки восстанавливается типизированной (тот же текст/код), а не заглушкой.
5. **Оценка стоимости (cost_estimate):** у модели с ценой за изображение в каталоге — перед генерацией видна корректная оценка «≈ X ₽ за изображение»; у модели без распознаваемых цен оценка не показывается (не 0 и не 1,5 ₽).
