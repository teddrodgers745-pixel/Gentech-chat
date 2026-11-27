# G1-video-player-heal2 — причина падения шага Run tests (CI 46055528708)

Упали ВСЕ 6 виджет-тестов файла `test/g1_video_player_test.dart` («73 passed, 6 failed»). У падений три независимые причины; первые из них — «асинхронный фантом», бивший по чужим тестам.

## 1. google_fonts: runtime-загрузка JetBrainsMono-SemiBold (корневая причина большинства падений)

- Карточка VideoPlayerCard подписывала имя файла через `fontStyle(settings.codeFont, ..., weight: FontWeight.w600)`. Вариант SemiBold — это отдельный файл шрифта, который google_fonts запрашивает по сети во время выполнения (пакет сам напечатал: `google_fonts was unable to load font JetBrainsMono-SemiBold ... Failed to load font with url: https://fonts.gstatic.com/...`).
- В виджет-тестах `TestWidgetsFlutterBinding` подменяет глобальные HttpOverrides заглушкой HttpClient (любой запрос -> 400, см. тот же механизм в комментарии F1-fix-tests-heal1 у f1_retry_resume_test.dart). google_fonts кидает необработанное `_Exception` — и тест-фреймворк валит ТЕКУЩИЙ тест, даже если запрос инициировал более ранний тест файла (исключения «thrown running a test (but after the test had completed)» атрибутируются выполняющемуся тесту). Поэтому падали и тесты, чьи собственные утверждения верны (SHARE, GALLERY), — исключения «прилетали» к ним от соседей.
- Доказательство, что триггер — именно weight-вариант: все существующие виджет-тесты, создающие `fontStyle(...)` БЕЗ weight (f3-cost-line, f4-markdown через RichMarkdown/MessageView), зелёные; единственный новый вызов fontStyle с weight в тестируемом коде — VideoPlayerCard.
- Исправление (lib/widgets/video_player_card.dart, 2 места — `_footer` и `_placeholderCard`): подпись имени файла рендерится `fontStyle(settings.codeFont, size: ..., color: p.text)` без weight — provably не триггерит runtime-fetch. Незначительная визуальная уступка (имя не SemiBold), никакого поведения не меняется.

## 2. G1-T-VIDEO-FULLSCREEN: find.byType не видел исходную карточку (offstage)

`Expected: exactly 2 ... Actual: Found 1` — найден только полноэкранный плеер. Причина не в плеере: после завершения перехода (pump 1 c > 300 мс transitionDuration MaterialPageRoute) Navigator помечает накрытый маршрут offstage, а `find.byType` по умолчанию `skipOffstage: true` и исходную карточку не считает. Исправление в тесте: `find.byType(VideoPlayerCard, skipOffstage: false)` — теперь считаются обе карточки (исходная + полноэкранная), что и проверяет «тот же единый плеер».

## 3. G1-T-VIDEO-DOWNLOAD: подтверждение — вторая плашка SnackBar, одного pump() мало

`snack()` перед показом вызывает `hideCurrentSnackBar()`: первая плашка («Сохранение видео…») уходит с exit-анимацией (~250 мс), вторая («Видео сохранено: …») показывается только после неё. Один `pump()` (0 мс) не прокручивал анимацию — «Found 0 widgets». Исправление в тесте: цикл `pump(120 мс)` до появления текста (до 1.2 с). Сам прод-код корректен, файл реально записывается в Downloads.

## Чего не хватило

- `lib/theme.dart` (реализация `fontStyle`) не был в присланном коде. Диагноз опирается на лог CI и на то, что все зелёные тесты с fontStyle используют его без weight. Если следующий прогон покажет, что fetch шрифта продолжается — пришлите theme.dart: тогда правильное место лечения — тестовая настройка шрифтов по образцу google_fonts/example/test (бандлинг вариантов в assets либо мок HTTP шрифтов в общем test-хелпере), а не точечные вызовы.

## Что стоит улучшить рядом

- `lib/widgets/file_card.dart` использует тот же паттерн `fontStyle(..., weight: FontWeight.w600)` — первый же виджет-тест, отрисующий FileCard, упадёт тем же образом. Лечить тем же приёмом либо централизованно настроить шрифты для тестов.
- Завести общий тест-хелпер для google_fonts (бандлинг шрифтовых вариантов в assets + `AssetManifest`, либо HttpOverrides-мок, отдающий валидные ttf, как в примере google_fonts) — тогда weight-варианты можно вернуть в дизайн без риска для CI.
- TEMP-DIAG-UNMODIFIABLE не затронут; существующие импорты не удалялись; пресеты/каталог не менялись.
