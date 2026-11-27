# fix_notes_F1-fix-tests.md — F1-fix-tests-heal1

## Что было не так (причины, а не симптомы)

Упали два теста, причины две, обе — в коде, а не в инфраструктуре:

### 1. `ActiveJobsStore.save` — «Cannot add to an unmodifiable list» (F1-T-RESUME-SAME-JOB)

- `ActiveJobsStore._readAll()` возвращал **const-литерал** `const <AsyncJobRecord>[]` (все три `return`: пустое хранилище, не-List, catch).
- `save()` выполняет read-modify-write над прочитанным списком: `jobs.add(record)` / `jobs[i] = record`; `updateProgress` — `jobs[i] = ...`; `remove` — `removeWhere`.
- На пустом хранилище (первый же `save` записи задачи) `jobs.add` падал с `Unsupported operation: Cannot add to an unmodifiable list` — трасса в логе: `active_jobs_store.dart ActiveJobsStore.save.<fn>`.

**Фикс:** `_readAll` во всех трёх ветках возвращает свежий выращиваемый `<AsyncJobRecord>[]` (комментарий в коде). Все read-modify-write операции (`save`/`updateProgress`/`remove`) теперь безопасны; контракт и сериализация очереди не менялись.

### 2. `TestWidgetsFlutterBinding` блокировал живые HTTP-запросы (F1-T-NETWORK-POLL-KEEPS-RECORD, и после п.1 задушил бы и первый тест)

- Файл вызывает `TestWidgetsFlutterBinding.ensureInitialized()` (нужен для мока канала `path_provider` — JSONL-лог задачи — и `SharedPreferences`). Побочный эффект binding’а: **глобальный `HttpOverrides` подменяется заглушкой HttpClient**, у которой любой запрос → `HTTP 400` и в сеть не ходит (предупреждение прямо в логе: «all HTTP requests will return status code 400»).
- Видно в логе: `AsyncJobExecutor CREATE http://127.0.0.1:36687/media -> 400:` — POST не дошёл до тестового `HttpServer`, `created` не резолвился, тест завис на `await created.future` до `TimeoutException after 30s`.
- Тест 1 при этом падал раньше (на краше хранилища), но после фикса п.1 «завис бы» так же: GET-опрос `/media/job-f1-77` получал бы 400 и крутился бы 150 попыток × 5 с.

**Фикс:** в `test/f1_retry_resume_test.dart` сетевые тесты (первые два) выполняются в зоне с **настоящими** `HttpOverrides` (`HttpOverrides.runWithHttpOverrides` + приватный `_RealHttpOverrides`, отдающий реальный `HttpClient`). Зона приоритетнее глобального override binding’а (семантика dart:io `runZoned`/`runWithHttpOverrides`). Binding остался только там, где он нужен: мок канала `path_provider`, `SharedPreferences.setMockInitialValues`. Содержательная логика тестов (шаги, серверы, assert’ы) не менялась. Тестам с живой сетью добавлен явный `timeout: 2 минуты` — две фазы транзиентных повторов исполнителя (пауза 2/4/6 с) дают ~24 с против дефолтных 30 с на тест; явный запас убирает риск мигания на медленной CI-машине.

## Что проверено по трассировке UI → сервис → исполнитель → API

- Путь resume: `GenerationService.resumeJob` → `AsyncJobExecutor.resume` → `_watch` → `MediaStatusPoller` → GET `/media/{id}` → `GenProgress/GenCompleted` — запись из `ActiveJobsStore` читается, мутируется и удаляется — теперь без крашей.
- Путь транзиентной ошибки опроса: обрыв сети → `PollTransientFailure` → `JobStatusUnknown(jobId)` → запись **сохраняется** в `ActiveJobsStore` (не удаляется), «Повторить» → `resumeJob` того же jobId без POST /media (assert `createPosts == 0` остаётся честным).
- Прочие 30 тестов сьюта по логу CI не зависели ни от одной из причин (свои `HttpServer` в файлах **без** `ensureInitialized` — там глобальный override не ставился); их не трогал.

## Замечания / что улучшить рядом

1. **Транзиентные паузы `AsyncJobExecutor`** (`_transientBackoffBase = 2 с`, ретраи 2/4/6 с) зашиты константами — интеграционные тесты с живым обрывом сети неизбежно тратят ~12 с на фазу. Стоит вынести в параметры конструктора/инжекцию, чтобы тесты подставляли миллисекунды.
2. **Юнит-тест на мутабельность результата `_readAll`/`loadAll`** (save на пустом хранилище, updateProgress, remove round-trip) не помешает — сейчас этот контракт покрыт только косвенно через `f1_retry_resume_test`.
3. **Заглушка HTTP у binding’а** — общий подводный камень flutter_test: любой файл, где `ensureInitialized()` + живой `HttpServer`, будет ловить «400 на всё». Стоит закрепить паттерн `runWithHttpOverrides(_RealHttpOverrides())` в проектном стиле тестов с сетевыми фикстурами.
4. **Чего не хватило в присланном коде:** `ArtifactMaterializer` (путь материализации видео в тесте 1) и `generation_executor.dart` — судя по логу, они работают штатно, проверять их правки не требовалось.
5. Участок TEMP-DIAG-UNMODIFIABLE в `async_job_executor.dart` не трогал; диагностика вокруг него (JSONL-лог в temp-каталоге через мок `path_provider`) проверена — работает и в тестах.
