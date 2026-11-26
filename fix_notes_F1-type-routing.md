# F1-type-routing — заметки после фикса analyze

- Причина красной сборки: 5 × `unnecessary_non_null_assertion` в `lib/app_state.dart` — flow analysis уже продвигает `pr` в non-null через `isUserPreset`/`otherProvider` (final bool-переменные), поэтому `!` удалены; поведение `effectiveConfig()` не изменилось.
- Ветка `otherProvider` (Polza OAuth + пресет RouterAI): если в пресете пустой `apiKey`, ключ по-прежнему фоллбэчится на `settings.apiKey`/Polza-токен — возможен 401 уже на routerai.ru; проверить живьём.
- `effectiveConfig()` при дефолтном пресете берёт адрес/ключ из `settings`, а модель — из `pr`/`settings.model`; при прямой записи `settings.model` в обход `setConnection`/`updateActivePresetModel` модель может «разъехаться» — прогнать сценарии сквозного выбора модели.
- `PresetStore._ensureDefaultPreset` не `await`-ит `storage.setString('activePresetId', ...)` — риск потерять активный id при мгновенном закрытии приложения; проверить, что после рестарта активный пресет восстанавливается.
- `updateActivePresetModel`/`updateActivePresetStream` не валидируют пустые значения: пустая модель в пресете приведёт к молчаливому откату `currentModelId` на `settings.model` — стоит проверить, что UI не передаёт пустую строку.
- Проверить вручную: Polza OAuth + RouterAI-пресет, Polza OAuth + дефолтный пресет, RouterAI OAuth без пресета; после фикса `flutter analyze` должен давать 0 issues.
