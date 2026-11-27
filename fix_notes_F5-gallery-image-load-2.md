# F5-gallery-image-load-2 — разбор упавшего шага Analyze Code

CI: запуск 46016186506, ветка agent, коммит 7aee663. Шаг 9 «Analyze Code» (flutter analyze) — failure, «Run tests» пропущен.

## Точная ошибка

Лог шага по GitHub API недоступен для анонимной выгрузки (403), поэтому ошибка установлена статически по фактическим данным коммита (репозиторий публичный) — это надёжно, потому что analysis_options.yaml проекта включает РОВНО два активных lint-правила и analyze падает на любом findings (в т.ч. info — уже установлено в heal1):

- `test/f5_image_reload_test.dart` — **prefer_const_constructors** (info) на строке `parts: <MessagePart>[ImagePart.fromUrl(url)]`.
- `lib/core/models/message_part.dart`: `const ImagePart.fromUrl(String url)` — const-конструктор; в тесте `url` объявлена как `const url = 'http://fixture.invalid/img.png'` — значит, вызов const-оспособен, но записан без `const`. Это единственное новое finding, внесённое heal2 (переписывание фикстуры).
- `ChatMessage(...)` линт НЕ флагает: у ChatMessage нет const-конструктора (мутабельные поля content/errorCode/toolStatus...). Доказательство: `test/f5_gallery_media_test.dart` с теми же не-const `ChatMessage(...)` и const-частями прошёл Analyze на 8e5b1c7.
- `prefer_final_locals` не задет: все `var errorShown/stubGone/i` переприсваиваются.

## Что поправлено

Ровно одна строка в `test/f5_image_reload_test.dart`: добавлен `const` к `ImagePart.fromUrl(url)` (плюс поясняющий комментарий и заметка в шапке файла). Фикстура heal2 (HttpOverrides-зона с моком HttpClient), фиксы heal1 (`const` в f5_gallery_media_test, `// ignore: unused_import` на flutter/services.dart), `_RetryableNetworkImage` из F1, ветка голых путей в `_fromSource` и TEMP-DIAG-UNMODIFIABLE не тронуты. Семантика теста не изменилась: `const`-часть ведёт себя так же (иммутабельна, читается `remoteUrl`).

## Что стоит улучшить рядом (не чинить сейчас)

- Общий источник pain: `flutter analyze` в CI падает на info-находках, а `analysis_options.yaml` активирует `prefer_const_constructors` глобально. Для тестов это высокорисково при каждом переписывании фикстур. Варианты: `analyzer.errors: prefer_const_constructors: ignore` для `test/**` (отдельный include) или правило «проверять тестовые правки локальным dart analyze» — требует согласования политики.
- В `_FixtureState`/`_MockHttpClient` осознанно типизированные списки (`List<String>`); при следующих правках держать это — падение типов в `List` снова даст несвязные ошибки.
- Дублирование PNG-фикстуры между f1/f5 тестами — кандидат в `test/helpers/` (как и отмечено в heal1).

## Как проверить результат

1. CI: Analyze Code, Run tests, build apk — зелёные на новом коммите; в частности F5-T-IMAGE-RELOAD-NO-REGEN и F5-T-GALLERY-IMAGE-AND-VIDEO/DEDUP/NEWEST-FIRST проходят.
2. Живой тест F5-LIVE-IMAGE-LOAD: на телефоне открыть чат со сгенерированной картинкой по URL, включить авиарежим → картинка показывает «Не удалось загрузить изображение» с кнопкой «Повторить загрузку» (без POST-генерации — проверяется счётчиком billing: новое списание не появляется), включить сеть → тап «Повторить загрузку» → та же картинка грузится с ТЕМ ЖЕ URL.
3. Живой тест F5-LIVE-GALLERY: сгенерировать картинку и видео в чате, перезапустить приложение, открыть «Галерея» (шторка чатов) — оба артефакта в галерее, свежие выше; после «Повторить» на картинке в галерее нет дублей.
