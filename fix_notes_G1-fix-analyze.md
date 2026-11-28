НЕДОСТАЮЩИЕ ФАЙЛЫ: нет

## G1-fix-analyze — фикс падения шага Analyze Code (run 46134313665, коммит 316ec9d)

### Причина бага
Правка heal2 (316ec9d) в `test/g1_video_player_test.dart` передавала в `vpi.VideoEvent(...)`
именованный параметр `position:` (строка 183, колонка 7 — вызов в `_FakeVideoPlatform.complete`).
У `VideoEvent` в `video_player_platform_interface` (резолвится 6.7.0) такого параметра НЕТ:
конструктор принимает только `eventType, duration, size, rotationCorrection, buffered, isPlaying`
(проверено по pub.dev API-докам 6.7.x). Файл не компилировался: `undefined_named_parameter` (error),
поэтому шаг `Run tests` был пропущен и исходная проблема google_fonts так и не была проверена.
Ошибка внесена правкой теста, боевой код (`lib/widgets/video_player_card.dart`) не виноват.

Важно: удаление `position:` НЕ ломает проверяемое поведение REPLAY. Установлено по исходникам
`packages/video_player/lib/video_player.dart` (eventListener): при получении события
`VideoEventType.completed` контроллер сам обновляет `VideoPlayerValue` — `position = value.duration`
и `isCompleted = true` (цитата в flutter#136309: `value = value.copyWith(isCompleted: true)`).
Карточка (`_centerButton`) показывает replay по инварианту `v.isCompleted || v.position >= v.duration`,
то есть достаточно одного события `completed` с duration.

### Что изменено по слоям
1. **UI/тест-слой** — `test/g1_video_player_test.dart` (единственный изменённый файл):
   - строка 183: удалён `position: const Duration(seconds: 30)` из события `completed`
     в `_FakeVideoPlatform.complete` (G1-T-POSITION-GONE);
   - строки 165–166: добавлены `const` к `Duration(seconds: 30)` и `Size(640, 360)`
     внутри `videoEventsFor` — закрыты оба info `prefer_const_constructors`
     (сам VideoEvent остаётся non-const-конструктором, const допустим у аргументов);
   - комментарии исправлены/дополнены (новый блок «G1-fix-analyze» в шапке и переписанный
     doc-комментарий `complete()`), чтобы не оставить ложное описание API.
   Логика тестов не менялась: все 6 сценариев (PLAY-PAUSE, REPLAY, FULLSCREEN, DOWNLOAD,
   SHARE, GALLERY) — как были.
2. **State/Service-слой** — `lib/theme.dart` (изменение heal1 d02880d) ПРОВЕРЕН и ОСТАВЛЕН:
   ветка `if (!GoogleFonts.config.allowRuntimeFetching) return base;` включается ТОЛЬКО в
   тестовых процессах (флаг ставится в `main()` теста); в проде флаг `true` и
   `GoogleFonts.getFont` работает штатно. JetBrainsMono не отключён (`codeStyle` прежний),
   google_fonts из боевого кода не убран. Изменение безвредно — откат не требуется.
3. **Storage/Serialization** — изменения не требуются; сериализация частей и VideoPart
   в задаче не затронуты.

### Почему уплыл REPLAY раньше и почему теперь зелёный
В run 46133475467 REPLAY падал («Found 0 widgets with icon U+F00FC»): исправление heal2
через `position:` в событии не могло помочь, т.к. такой параметр в API отсутствует
(сборка с ним не компилировалась). Фактический механизм: контроллер video_player по
событию completed сам ставит `isCompleted=true` (+ position=duration) — асинхронная
доставка события покрывается уже имеющимся циклом прокачки (12×100 мс).

### Как проверить живым тестом
- `flutter analyze --no-fatal-infos` → 0 issues (G1-T-ANALYZE-GREEN);
- строка вызова `completed`-события не содержит `position:` (G1-T-POSITION-GONE);
- `flutter test --reporter expanded test/g1_video_player_test.dart` → все 6 тестов зелёные,
  ни одного `Failed to load font with url: https://fonts.gstatic.com/...` (G1-T-RUN-TESTS-GREEN;
  флаг `GoogleFonts.config.allowRuntimeFetching = false` уже стоит в `main()` до первого pump).
