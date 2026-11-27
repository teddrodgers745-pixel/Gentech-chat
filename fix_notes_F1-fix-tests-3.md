# fix_notes_F1-fix-tests-3

## Точная ошибка из лога Analyze Code (run 45989128275, коммит 6026d1d)

```
error • The getter 'global' isn't defined for the type 'HttpOverrides'
      • test/f1_retry_resume_test.dart:88:48 • undefined_getter
1 issue found.
```

Строка 88, колонка 48 — это `final HttpOverrides? saved = HttpOverrides.global;`
в `_RealHttpOverrides.createRealHttpClient()` (позиция `.global` = колонка 48).
Других ошибок analyze не сообщил — именно поэтому присваивания
`HttpOverrides.global = null;` и `HttpOverrides.global = saved;` (строки 89/93)
прошли: **сеттер существует, геттера нет**.

## Причина (проверено по API dart:io стабильного SDK, Dart 3.9.4 = Flutter 3.35.7)

В Dart 3.9 статический `HttpOverrides.global` стал **write-only**:

- `global` — только сеттер (`static set global(HttpOverrides? overrides)`),
  документировано «no getter» (api.dart.dev …/HttpOverrides/global.html,
  реализация `sdk/lib/_http/http.dart`);
- чтение доступно только через zone-aware геттер `HttpOverrides.current`
  (`Zone.current[token] ?? _global`), у которого, наоборот, нет сеттера.

Heal2 опирался на старый API (читать global → снять → создать клиент → вернуть).
На новом SDK это закономерно undefined_getter, и это объясняет, почему
анализатор не ругался на сеттеры.

## Что исправлено (один участок, test/f1_retry_resume_test.dart)

1. Удалён блок чтения/восстановления `HttpOverrides.global` из
   `createRealHttpClient()` — геттера в Dart 3.9 больше нет, восстанавливать
   нечего и незачем.
2. Клиент теперь создаётся так, что способ **не зависит ни от `global`, ни от
   порядка инициализации binding**: `HttpOverrides.runWithHttpOverrides(
   () => HttpClient(), _RealHttpClientFactory())`, где новый крошечный
   класс `_RealHttpClientFactory extends HttpOverrides` наследует БАЗОВУЮ
   `createHttpClient`. Документированное поведение базовой реализации:
   «The implementation in this base class defaults to the actual HttpClient
   implementation» — т.е. в зоне её `HttpClient()` даёт НАСТОЯЩИЙ клиент,
   без рекурсии и без заглушки binding. Кэширование в `_realClient` и
   громкий `StateError` в `createHttpClient` при отсутствии клиента
   сохранены (защита от тихой заглушки 400).
3. Обновлены только комментарии (шапка-хроника + док метода и `main()`).
   Код тестов, фикстур и счётчики не тронуты.

## Что НЕ тронуто (контракты сохранены)

- F1: повтор живой задачи — ноль POST /media (F1-T-RESUME-SAME-JOB,
  resumeJob без создания; ожидания createPosts == 0 / 1 не менялись).
- heal1: `_readAll` возвращает выращиваемый список (ActiveJobsStore не трогали).
- heal1 из F1-fix-tests-2: `Completer` без `.never()` — обработчик «сеть рвётся»
  не изменён.
- heal2: настоящий HttpClient создаётся в `main()` ДО
  `TestWidgetsFlutterBinding.ensureInitialized()` — вызов не перенесён;
  фиксирование клиента в поле убрано ещё heal2 и не возвращалось.
- TEMP-DIAG-UNMODIFIABLE, R1–R6, `GenErrorMapper.fromCode('status_unknown')`
  — не тронуты (файл и правки целиком внутри теста).

## Что стоит улучшить рядом (сейчас НЕ чинится)

- Прогнать `flutter analyze` локально/в CI перед Run tests, чтобы ловить
  API-дрифт SDK (как этот) до траты двух heal-попыток на Run tests.
- Зафиксировать минимальную версию SDK в pubspec с комментарием о том, что
  `HttpOverrides.global` с Dart 3.9 — write-only: это документирует причину
  фикса для будущих читателей.
- `_RealHttpClientFactory` можно вынести в общий test-хелпер, если ещё где-то
  понадобится настоящий клиент под заглушкой binding.

## Как проверить живым тестом (пользователь, телефон)

1. CI: зелёные Analyze Code + Run tests + build apk на новом коммите.
2. F1-LIVE-RETRY-RESUME: запустить видео-генерацию у Polza, во время
   опроса включить авиарежим на 15–30 с, выключить, нажать «Повторить»:
   карточка «Статус задачи неизвестен» → повтор возобновляет ТО ЖЕ видео
   (в истории не появляется второе списание/новая задача), видео доезжает.
3. Перезапуск приложения, пока карточка «неизвестен» в авиарежиме: после
   восстановления сети restorePendingJobs доводит ту же задачу до VideoPart
   — без повторного POST /media.
4. F1-LIVE-IMAGE-RELOAD: картинка с недоступной временно ссылкой показывает
   «Не удалось загрузить изображение» + «Повторить загрузку»; после
   восстановления сети загрузка того же URL завершается без новой генерации.
