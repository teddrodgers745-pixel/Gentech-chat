# GenTech Lab — Project State

_Last updated: 2026-11-13_

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
- **Stage 2c (открыта)** — остатки (e):
  - sizes-чипсы: у CatalogEntry нет списка sizes (только mediaParams-карта
    произвольного формата) — нужен парсер/источник размеров;
  - resolution в image-запросе: ключ `image_resolution` у Polza —
    добавить перевод ключа в `ParameterTranslator.toImageBody` по
    провайдеру/схеме (сейчас в image-запрос resolution не отправляется
    намеренно, чтобы не ломать валидные запросы);
  - merge каталога подключения в `ParameterTranslator.translateWithCatalog`
    (сейчас spec = user > curated; catalog-уровень добирается только
    через caps.params в UI);
  - качества/разрешения в диалоге ручного override параметров.
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
