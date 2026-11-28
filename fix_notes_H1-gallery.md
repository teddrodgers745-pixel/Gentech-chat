НЕДОСТАЮЩИЕ ФАЙЛЫ: нет

H1-gallery-heal1 — минимальные фиксы строго по логу flutter analyze (7 issues):

1. lib/features/gallery/artifacts_gallery_screen.dart
   - undefined_method `_EmptyHint` (64:25): добавлен недостающий приватный
     виджет `_EmptyHint({palette, section})` — заглушка пустой галереи с
     текстом прежней пустой ветки F5 для «Все» и уточнёнными текстами для
     «Изображения»/«Видео». Остальные методы не тронуты.
   - unchecked_use_of_nullable_value (377), argument_type_not_assignable
     (378), return_of_invalid_type (381): в `VideoPreviewCache.acquire`
     замыкание внутри `.then` не сохраняет promotion nullable-локала
     `entry`, а re-read `entry.init` остаётся nullable. Точечное
     исправление: работа в замыкании через ненулевую ссылку
     `final current = entry;`, а возвращаемое будущее фиксируется как
     `final init = current.init ??= ...; return init;`. Семантика кэша
     (uses/lastUsed/LRU-вытеснение/чёрный список) не изменена.

2. test/h1_gallery_sections_test.dart
   - const_with_non_const (36:32): убран `const` перед `VideoEvent(...)` —
     в зафиксированной версии video_player_platform_interface конструктор
     VideoEvent не константный.
   - override_on_non_overriding_member (43): снят `@override` с
     `setPreventsDisplaySleepDuringVideoPlayback` — в данной версии
     интерфейса у базового класса метода с таким именем нет; сам метод
     оставлен обычным no-op фейка (поведение теста не меняется).
   - undefined_function `_PlaceholderVideoPlatform` (141): добавлена
     пустая конкретная реализация
     `class _PlaceholderVideoPlatform extends VideoPlayerPlatform {}`
     для восстановления платформы в addTearDown.

Другие файлы не менялись; TEMP-DIAG-UNMODIFIABLE не затронут.
