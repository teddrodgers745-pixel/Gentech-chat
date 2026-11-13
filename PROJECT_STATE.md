# GenTech Lab — Project State

_Last updated: 2026-11-14_

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
- **Stage 2c-3 (открыта)**: merge CatalogEntry в
  `ParameterTranslator.translateWithCatalog` с приоритетом
  `UserOverride > CatalogEntry > Curated > spec-defaults`. Требует
  изменения сигнатуры: `GenerationRequest` не несёт CatalogEntry, а
  `translateWithCatalog` не получает каталог — нужно передавать
  CatalogEntry (либо уже разрешённую spec) новым опциональным параметром
  из исполнителей (ImagesApiExecutor/AsyncJobExecutor) и добавить
  field-level merge между user и curated в трансляторе. UI-уровень
  (caps.params из ActiveModelController) уже перекрывает основные
  сценарии, поэтому перенос безопасен и отложен.
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
