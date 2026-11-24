// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/auth/polza_auth_service.dart';
import 'core/auth/routerai_auth_service.dart';
import 'core/catalog/provider_catalog_service.dart';
import 'core/search/search_strategy.dart';
import 'core/storage.dart';
import 'models.dart';
import 'theme.dart';

final AppSettings settings = AppSettings();
final ChatStore store = ChatStore();
final PresetStore presets = PresetStore();

int _idSeq = 0;

/// Уникальный идентификатор: время плюс счётчик. Только microsecondsSinceEpoch
/// недостаточно: на части устройств точность времени миллисекундная, и
/// инструменты, созданные подряд (например, из MCP-каталога), получали
/// одинаковый id — из-за этого в редакторе пресета тумблеры «слипались».
String newId() {
  _idSeq += 1;
  return '${DateTime.now().microsecondsSinceEpoch}-$_idSeq';
}

/// Итоговая конфигурация запроса: активный пресет либо глобальные настройки.
class EffectiveConfig {
  final String baseUrl;
  final String apiKey;
  final String model;
  final String systemPrompt;
  final bool stream;
  final double? temperature;

  const EffectiveConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.systemPrompt,
    required this.stream,
    required this.temperature,
  });
}

/// Активный пресет имеет приоритет; если он не выбран — работают прежние
/// настройки (совместимость со старыми данными). Если адрес или ключ пусты,
/// но пользователь авторизован в Polza AI, автоматически подставляются
/// OAuth-токен и Base URL Polza — переключение пресетов больше не роняет
/// запросы с ошибкой ключа.
EffectiveConfig effectiveConfig() {
  final polzaKey =
      polzaAuth.isAuthenticated ? polzaAuth.accessToken.trim() : '';
  final polzaUrl = PolzaAuthService.polzaBaseUrl;

  final pr = presets.active;
  // Фикс 401 (часть 2): при активной сессии Polza AI живой OAuth-токен
  // (polzaAuth.accessToken) имеет приоритет над settings.apiKey и ключом
  // пресета — иначе запросы уходили с устаревшим ключом из настроек либо
  // пресета и падали с «Неверный API-ключ (401)», хотя
  // polzaAuth.isAuthenticated был true. Исключение — явный пресет
  // ДРУГОГО провайдера: baseUrl содержит 'routerai.ru' и не содержит
  // 'polza.ai' — такой пресет используется целиком (pr.baseUrl + pr.apiKey).
  if (polzaAuth.isAuthenticated) {
    final presetUrl = pr?.baseUrl.trim() ?? '';
    final isUserPreset = pr != null && pr.id != PresetStore.defaultPresetId;
    final otherProvider = isUserPreset &&
        presetUrl.contains('routerai.ru') &&
        !presetUrl.contains('polza.ai');
    if (otherProvider) {
      final presetKey = pr.apiKey.trim();
      final key = presetKey.isNotEmpty
          ? presetKey
          : (settings.apiKey.trim().isNotEmpty
              ? settings.apiKey.trim()
              : polzaKey);
      return EffectiveConfig(
        baseUrl: presetUrl,
        apiKey: key,
        model: pr.model.trim(),
        systemPrompt: pr.systemPrompt,
        stream: pr.stream,
        temperature: pr.temperature,
      );
    }
    // Пользователь залогинен в Polza AI и пресет не указывает явно на
    // RouterAI: подключение целиком из Polza-сессии (токен + Base URL),
    // модель и поведение — из активного пресета, как раньше.
    // Фикс 401 (финал): polzaAuth.accessToken здесь имеет НАИВЫСШИЙ
    // приоритет — никакие старые settings.apiKey или pr.apiKey не могут
    // его перебить (исключение — только явный RouterAI-пресет выше).
    assert(() {
      debugPrint(
        '[auth] effectiveConfig: Polza OAuth активна, '
        'ключ: ${polzaKey.length >= 8 ? polzaKey.substring(0, 8) : polzaKey}',
      );
      return true;
    }());
    return EffectiveConfig(
      baseUrl: polzaUrl,
      apiKey: polzaKey,
      model: (pr?.model ?? settings.model).trim(),
      systemPrompt:
          isUserPreset ? pr.systemPrompt : settings.systemPrompt,
      stream: pr?.stream ?? true,
      temperature: isUserPreset ? pr.temperature : null,
    );
  }
  if (routerAiAuth.isAuthenticated) {
    // Приоритет 2: активна OAuth-сессия RouterAI (Polza не авторизован) —
    // подключение целиком из RouterAI-сессии (ключ sk-... + Base URL
    // routerai.ru/api/v1), модель и поведение — из активного пресета
    // либо настроек, как в Polza-ветке.
    final routerKey = routerAiAuth.accessToken.trim();
    final routerUrl = RouterAiAuthService.routeraiBaseUrl;
    final isUserPreset = pr != null && pr.id != PresetStore.defaultPresetId;
    assert(() {
      debugPrint(
        '[auth] effectiveConfig: RouterAI OAuth активна, '
        'ключ: ${routerKey.length >= 8 ? routerKey.substring(0, 8) : routerKey}',
      );
      return true;
    }());
    return EffectiveConfig(
      baseUrl: routerUrl,
      apiKey: routerKey,
      model: (pr?.model ?? settings.model).trim(),
      systemPrompt:
          isUserPreset ? pr.systemPrompt : settings.systemPrompt,
      stream: pr?.stream ?? true,
      temperature: isUserPreset ? pr.temperature : null,
    );
  }
  if (pr != null && pr.id != PresetStore.defaultPresetId) {
    // Фикс 401: адрес и ключ берутся ИЗ ОДНОГО источника — та же логика
    // выбора подключения, что в ActiveModelController._catalogConnectionId.
    // Пресет используется целиком, только если он заполнен ПОЛНОСТЬЮ
    // (baseUrl и apiKey); иначе подключение целиком из глобальных настроек
    // (с прежним фоллбэком на Polza-сессию). Прежнее по-полевое смешивание
    // (адрес пресета + ключ из настроек/Polza) отправляло запрос на адрес
    // пресета с чужим или устаревшим ключом -> «Неверный API-ключ (401)»,
    // хотя авторизация Polza была активна.
    final presetFilled =
        pr.baseUrl.trim().isNotEmpty && pr.apiKey.trim().isNotEmpty;
    final url = presetFilled
        ? pr.baseUrl.trim()
        : (settings.baseUrl.trim().isNotEmpty
            ? settings.baseUrl.trim()
            : (polzaKey.isNotEmpty ? polzaUrl : ''));
    final key = presetFilled
        ? pr.apiKey.trim()
        : (settings.apiKey.trim().isNotEmpty
            ? settings.apiKey.trim()
            : polzaKey);
    return EffectiveConfig(
      baseUrl: url,
      apiKey: key,
      model: pr.model.trim(),
      systemPrompt: pr.systemPrompt,
      stream: pr.stream,
      temperature: pr.temperature,
    );
  }
  // Системный дефолтный пресет отражает глобальные настройки: адрес, ключ
  // и системный промпт читаются из настроек «живьём», модель — из пресета
  // (PresetStore — единственный источник истины для модели).
  final url = settings.baseUrl.trim().isNotEmpty
      ? settings.baseUrl.trim()
      : (polzaKey.isNotEmpty ? polzaUrl : '');
  final key = settings.apiKey.trim().isNotEmpty
      ? settings.apiKey.trim()
      : polzaKey;
  return EffectiveConfig(
    baseUrl: url,
    apiKey: key,
    model: (pr?.model ?? settings.model).trim(),
    systemPrompt: settings.systemPrompt,
    // Тумблер «Поток (Stream)» активного (в т.ч. дефолтного) пресета
    // управляет стримингом; без пресета — прежнее поведение (stream: true).
    stream: pr?.stream ?? true,
    temperature: null,
  );
}

