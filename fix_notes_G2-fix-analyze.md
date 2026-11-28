НЕДОСТАЮЩИЕ ФАЙЛЫ: нет

## Причина бага
Все 8 errors падающего шага «Analyze Code» (run 46142029615, коммит ce6e379) — в одном месте `lib/screens/chat_screen.dart`, строки 2549–2552: оборванная правкой G2 закрывающая скобочная последовательность метода `_empty` (хвост файла, область строк 2540–2553). Незакрытая/заменённая закрывающая `]` литерала `children: [...]` виджета Column дала `Expected to find ']'` (2549:11), а каскад восстановления парсера — `Expected to find ';'` (2551:7), `dead_code`/`missing_identifier`/`unexpected ';'` (2551:8, 2552:5). Ошибка чисто синтаксическая, вне проводки G2.

## Что изменено
1. UI-слой (`lib/screens/chat_screen.dart`): восстановлена корректная закрывающая последовательность метода `_empty` в области строк 2540–2553 — `],` (children Column) → `),` (Column) → `),` (Padding) → `);` (Center) после `],`/`),` внутренних Wrap. Остальной файл (2571 строка) и вся проводка G2 не тронуты: `_attach` (лимит/типы строго из каталога), `_sendImage`/`_sendVideo` (data-URI референсы в `params['images']`, расходование вложений), `_mediaReferenceImages`, `mediaAttachments`/`onRemoveMediaAttachment` в build, `_attachmentActions`. TEMP-DIAG-UNMODIFIABLE участки отсутствуют.
2. Тест (`test/g2_media_references_test.dart`, строки 75 и 97): `AdaptiveChatInputBar(` → `const AdaptiveChatInputBar(...)` — все аргументы константны (const-конструктор, const-capabilities, `ModelTypes.video` — static const); внутренний избыточный `const` у `config: TextModelConfig()` снят, чтобы не породить `unnecessary_const`. Логика тестов не менялась.
3. Сервисный слой G2 проверен по логу CI и не менялся (в нём 0 issues): `lib/models/attachment_draft.dart`, `lib/core/models/active_model_capabilities.dart`, `lib/core/generation/active_model_controller.dart`, `lib/core/generation/parameter_translator.dart`, `lib/features/composer/adaptive_chat_input_bar.dart`. Неиспользуемых импортов после правки не появилось.

## Как проверить живым тестом
- G2-T-ANALYZE-GREEN: `flutter analyze --no-fatal-infos` в CI — 0 errors/warnings, шаг Analyze Code зелёный (info-уровень тоже чист: оба prefer_const_constructors устранены).
- G2-T-SYNTAX-FIXED: строки 2549–2552 `chat_screen.dart` — закрывающая последовательность `_empty` парсится без `expected_token`/`missing_identifier`/`unexpected_token`/`dead_code`.
- G2-T-RUN-TESTS-GREEN: шаг `Run tests` — все тесты `test/g2_media_references_test.dart` (G2-T-CAPS, G2-T-ATTACH-VISIBLE-WHEN-SUPPORTED, G2-T-ATTACH-HIDDEN-WHEN-UNSUPPORTED, G2-T-LIMIT-AND-STRIP, G2-T-TRANSLATOR-IMAGES-IN-MEDIA-INPUT, G2-T-DATAURI) зелёные; `test/g1_video_player_test.dart` не краснеет.
