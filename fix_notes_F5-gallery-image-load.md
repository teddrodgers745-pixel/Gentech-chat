# F5-gallery-image-load-heal2 — причины и правки

CI: запуск 46013163126, ветка agent, коммит 8e5b1c7. Упал только шаг «Run tests» (flutter analyze — зелёный). Два падения — две разные причины.

## 1. F5-T-GALLERY-IMAGE-AND-VIDEO: 2 вместо 3

**Причина (не симптом).** `GeneratedMediaCollector._fromSource` распознавал только `file://`, `data:image/video` и `http(s)`. Но `ImagePart.fromPath`/`VideoPart.fromPath` хранят ГОЛЫЙ абсолютный путь без префикса (`/storage/emulated/0/GenTech/img_a.png`) — такой источник попадал в «неподдерживаемую схему» и отбрасывался. В галерею собирались только markdown-ссылка `file://` и `VideoPart`-URL → 2 вместо 3.

**Правка.** В `_fromSource` добавлена ветка голых локальных путей (`s.startsWith('/')`) → `GalleryMediaItem(isLocal: true)`. Дедуп не страдает и стал точнее: `file:///x/img.png` и `/x/img.png` нормализуются в один path-ключ — один и тот же файл не дублируется из двух представлений. Потребители (ArtifactsGalleryScreen) не менялись: API `GalleryMediaItem` не менялся.

## 2. F5-T-IMAGE-RELOAD-NO-REGEN: TimeoutException после 2 минут

**Причина (не симптом).** Фикстура поднимала живой HttpServer и ждала сеть окнами `tester.runAsync` внутри `testWidgets`. `testWidgets` работает в fake-async; сочетание «реальный HTTP + runAsync» — документированная ловушка (api.flutter.dev, WidgetTester.runAsync: «If your widget test hangs and you are using runAsync…»). Тест завис на первом же окне ожидания до таймаута. Продакшн-виджет `_RetryableNetworkImage` не виноват: его поведение (заглушка → ручной повтор того же URL без новой генерации) корректно.

**Правка.** По рекомендациям того же API («restructure your code so you do not need runAsync») тест переведён на детерминированный fake-async: HttpClient замокан через HttpOverrides-зону (мгновенные microtask-ответы, счётчики GET/POST), гонка только на `pump`. Имя теста и проверяемое поведение сохранены: 503 → заглушка с кнопкой → тап «Повторить загрузку» → второй GET ТОГО ЖЕ URL (`gets.toSet().length == 1`, `gets.length == 2`) → заглушка уходит; `posts == 0`.

## Что стоит улучшить рядом

- Покрыть авто-повтор `_RetryableNetworkImage` (таймер 2/4/8/… с) отдельным фикстурным тестом через `pump(Duration(seconds: 2))` — сейчас покрыт только ручной повтор.
- Для реальных сетевых widget-фикстур держать правило: живой HttpServer — только в plain `test` (как в f1_retry_resume_test); в `testWidgets` — мок HttpClient на уровне HttpOverrides.
- При добавлении аудио (F6) вынести нормализацию источников медиа из `_fromSource` в общий хелпер MessagePart, чтобы типы медиа не рассинхронизировались.