class PresetStore extends ChangeNotifier {
  /// Идентификатор системного дефолтного пресета: создаётся автоматически
  /// при смене модели без активного пресета; удалить его нельзя.
  static const String defaultPresetId = 'system-default';

  final List<Preset> _items = [];
  String _activeId = '';

  List<Preset> get items => List.unmodifiable(_items);

  Preset? get active {
    for (final p in _items) {
      if (p.id == _activeId) return p;
    }
    return null;
  }

  /// Алиас для единообразного доступа к активному пресету.
  Preset? get activePreset => active;

  Preset? byId(String id) {
    for (final p in _items) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> load() async {
    final raw = await storage.getString('presets');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _items
          ..clear()
          ..addAll(list
              .map((e) => Preset.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList());
      } catch (_) {}
    }
    _activeId = await storage.getString('activePresetId') ?? '';
    if (active == null) _activeId = '';
  }

  Future<void> _persist() async {
    await storage.setString(
      'presets',
      jsonEncode(_items.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> setActive(String id) async {
    if (byId(id) == null) return;
    _activeId = id;
    await storage.setString('activePresetId', id);
    notifyListeners();
  }

  Future<void> clearActive() async {
    _activeId = '';
    await storage.setString('activePresetId', '');
    notifyListeners();
  }

  Future<void> upsert(Preset preset) async {
    final i = _items.indexWhere((x) => x.id == preset.id);
    if (i >= 0) {
      _items[i] = preset;
    } else {
      _items.add(preset);
    }
    await _persist();
    notifyListeners();
  }

  /// Обновляет модель активного пресета и сохраняет его в
  /// SharedPreferences. Пресет — единственный источник истины для модели;
  /// вызывается из ActiveModelController.setModel и из быстрых смен
  /// модели в интерфейсе.
  ///
  /// Если активного пресета нет, создаётся «Системный дефолтный пресет»
  /// ([defaultPresetId]) — его нельзя удалить, он отражает глобальные
  /// настройки подключения, а модель хранит в себе.
  Future<void> updateActivePresetModel(String newModelId) async {
    final pr = active ?? _ensureDefaultPreset();
    pr.model = newModelId;
    await _persist();
    notifyListeners();
  }

  /// Обновляет тумблер «Поток (Stream)» активного пресета и сохраняет
  /// его в SharedPreferences. Если активного пресета нет, создаётся
  /// системный дефолтный — как у updateActivePresetModel.
  Future<void> updateActivePresetStream(bool value) async {
    final pr = active ?? _ensureDefaultPreset();
    pr.stream = value;
    await _persist();
    notifyListeners();
  }

  /// Создаёт (при отсутствии) системный дефолтный пресет и делает его
  /// активным. Адрес, ключ и промпт берутся из текущих настроек.
  Preset _ensureDefaultPreset() {
    var pr = byId(defaultPresetId);
    if (pr == null) {
      pr = Preset(
        id: defaultPresetId,
        name: 'Системный дефолтный пресет',
        baseUrl: settings.baseUrl,
        apiKey: settings.apiKey,
        model: settings.model,
        systemPrompt: settings.systemPrompt,
        stream: true,
      );
      _items.add(pr);
    }
    if (_activeId != defaultPresetId) {
      _activeId = defaultPresetId;
      storage.setString('activePresetId', defaultPresetId);
    }
    return pr;
  }

  /// Системный дефолтный пресет удалить нельзя.
  Future<void> remove(String id) async {
    if (id == defaultPresetId) return;
    _items.removeWhere((x) => x.id == id);
    if (_activeId == id) {
      _activeId = '';
      await storage.setString('activePresetId', '');
    }
    await _persist();
    notifyListeners();
  }
}

class AppSettings extends ChangeNotifier {
  String apiKey = '';

  /// Адрес провайдера и модель вводятся пользователем:
  /// по умолчанию поля пустые (подсказки — в hintText).
  String baseUrl = '';
  String model = '';
  String systemPrompt = '';
  String paletteId = 'light';
  String bodyFont = 'Literata';
  String codeFont = 'JetBrains Mono';
  double lineHeight = 1.55;

  /// Экономика: показывать ли стоимость ответов (по умолчанию включено).
  bool showCost = true;

  /// Валюта стоимости ('RUB', 'USD', 'EUR', 'CNY').
  String currency = 'RUB';

  /// Автоозвучка новых ответов модели (TTS), по умолчанию выключена.
  bool autoTts = false;

  /// Встроенный «Базовый поиск в интернете» для пресетов с поддержкой поиска.
  bool webSearchEnabled = true;

  /// Режим поиска в интернете: 'off', 'polza', 'sonar', 'deepseek'.
  String webSearchMode = 'off';

  /// Режим поиска (SearchMode): off, native, provider, modelAsTool,
  /// customApi. Хранится строкой (имя enum) в SharedPreferences.
  String searchMode = 'off';

  /// Ключ пользовательского поискового API (режим customApi).
  String customSearchApiKey = '';

  /// Модель-инструмент поиска (режим modelAsTool): идентификатор модели.
  String searchToolModel = '';

  /// Поддерживает ли активный провайдер серверный инструмент веб-поиска
  /// ('type': 'web_search'). Определяется лёгким probe-запросом при выборе
  /// режима «Провайдер» в настройках; true — инструмент добавляется
  /// в тело каждого запроса /chat/completions.
  bool webSearchSupported = false;

  /// Поддерживает ли активный провайдер поиск в режиме «Провайдер»
  /// (SearchMode.provider). Сохраняется в SharedPreferences под ключом
  /// 'isProviderSearchSupported'; определяется кнопкой «Проверить
  /// поддержку» в настройках поиска.
  bool providerSearchSupported = false;

  /// Уровень размышлений, который уйдёт в следующий POST (Reasoning
  /// Effort). Хранится строкой: значения и список допустимых приходят
  /// из каталога активной модели — здесь не хардкодятся.
  /// Для ненастроенной модели контроллер выставляет default_effort.
  String reasoningLevel = 'off';

  /// Выбор пользователя ПО КАЖДОЙ модели (id модели -> уровень).
  /// Используется, когда модель снова становится активной. Если записи
  /// нет, контроллер берёт default_effort каталога либо первый
  /// допустимый уровень.
  final Map<String, String> reasoningByModel = <String, String>{};

  /// Режим для профи (Advanced): полные настройки вместо быстрой настройки.
  bool advancedMode = true;

  /// Главный тумблер экрана «Коннекторы»: использовать ли MCP-серверы.
  /// По умолчанию включён — прежнее поведение не меняется.
  bool mcpEnabled = true;

  /// Размер шрифта вынесен отдельно, чтобы щипок не перестраивал всё приложение.
  final ValueNotifier<double> fontSizeN = ValueNotifier<double>(17);

  SharedPreferences? _prefs;

  Palette get palette =>
      palettes.firstWhere((x) => x.id == paletteId, orElse: () => palettes.first);

  /// Текущий идентификатор модели (активный пресет, иначе — настройки).
  String get currentModelId {
    final active = presets.active?.model.trim() ?? '';
    if (active.isNotEmpty) return active;
    return model.trim();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    apiKey = p.getString('apiKey') ?? apiKey;
    baseUrl = p.getString('baseUrl') ?? baseUrl;
    model = p.getString('model') ?? model;
    systemPrompt = p.getString('systemPrompt') ?? systemPrompt;
    paletteId = p.getString('paletteId') ?? paletteId;
    bodyFont = p.getString('bodyFont') ?? bodyFont;
    codeFont = p.getString('codeFont') ?? codeFont;
    lineHeight = p.getDouble('lineHeight') ?? lineHeight;
    fontSizeN.value = p.getDouble('fontSize') ?? 17;
    autoTts = p.getBool('autoTts') ?? false;
    showCost = p.getBool('showCost') ?? true;
    currency = p.getString('currency') ?? 'RUB';
    webSearchEnabled = p.getBool('webSearchEnabled') ?? true;
    webSearchMode = p.getString('webSearchMode') ?? 'off';
    final rawSearchMode = p.getString('searchMode') ?? 'off';
    searchMode = SearchModes.isKnownId(rawSearchMode) ? rawSearchMode : 'off';
    customSearchApiKey = p.getString('customSearchApiKey') ?? '';
    searchToolModel = p.getString('searchToolModel') ?? '';
    webSearchSupported = p.getBool('webSearchSupported') ?? false;
    providerSearchSupported =
        p.getBool('isProviderSearchSupported') ?? false;
    // Список допустимых усилий — только из каталога; здесь не валидируем,
    // сохраняем строку как есть (незнакомое значение уходит в запрос).
    reasoningLevel = p.getString('reasoningLevel') ?? 'off';
    final rawByModel = p.getString('reasoningByModel');
    if (rawByModel != null && rawByModel.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawByModel);
        if (decoded is Map) {
          reasoningByModel.clear();
          decoded.forEach((k, v) {
            if (v is String) {
              reasoningByModel[k.toString()] = v;
            }
          });
        }
      } catch (_) {
        // Битый JSON — оставляем пустую карту.
      }
    }
    advancedMode = p.getBool('advancedMode') ?? true;
    mcpEnabled = p.getBool('mcpEnabled') ?? true;
  }

  Future<void> _persist() async {
    final p = _prefs;
    if (p == null) return;
    await p.setString('apiKey', apiKey);
    await p.setString('baseUrl', baseUrl);
    await p.setString('model', model);
    await p.setString('systemPrompt', systemPrompt);
    await p.setString('paletteId', paletteId);
    await p.setString('bodyFont', bodyFont);
    await p.setString('codeFont', codeFont);
    await p.setDouble('lineHeight', lineHeight);
    await p.setDouble('fontSize', fontSizeN.value);
    await p.setBool('autoTts', autoTts);
    await p.setBool('showCost', showCost);
    await p.setString('currency', currency);
    await p.setBool('webSearchEnabled', webSearchEnabled);
    await p.setString('webSearchMode', webSearchMode);
    await p.setString('searchMode', searchMode);
    await p.setString('customSearchApiKey', customSearchApiKey);
    await p.setString('searchToolModel', searchToolModel);
    await p.setBool('webSearchSupported', webSearchSupported);
    await p.setBool('isProviderSearchSupported', providerSearchSupported);
    await p.setString('reasoningLevel', reasoningLevel);
    await p.setString('reasoningByModel', jsonEncode(reasoningByModel));
    await p.setBool('advancedMode', advancedMode);
    await p.setBool('mcpEnabled', mcpEnabled);
  }

  Future<void> saveNow() => _persist();

  void setConnection({String? key, String? url, String? mdl, String? sys}) {
    final keyChanged = key != null && key.trim() != apiKey.trim();
    final urlChanged = url != null && url.trim() != baseUrl.trim();
    if (key != null) apiKey = key;
    if (url != null) baseUrl = url;
    if (mdl != null) model = mdl;
    if (sys != null) systemPrompt = sys;
    // PresetStore — единственный владелец модели: если активного пресета нет
    // или активен системный дефолтный пресет, модель синхронизируется в него.
    if (mdl != null &&
        (presets.active == null ||
            presets.active?.id == PresetStore.defaultPresetId)) {
      presets.updateActivePresetModel(mdl);
    }
    _persist();
    notifyListeners();
    // Каталог моделей по подключению: сразу после ввода или смены ключа
    // (либо адреса) синхронизируем возможности и цены (force: true).
    // Смена одной только модели синхронизацию не запускает.
    if (keyChanged || urlChanged) {
      try {
        unawaited(providerCatalog.sync(
          CatalogConnection(
            id: 'global',
            baseUrl: baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
            apiKey: apiKey.trim(),
          ),
          force: true,
        ));
      } catch (_) {}
    }
  }

  void setPalette(String id) {
    paletteId = id;
    _persist();
    notifyListeners();
  }

  void setBodyFont(String f) {
    bodyFont = f;
    _persist();
    notifyListeners();
  }

  void setCodeFont(String f) {
    codeFont = f;
    _persist();
    notifyListeners();
  }

  void setLineHeight(double v) {
    lineHeight = v;
    notifyListeners();
  }

  void setFontSize(double v) {
    fontSizeN.value = v.clamp(11.0, 34.0).toDouble();
  }

  void setAutoTts(bool v) {
    autoTts = v;
    _persist();
    notifyListeners();
  }

  void setShowCost(bool v) {
    showCost = v;
    _persist();
    notifyListeners();
  }

  void setCurrency(String v) {
    currency = v;
    _persist();
    notifyListeners();
  }

  void setWebSearch(bool v) {
    webSearchEnabled = v;
    _persist();
    notifyListeners();
  }

  void setWebSearchMode(String v) {
    webSearchMode = v;
    _persist();
    notifyListeners();
  }

  void setSearchMode(String v) {
    if (!SearchModes.isKnownId(v)) return;
    searchMode = v;
    _persist();
    notifyListeners();
  }

  void setCustomSearchApiKey(String v) {
    customSearchApiKey = v;
    _persist();
  }

  void setSearchToolModel(String v) {
    searchToolModel = v;
    _persist();
  }

  void setWebSearchSupported(bool v) {
    webSearchSupported = v;
    _persist();
    notifyListeners();
  }

  void setProviderSearchSupported(bool v) {
    providerSearchSupported = v;
    _persist();
    notifyListeners();
  }

  /// Явный выбор пользователя: сохраняется по текущей модели, чтобы при
  /// возврате к ней применился снова. Значение не валидируется по
  /// захардкоженному списку — список усилий даёт каталог.
  void setReasoningLevel(String v) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) return;
    final model = currentModelId;
    if (model.isNotEmpty) {
      reasoningByModel[model] = trimmed;
    }
    reasoningLevel = trimmed;
    _persist();
    notifyListeners();
  }

  /// Вычисленный контроллером уровень для текущей модели — уходит в
  /// следующий POST. Per-model выбор не трогает: это «эффективное»
  /// значение, а не явный выбор пользователя.
  void applyReasoningLevel(String v) {
    final trimmed = v.trim();
    if (trimmed.isEmpty || reasoningLevel == trimmed) return;
    reasoningLevel = trimmed;
    _persist();
    notifyListeners();
  }

  /// Сохранённый пользователем уровень для конкретной модели, либо null.
  String? reasoningForModel(String modelId) {
    final key = modelId.trim();
    if (key.isEmpty) return null;
    return reasoningByModel[key];
  }

  void setAdvancedMode(bool v) {
    advancedMode = v;
    _persist();
    notifyListeners();
  }

  void setMcpEnabled(bool v) {
    mcpEnabled = v;
    _persist();
    notifyListeners();
  }
}

class ChatStore extends ChangeNotifier {
  final List<Chat> chats = [];
  Chat? current;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('chats');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        chats
          ..clear()
          ..addAll(list
              .map((e) => Chat.fromJson(Map<String, dynamic>.from(e as Map))));
        chats.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      } catch (_) {}
    }
    final cur = p.getString('currentChat');
    current = chats.where((c) => c.id == cur).firstOrNull;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'chats', jsonEncode(chats.map((c) => c.toJson()).toList()));
    await p.setString('currentChat', current?.id ?? '');
  }

  Chat createChat() {
    final c = Chat(id: newId());
    chats.insert(0, c);
    current = c;
    notifyListeners();
    return c;
  }

  void open(Chat c) {
    current = c;
    notifyListeners();
    save();
  }

  void startNew() {
    current = null;
    notifyListeners();
    save();
  }

  void touch(Chat c) {
    c.updatedAt = DateTime.now();
    chats.remove(c);
    chats.insert(0, c);
    notifyListeners();
  }

  Future<void> delete(Chat c) async {
    chats.remove(c);
    if (current == c) current = null;
    notifyListeners();
    await save();
  }
}
