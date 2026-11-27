# F1-fix-tests-2-heal2 — что было не так и что исправлено

## Причина падения (не симптом)

Красные были ровно два теста в `test/f1_retry_resume_test.dart`
(F1-T-RESUME-SAME-JOB, F1-T-NETWORK-POLL-KEEPS-RECORD). Лог: все
`POST /media` и `GET /media/{id}` возвращали `400` с пустым телом, в
падающих группах присутствует штатное предупреждение flutter_test
"At least one test in this suite creates an HttpClient…", затем
`TimeoutException after 2 minutes`.

Проверено по исходникам (flutter 3.35.7, `flutter_test`):
1. `TestWidgetsFlutterBinding.ensureInitialized()` → `initInstances` →
   `binding.setupHttpOverrides()` → `HttpOverrides.global = _MockHttpOverrides()`.
   Заглушка ставится **глобально** в момент инициализации binding и
   отвечает статусом **400** на всё.
2. В тесте `_RealHttpOverrides` кэшировал клиент полем
   `final HttpClient _client = HttpClient();`. Поле-инициализатор
   выполняется в момент конструирования `_RealHttpOverrides()` — то есть
   в позиции **аргумента** `HttpOverrides.runWithHttpOverrides(...)`,
   ЕЩЁ ДО входа в «настоящую» зону. В этот момент
   `HttpOverrides.current` уже указывал на заглушку binding, поэтому
   «настоящий» клиент оказался `_MockHttpClient`. Дальше зона
   раздавала всем клиентам заглушку → все запросы = 400, живой
   HttpServer теста не достигался, исполнитель вечно получал
   «HTTP 400 → задача ещё в процессе» → цикл опроса 150×5с упирался в
   таймаут теста 2 минуты.

Отдельное подтверждение: внутри зоны с HttpOverrides вызвать
`HttpClient()` в `createHttpClient` нельзя — factory
`HttpClient()` выполняет `HttpOverrides.current.createHttpClient(...)`,
то есть рекурсию. Поэтому «ленивое создание» настоящего клиента внутри
зоны невозможно в принципе; клиент должен быть создан в момент, когда
HttpOverrides ещё нет.

## Что поправлено (только test/f1_retry_resume_test.dart)

1. В `main()` настоящий `HttpClient` создаётся ДО
   `TestWidgetsFlutterBinding.ensureInitialized()` — на этот момент
   `HttpOverrides.global` ещё не установлен заглушкой binding.
   Хелпер `_RealHttpOverrides.createRealHttpClient()` дополнительно
   синхронно снимает/восстанавливает `HttpOverrides.global` (без
   `await` между операциями — изолят однопоточный, гонок нет), так что
   фикстура не зависит от порядка инициализации.
2. `_RealHttpOverrides.createHttpClient` возвращает этот единственный
   настоящий клиент; при отсутствии клиента — громкий `StateError`
   вместо тихой заглушки 400, маскирующей дефект фикстуры.
3. Обновлены комментарии фикстуры (heal2). Исполнитель и все
   lib-файлы НЕ тронуты: это дефект тестовой фикстуры, не кода
   приложения (TEMP-DIAG-UNMODIFIABLE не затронут).

## Что стоит улучшить рядом

- `AsyncJobExecutor._pollOnce` трактует HTTP 400 при опросе как
  «задача ещё в процессе» (без анализа тела). Возможно, стоит
  различать «400 провайдера» и «заглушка тестовой среды» не нужно, но
  голоса о которых говорит и, по-видимому, 400-ответы провайдера с
  телом «некорректный запрос задачи» стоит считать фатальными — иначе
  живой тест мог бы маскировать реальный 400. (Отдельная задача, не
  в рамках этого фикса.)
- Для тестов с реальным HTTP, где нужен TestWidgetsFlutterBinding
  (path_provider/shared_preferences), этот паттерн «настоящий
  HttpClient до ensureInitialized» стоит вынести в общий тестовый
  хелпер, чтобы не дублировать в будущих фикстурах.
