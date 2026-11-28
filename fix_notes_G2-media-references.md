НЕДОСТАЮЩИЕ ФАЙЛЫ: нет

## Причина бага

Прикреплённые референсы для медиа-моделей не работали по трём причинам (сверка с картой архитектуры):
1. **UI**: `_buildMediaComposer` в `AdaptiveChatInputBar` вообще не рендерил скрепку и полосу миниатюр — а в `ChatScreen._currentConfig` `supportsAttachments: true` выставлялся только для `TextModelConfig`.
2. **State**: `CatalogEntry.maxReferenceImages` (уже парсится каталогом, например 7 у `grok-imagine-video-1-5`) не пробрасывался в `ActiveModelCapabilities`.
3. **API**: в `_send` ветки image/video игнорировали `_attachments`, а `ParameterTranslator.toPolzaMediaInput` не переносил `images` в тело `POST /v1/media`.

## Что изменено по слоям

- **`active_model_capabilities.dart`**: добавлены `maxReferenceImages` и геттер `supportsReferenceImages`.
- **`active_model_controller.dart`**: `_resolve` заполняет лимит из `CatalogEntry.maxReferenceImages` (с терпимым фоллбэком `mediaParams['images'].max`); лимит отражён в диагностическом логе.
- **`adaptive_chat_input_bar.dart`**: новые поля `mediaAttachments`/`onRemoveMediaAttachment`; скрепка (`Icons.attach_file`, ключ `g2_media_attach`) видна ТОЛЬКО при `supportsReferenceImages` (никаких захардкоженных списков моделей); полоса миниатюр (переиспользован `AttachmentStrip`) со счётчиком «N / max» (`g2_ref_counter`) над полем ввода.
- **`attachment_draft.dart`**: чистые, тестируемые helpers — `kMediaReferenceExtensions`, `selectMediaReferenceFiles` (фильтр jpg/jpeg/png/webp + лимит с учётом уже прикреплённых), `mediaReferenceMime`, `mediaReferenceDataUri` (data-URI `data:<mime>;base64,...`).
- **`chat_screen.dart`**: `_attach` в медиа-режиме фильтрует типы и лимит с понятными SnackBar («Максимум референсов для этой модели: 7», «Референсы — только изображения jpg, jpeg, png, webp»); `_sendImage`/`_sendVideo` кодируют готовые вложения (до `maxReferenceImages`) в data-URI, кладут в `params['images']` тела запроса (`GenerationRequest.parameters`) и очищают `_attachments`; референсы в снимок повтора НЕ пишутся (base64 раздул бы SharedPreferences); `_attachmentActions` в медиа-режиме не дублирует полосу композера; в `AdaptiveChatInputBar` проброшены вложения и колбэк удаления.
- **`parameter_translator.dart`**: `toPolzaMediaInput` переносит `translated['images']` в `out['images']` (опциональный параметр `maxReferenceImages` обрезает список); `translateWithCatalog` сохраняет `images` из `rawParams` во все ветки возврата (spec/null-fallback/пустое тело), поэтому оба исполнителя (`ImagesApiExecutor`, `AsyncJobExecutor`) автоматически включают `input.images` в тело POST /v1/media без правок самих исполнителей.

## Как проверить живым тестом

`flutter test test/g2_media_references_test.dart` — 6 именованных тестов по таблице приёмки: скрепка видна/скрыта по каталогу (G2-T-ATTACH-VISIBLE/HIDDEN), миниатюры с удалением и счётчиком «7 / 7» + блокировка свыше лимита (G2-T-LIMIT-AND-STRIP), `images` в `input` тела /v1/media с обрезкой по лимиту (G2-T-TRANSLATOR-IMAGES-IN-MEDIA-INPUT), плюс data-URI-кодирование файла и геттер capabilities. Живой чек пользователя: выбрать `grok-imagine-video-1-5` → появляется скрепка и счётчик, 8-й файл не добавляется с уведомлением, отправка уходит в POST /v1/media с `"images": ["data:image/...;base64,..."]`.
