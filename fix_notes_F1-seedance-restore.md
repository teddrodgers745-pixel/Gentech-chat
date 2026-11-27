# fix_notes_F1-seedance-restore

## Что было не так (по дырам Аргона, подтверждено кодом)

1. **0% на старте.** `_generateVideo` (lib/screens/chat_screen.dart, ':1' = якорь начала файла) создавал `PendingPart` с дефолтами `progress = 0`, `indeterminate = false` — карточка гарантированно показывала «0%» до первого `GenProgress`.
2. **0%/синтетика при поллинге.** `AsyncJobExecutor._parsePollBody` считал прогресс определённым всегда: `indeterminate: pct == null`, а при `pct <= 0` (Seedance отдаёт `progress: 0`, пока processing) подставлял синтетический процент с флагом `false` — пользователь видел выдуманные проценты вместо «в процессе…». Плюс ветки не-2xx и битого JSON в `_pollOnce/_parsePollBody` тоже отдавали синтетический процент как «определённый».
3. **Потеря jobId при убийстве приложения.** В `_generateVideo` при первом `GenProgress` с `ev.jobId` обновлялся только UI (`_scheduleUi()`); `store.save()` вызывался лишь в самом конце генерации — снимок с jobId не попадал в SharedPreferences, и после убийства приложения задача исчезала (деньги списаны).
4. **Восстановление молча не находило карточку.** `_applyToJobParts` искал строго `PendingPart.jobId == id`; если карточка не сохранилась/сохранилась с пустым jobId — молчаливый выход, опрос впустую, при ошибке/завершении задача удалялась из ActiveJobsStore. Подписка `restorePendingJobs()` стартовала синхронно в `initState`, потенциально до загрузки чатов.

## Что поправлено

- `lib/screens/chat_screen.dart`: начальный `PendingPart` — `indeterminate: true`; немедленный `unawaited(store.save())` при смене jobId с пустого на реальный (и после добавления карточки в чат); подписка `restorePendingJobs()` перенесена в `addPostFrameCallback` первого кадра; `_applyToJobParts` стал async с fallback `_restorePendingForJob` (поиск user-сообщения по `generationSnapshot.jobId` либо по model+prompt из ActiveJobsStore, восстановление/создание PendingPart «Генерация видео» с indeterminate в ответе ассистента, в т.ч. замена карточки с пустым jobId); `_upsertPendingToolMedia` тоже ставит `indeterminate: progress <= 0` (путь «модель-как-инструмент»).
- `lib/core/generation/async_job_executor.dart`: `_parsePollBody` — `hasServerPct = pct != null && pct > 0`, `indeterminate: !hasServerPct`; первый `GenProgress` в `run()` и `resume()` — `indeterminate: true`; ветки не-2xx и битого JSON — `indeterminate: true`. TEMP-DIAG-UNMODIFIABLE не тронут.
- `lib/models/chat_message.dart` (проверено, БЕЗ изменений): сериализация PendingPart уже полная — `_encodePart` пишет name/localPath/jobId/progress/indeterminate/debug-поля, `_decodePart` case 'pending' восстанавливает их. Дыра №2 из разбора в этой версии кода закрыта; доказано тестом `F1-T-SEEDANCE-PENDING-SERIALIZATION`.
- `test/f1_seedance_restore_test.dart` (новый): живой локальный сервер + полный путь POST /media → poll → GenProgress/GenCompleted через GenerationService.

## Чего не хватило / что улучшить рядом (не чиня сейчас)

- **lib/app_state.dart и lib/core/storage.dart не были присланы**: не видно, есть ли у ChatStore явный флаг/фьючерс загрузки чатов (`loaded`/`ready`). Сейчас restore стартует после первого кадра; если ChatStore грузит чаты асинхронно ПОСЛЕ runApp — надёжнее await явного флага в `_startRestore`. Это единственное место с остаточным риском; fallback `_restorePendingForJob` смягчает, но не устраняет гонку.
- `ActiveJobsStore.AsyncJobRecord` не хранит признак indeterminate — сохранённый «синтетический» процент неотличим от реального; на resume теперь всегда `indeterminate: true` до первого ответа сервера, но честнее было бы персистить флаг.
- `_watch` продолжает копить синтетический `lastPct` в ActiveJobsStore; при желании можно хранить только реально полученные от сервера проценты.
- UI-виджеты карточки (lib/widgets/message_parts.dart / message_view_parts.dart) не были присланы — предполагается, что R6, п.8 уже рендерит indeterminate как спиннер; стоит убедиться живым тестом.

## Как проверить живым тестом (F1-LIVE-SEEDANCE-RESTORE)

1. Выбрать модель bytedance/seedance-2-mini (480p), отправить промпт: с первой секунды карточка — спиннер и «в процессе…», никаких «0%» (фикс 1 + `run()`).
2. Дождаться `poll 1 … http=200 status processing` в логе, УБИТЬ приложение (свайп из недавних).
3. Открыть заново: карточка «Генерация видео (в процессе…)» на месте в чате (сериализация + fallback + отложенный restore), поллинг продолжается.
4. Дождаться завершения: карточка заменяется на готовое видео, запись исчезает из ActiveJobsStore; повторный запуск приложения не дублирует задачу.
5. Кросс-проверка в логе: jobId задачи совпадает с `gen_…` из снимка user-сообщения после убийства (сохранение при первом jobId).
