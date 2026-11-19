# GenTech Lab — Project State

_Last updated: 2026-11-19_

## Repo & workflow
- `~/gentech_work` — Flutter app `gentech_lab`.
- Agent: `~/agent.py`. Providers: `glm` (regular, quality — default),
  `glm53`, `flash` (только для тривиальных задач).
- Workflow: `~/run_*.py` -> `--auto-merge` в `origin/main` -> CI -> APK.
- Правило импортов: НЕ удалять существующие импорты даже при `unused_import`
  (использовать `// ignore: unused_import`).

## Closed stages
- ✅ Multimodal v2 + Curated params: `CuratedParameterCatalog`,
  `UserParamOverrideStore`, `ParameterTranslator`, `ModelParamsBar`,
  `ManualParamsSheet`, `QuickAccessSheet`.
- ✅ Stage 1b (#552): catalog parsers + dispatcher в `lib/core/catalog/`.
- ✅ Stage 1c (#555): `parseModelsList` в `syncFromConnection`.
- ✅ Reasoning normalization (#557): `reasoning_levels.dart` + нормализация
  `none→off`, `minimal→low`, canonical sort, drop `off` при mandatory.
  Применено в polza/routerai/openrouter parsers + provider_catalog_service.
  APK `gentech-lab-v2-101609.apk`.
- ✅ Media parsers fix: aspectRatios/resolutions для Polza/RouterAI
  теперь парсятся из реальных полей API (flux.2-pro, seedream-4.5 и др.).
- ✅ Stage 2a: (a) lookup изолирован по connectionId; (d) reasoning
  pass-through проверен и пофикшен.

### Stage 2b (закрыта)
- **(b) UI refresh после syncFromConnection** — ПОДТВЕРЖДЕНО (реализовано
  в 2a, не трогали): `ActiveModelController` слушает `providerCatalog`
  (`_onCatalogChanged`), пересчитывает `_resolve` и `notifyListeners()`
  без рестарта; race guard — существующий токен `_resolveToken`
  (проверка после каждого await); `notifyListeners()` рекурсивно
  `_resolve` не вызывает. Добавлен только подтверждающий комментарий.
- **(c) Приоритет и merge по полям**: в `active_model_controller.dart`
  добавлены `_paramCandidates`, `_loadUserOverride`, `_loadCuratedParams`,
  `_mergeFieldLevel`; сборка params в `_resolve` переделана с
  «всё или ничего» на field-level merge:
  `UserParamOverrideStore > CatalogEntry/кэш OpenRouter > curated >
  unknown`. Непустое поле более приоритетного источника всегда побеждает,
  пустое поле источника пропускается (curated добивает недостающие поля
  даже при непустом CatalogEntry); constraints объединяются из всех
  источников; confidence='user' и isUserDefined при вкладе override.
  `_fillFromReference` (OpenRouter reference) не тронут — дизайн корректен.
- **(e) Media params в UI**: CatalogEntry (aspectRatios, durations —
  discrete и range, resolutions, qualities) теперь попадает в
  `caps.params` через merge (c) и отрисовывается чипсами
  `AdaptiveChatInputBar`; добавлены чипсы качества и колбэки
  `onResolutionChanged`/`onQualityChanged`; выбранные resolution/quality
  передаются в `GenerationRequest.parameters` (видео — оба поля,
  изображение — quality), `ImagesApiExecutor` мержит `request.parameters`
  в rawParams перед `ParameterTranslator.translateWithCatalog`.
  `ParameterTranslator.toImageBody/toVideoBody` уже переводит
  aspect_ratio / size / duration / resolution / quality — изменений
  не потребовалось. Только image/video моделей: у chat-моделей
  media-чипсы не показываются (composer строится только для media-kind).

## Архитектурные правила
- Для known providers (polza/routerai/openrouter): только их /v1/models.
  OpenRouter reference — только для сторонних API. null от провайдера =
  чипсы скрыты, curated fallback ТОЛЬКО для media-полей (не reasoning).
- Реактивная защита: 400 с metadata.raw → retry без поля (один раз).
  warnings[] от Media API → in-memory blacklist по модели.
- async:true для video — защита от 120-сек таймаута.

## Next stages
- **Stage 2c (закрыта 2026-11-14, Stage 2c-2)** — остатки (e):
  - ✅ resolution в image-запросе: `chat_screen._sendImage` пробрасывает
    `ParamKeys.resolution` в `GenerationRequest.parameters`;
    `ParameterTranslator.toImageBody` отдаёт безопасный дефолт
    `'resolution'` (совместим с RouterAI и Media API), а
    `ImagesApiExecutor` при `providerId == 'polza'` дополнительно
    дублирует значение в `'image_resolution'` (реальное имя в Polza
    Media API). Перевод сделан в исполнителе по существующему
    провайдер-флагу — без хардкода по baseUrl и без ломки сигнатуры
    транслятора.
  - ✅ качества/разрешения в ручном override: `ManualParamsSheet` получил
    секцию MEDIA — чипсы resolutions/qualities из caps.params (тап
    подставляет значение в поле шторки); сохранение — прежним путём через
    `UserParamOverrideStore`. `AdaptiveChatInputBar._openManualParamsDialog`
    теперь открывает эту шторку и передаёт списки из caps; тип модели
    фиксируется в override (видео-модель не превращается в image).
  - merge каталога подключения в `ParameterTranslator.translateWithCatalog`
    — перенесён в Stage 2c-3 (см. ниже).
- ✅ **Stage 2c-3 (закрыта 2026-11-15)**: merge CatalogEntry в
  `ParameterTranslator.translateWithCatalog`. Итоговые merged-параметры
  контроллера (field-level: User > CatalogEntry > Curated) публикуются
  в статическом реестре ActiveModelController (`mergedParamsFor`) —
  GenerationRequest, исполнители и UI не менялись. Транслятор берёт
  merged как базовый источник и применяет свежий UserOverride поверх
  по полям (constraints объединяются); без merged — прежний путь
  (UserOverride > Curated).
- **Stage 2d (открыта)**: sizes-chips — отложено, в API Polza/RouterAI
  нет отдельного поля 'sizes' (есть image_resolution/resolutions — это
  уже показывается как resolutions). Если появится источник — вернуться.
- **Stage 3:** сквозные регрессионные тесты каталога, контроллера, парсеров.

## Changelog
- 2026-11-13: создан файл. Stage 2 разбита на 2a (backend+verification)
  и 2b (UX+media) для изоляции рисков.
- 2026-11-13: Stage 2a закрыта. (a) lookup изолирован по connectionId;
  (d) reasoningLevels pass-through проверен и пофикшен.
- 2026-11-13: медиа-парсеры пофикшены. polza_parser: params['resolution']
  → params['image_resolution'] (реальное имя в API). routerai_parser:
  supported_resolutions → supported_image_sizes. Добавлен парсинг цен по
  разрешению в mediaParams['pricing_tiers'] / ['pricing_variants'].
- 2026-11-13: Stage 2b закрыта. (b) UI refresh с race guard (подтверждено
  из 2a); (c) field-level priority merge (user > catalog > curated);
  (e) media params в чипсах композера + проброс resolution/quality в
  запрос (частично: sizes и image-resolution — в Stage 2c).
- 2026-11-14: media-парсеры расширены. RouterAI: в mediaParams
  добавлены output_formats/backgrounds/max_image_count/max_image_references/
  supports_image_references/image_seed/supports_negative_prompt.
  Polza: в mediaParams добавлены images_min/images_max/prompt_max_length.
  Существующие pricing_tiers/pricing_variants сохранены. UI пока эти поля
  не использует — данные для будущих stages.
- 2026-11-14: Stage 2c-2. (1) image_resolution в image-запросе —
  resolution пробрасывается в GenerationRequest.parameters (chat_screen),
  toImageBody отдаёт 'resolution', ImagesApiExecutor для Polza
  дополнительно дублирует в 'image_resolution'. (3) ManualParamsSheet
  media-чипсы (resolution/quality) + подключение из AdaptiveChatInputBar.
  (2) — отложено: merge CatalogEntry в translateWithCatalog требует
  изменения сигнатуры, перенос в Stage 2c-3.
- 2026-11-15: Stage 4.1. (a) _needsReference skip для known providers
  (polza/routerai/openrouter): фильтр в lookup по baseUrl подключения
  (_isKnownProviderConnection), сигнатура _needsReference не менялась,
  _fillFromReference сохранён для сторонних API. (b) retry 400 через
  error.metadata.raw — реализован в реальном исполнителе POST
  /chat/completions (ChatService._roundOnce): извлечение имени поля
  (3 паттерна), один retry с удалением поля, повторный 400 — пользователю.
  (c) async:true для video-моделей в AsyncJobExecutor._createJob.
  (d) warnings[] медиа-ответа → in-memory blacklist
  _unsupportedParamsByModel в ImagesApiExecutor (параметр не отправляется
  повторно, лог '[media] dropped unsupported param'). Stage 2c пункт (2)
  остаётся в Stage 2c-3.
- 2026-11-15: Stage 2c-3. ParameterTranslator теперь принимает итоговые
  merged params из контроллера (User > Catalog > Curated).
- 2026-11-15: фикс 401. Ключ и baseUrl теперь берутся из активного пресета
  (preset.apiKey/baseUrl), а не из глобальных settings, если пресет заполнен.
- 2026-11-16: фикс 401 (часть 2). effectiveConfig() теперь отдаёт приоритет
  polzaAuth.accessToken, если polzaAuth.isAuthenticated, кроме случая
  явного RouterAI-пресета. Устранён конфликт со старыми ключами в
  settings/preset.
- 2026-11-16: OAuth Polza. Добавлен refreshAccessToken() (grant_type=refresh_token),
  авто-refresh при 401 в chat_service (один retry), prompt=login в URL
  авторизации (браузер больше не подхватывает старую сессию).
- 2026-11-16: ФИКС 401 НАЙДЕН. polzaBaseUrl исправлен с
  https://api.polza.ai/api/v1 на https://polza.ai/api/v1. Причина:
  api.polza.ai делает редирект на polza.ai, при котором dart:io
  HttpClient вырезает заголовок Authorization. Добавлена миграция
  старого URL в settings.baseUrl при загрузке. Добавлена очистка
  'Bearer ' в ChatService._roundOnce на случай ручного ввода.
- 2026-11-16: Убран refreshAccessToken() из обработки 401 (Polza не
  поддерживает grant_type=refresh_token). При 401 для Polza — разлогин.
  В текст ошибки 401 добавлены URL и префикс токена для отладки.
  baseUrl принудительно мигрирует на https://polza.ai/api/v1.
- 2026-11-16: ФИКС OAuth Polza. Сервер возвращает 'key' (pza_...), а не
  'access_token'. Код обмена исправлен: парсится data['key'], сохраняется
  как API-ключ. Refresh-токены удалены (не поддерживаются).
- 2026-11-16: OAuth Debug на экране. Сырой ответ /auth/token и распарсенный ключ выводятся в настройках Polza. Если ключ не pza_ — AlertDialog.
- 2026-11-16: Диагностика PKCE. Выведен code_verifier (начало/конец), проверка соответствия regex, проверка совпадения сгенерированного и отправленного. Убрано шифрование code_verifier.
- 2026-11-18: Исправлена генерация PKCE code_challenge. Удален багованный самописный SHA-256, заменен на стандартный пакет crypto. Это исправляет ошибку 'Невалидный code_verifier' от Polza.
- 2026-11-18: Финальный фикс 401. Ключ pza_... из OAuth принудительно перезаписывает settings.apiKey и активный пресет при логине. effectiveConfig() отдает приоритет polzaAuth.accessToken.
- 2026-11-18: Полная перезапись OAuth Polza с нуля. Использован стандартный crypto для PKCE, убраны самописные велосипеды. Сохранение ключа pza_... и приоритет над пресетами.
- 2026-11-18: OAuth Polza финальный фикс. Переход на надежный метод получения callback (flutter_web_auth_2 или жесткий контроль loopback). Вывод сырого ответа при ошибке обмена.
- 2026-11-18: OAuth Polza полностью перезаписан по фиксу Gemini 4 Argon.
  Исправлены race conditions в loopback-сервере, добавлен fallback на
  form-urlencoded, изоляция сессий PKCE. Токен сохраняется корректно.
- 2026-11-18: Добавлен OAuth RouterAI. Создан RouterAiAuthService, UI для
  входа (RouterAiAuthSection в настройках), обновлен effectiveConfig()
  (приоритет: Polza -> RouterAI -> пресеты/settings). Ключ валидируется
  префиксом sk-, обмен кода — POST /api/v1/auth/keys без grant_type,
  ответ data['key']. Карточка подключена ниже Polza в settings_screen.
- 2026-11-19: Исправлена кнопка «Загрузить модели» при OAuth. Секция
  «Подключение» переименована в «Новое подключение». Поля ручного ввода
  предназначены для сторонних API. Кнопка берёт подключение из
  effectiveConfig() (Polza -> RouterAI -> пресет/настройки), при RouterAI
  OAuth выбор модели пишется через settings.setConnection; в
  _collectConnections добавлена RouterAI-сессия (id 'routerai').
