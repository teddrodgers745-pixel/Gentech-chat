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

## Current stage — Stage 2 (СПЛИТ на 2a и 2b)
Исходная Stage 2 содержит 5 подцелей, разбиваем из-за разных risk-профилей:

### Stage 2a (закрыта) — критический backend + verification
- **(a) Изоляция lookup по connectionId**: `ActiveModelController._resolve`
  должен брать CatalogEntry из каталога ТЕКУЩЕГО подключения, а не из
  общего пула Polza+RouterAI+OpenRouter. Одинаковый modelId в разных
  провайдерах -> сейчас может подтянуться чужой.
- **(d) Reasoning pass-through verification**: гарантировать, что
  `CatalogEntry.reasoningLevels` (уже нормализованные) без искажений
  доезжают через `ActiveModelCapabilities`/`ModelInfo` до капсулы
  `text_chat_input`. Не пересчитывать из raw, не подставлять curated
  при явно пустом списке от провайдера.
- Изменённые файлы: `lib/core/generation/active_model_controller.dart`
  (`_resolve` берёт CatalogEntry строго из каталога АКТИВНОГО подключения:
  `_catalogConnectionId()` -> `ProviderCatalogService.lookup(connectionId, ...)`;
  fallback при connectionId == null — прежние резолверы; уровни reasoning
  из CatalogEntry как есть, mandatory убирает 'off', при явном отсутствии
  reasoning капсула скрывается без подстановки curated),
  `lib/core/catalog/provider_catalog_service.dart`
  (`lookup(connectionId, modelId)` — поиск записи только в каталоге
  указанного подключения).

### Stage 2b (открыта, после 2a) — UX + merge + media
- **(b) UI refresh после `syncFromConnection`**: `ActiveModelController`
  пересчитывает `_resolve` и `notifyListeners()` без рестарта. Простая
  guard-проверка от races, без мьютексов.
- **(c) Приоритет и merge по полям**: `UserOverride > dynamic catalog >
  curated > unknown`. Явно пустой список ≠ отсутствует (не подставлять
  curated). `null ≠ false`.
- **(e) Media params в UI**: `CatalogEntry.mediaParams` (aspectRatios,
  durations (discrete и range), resolutions, sizes, qualities) ->
  `ModelParamsBar`/`ComposerShell` chips -> `ParameterTranslator`.
  Только image/video модели (flux.2-pro, sora и т.п.).

## Next stages
- **Stage 3:** сквозные регрессионные тесты каталога, контроллера, парсеров.

## Changelog
- 2026-11-13: создан файл. Stage 2 разбита на 2a (backend+verification)
  и 2b (UX+media) для изоляции рисков.
- 2026-11-13: Stage 2a закрыта. (a) lookup изолирован по connectionId;
  (d) reasoningLevels pass-through проверен и пофикшен.
