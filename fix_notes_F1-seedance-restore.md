# F1-seedance-restore-heal1 — замечания к исправлению

## Что было не так

Сборка пала на шаге `flutter analyze --no-fatal-infos` (CI-ран 46048956123),
две находки:

1. **`warning • Dead code • lib/screens/chat_screen.dart:428:55`** — причина,
   а не симптом: в `_restorePendingForJob` поиск ответа ассистента был
   написан как цикл
   `for (int j = i + 1; j < chat.messages.length; j++) { if (role != 'assistant') break; reply = ...; break; }`.
   Тело цикла завершается `break` на КАЖДОЙ итерации (обе ветки: «не
   ассистент → break» и «присвоили reply → break»), поэтому инкремент
   `j++` недостижим. Анализатор указывает ровно на `j++`: строка 428,
   колонка 55 — точная позиция второго `j` в заголовке цикла при
   8-пробельном отступе. Это мёртвый код, внесённый коммитом
   F1-seedance-restore, а не ложное срабатывание.

2. **`info • prefer_const_constructors • test/f1_seedance_restore_test.dart:153:11`** —
   `PendingPart(...)` внутри списка частей `ChatMessage` может быть
   `const PendingPart(...)` (конструктор PendingPart — const, все
   аргументы константы). Конструктор `ChatMessage` const-оспособен НЕ
   является (мутабельные поля), поэтому const ставится только на элемент
   списка. CI с `--no-fatal-infos` валил любую info-находку.

## Что поправлено

- `lib/screens/chat_screen.dart`, `_restorePendingForJob`: цикл заменён
  на прямую проверку следующего сообщения
  (`i + 1 < chat.messages.length && role == 'assistant'` → `reply = ...`).
  Поведение идентично прежнему: цикл фактически мог рассмотреть только
  `messages[i + 1]` и никогда не доходил до `j++`. Мёртвый инкремент
  исчез, поведение restore не изменено.
- `test/f1_seedance_restore_test.dart`: `PendingPart(` → `const PendingPart(`
  с комментарием о причине; сам тест и проверяемые утверждения не менялись.
- Участок TEMP-DIAG-UNMODIFIABLE (async_job_executor.dart) не тронут;
  другие файлы не изменялись; импорты не удалялись.

## Что стоит улучшить рядом

- В `_restorePendingForJob` fallback «по модели и промпту» при пустом
  jobId снимка сравнивает `snap.modelId.trim() == model` — стоит покрыть
  именованным тестом случай «карточка сохранена без jobId, но снимок
  есть» (сейчас проверен только round-trip сериализации).
- `MessagesCost`-логика `_sumRoundCosts` и путь `_handleRestoredEvent`
  для `GenerationFailure` с пустым jobId — кандидаты на юнит-тесты,
  чтобы падение analyze не было единственной защитой этих веток.
