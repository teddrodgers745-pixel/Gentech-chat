# R6-audio-robustness-3 — лечение падшей сборки (heal 1)

## Что было не так
Коммит ссылался на компоненты, которых нет в репозитории (не закоммичены):
- `lib/core/generation/media_status_poller.dart` отсутствует целиком (все ошибки про MediaStatusPoller/PollCancelled/PollTransientFailure);
- у `GenErrorMapper` нет публичного `fromStatusCode` (исполнители вызывали приватный `_fromStatusCode`);
- у `ActiveModelController` нет `isCurrentTypeUnsupported`/`currentCatalogType`;
- у `PendingPart` нет параметра `indeterminate`.

## Что поправлено (минимально, причины, не симптомы)
1. **media_status_poller.dart создан** по фактическому контракту из `async_job_executor.dart`: generic-каркас `MediaStatusPoller<T>` (interval/maxAttempts/maxTransientRetries/backoff/isCancelled/onTransientRetry), исключения `PollCancelled` и `PollTransientFailure` с полем `message`; прочие исключения (GenError и др.) транзитом без повторов — это сохраняет публичный контракт `pollMediaJob` («GenError при 401/403, Exception при остальных неудачах»).
2. **gen_error_mapper.dart**: добавлена публичная обёртка `fromStatusCode(int code, String body) => _fromStatusCode(code, body)` — логика не дублируется, расхождений нет.
3. **message_part.dart**: у `PendingPart` добавлено поле `indeterminate` (default false) — все три места конструирования в `chat_screen.dart` теперь компилируются.
4. **chat_screen.dart**: признак «неподдерживаемый тип каталога» выведен из того же резолва каталога, что и маршрут отправки (`ModelTypeOverrideStore.resolveType`): статический хелпер `_unsupportedCatalogType` (всё, что не text/image/video, считается неподдерживаемым). Заменены вызовы `_activeModel.isCurrentTypeUnsupported` (панель → ModelTypes.unknown) и `_activeModel.currentCatalogType` (текст ошибки в `_send`). TEMP-DIAG-UNMODIFIABLE не тронут.

## Замечания / что стоит улучшить рядом
- **Не хватило файлов**: `active_model_controller.dart` и `widgets/message_view.dart` пришли обрезанными — править их вслепую нельзя. Поэтому: (а) геттеры добавлены на уровне chat_screen, а не в контроллере — стоит перенести в контроллер (единый источник истины), когда придёт полный файл; (б) `_PartPending` в message_view пока не использует `indeterminate` (показывает плавный процент как раньше) — при рендере стоит рисовать неопределённый индикатор, когда `part.indeterminate == true`.
- Проверить, что `ModelTypeOverrideStore.resolveType` возвращает сырой каталожный тип ('tts', 'stt', 'music'...) для не-чат моделей, а не маскирует в 'text' — иначе блокировка отправки не сработает и нужно чинить в store.
- В `_watch`/`pollMediaJob` поведение зависит от точной семантики retries исчерпаны → rethrow — покрыто живым тестом после зелёной сборки (пользователь проверяет на телефоне).
