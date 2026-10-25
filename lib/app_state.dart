// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/storage.dart';
import 'models.dart';
import 'theme.dart';

final AppSettings settings = AppSettings();
final ChatStore store = ChatStore();
final PresetStore presets = PresetStore();

String newId() => DateTime.now().microsecondsSinceEpoch.toString();

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

/// Активный пресет имеет приоритет; если он не выбран —
/// работают прежние настройки (совместимость со старыми данными).
EffectiveConfig effectiveConfig() {
  final pr = presets.active;
  if (pr != null) {
    return EffectiveConfig(
      baseUrl: pr.baseUrl.trim(),
      apiKey: pr.apiKey.trim(),
      model: pr.model.trim(),
      systemPrompt: pr.systemPrompt,
      stream: pr.stream,
      temperature: pr.temperature,
    );
  }
  return EffectiveConfig(
    baseUrl: settings.baseUrl.trim(),
    apiKey: settings.apiKey.trim(),
    model: settings.model.trim(),
    systemPrompt: settings.systemPrompt,
    stream: true,
    temperature: null,
  );
}

class PresetStore extends ChangeNotifier {
  final List<Preset> _items = [];
  String _activeId = '';

  List<Preset> get items => List.unmodifiable(_items);

  Preset? get active {
    for (final p in _items) {
      if (p.id == _activeId) return p;
    }
    return null;
  }

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

  Future<void> remove(String id) async {
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
  String baseUrl = 'https://api.deepseek.com';
  String model = 'deepseek-chat';
  String systemPrompt = '';
  String paletteId = 'light';
  String bodyFont = 'Literata';
  String codeFont = 'JetBrains Mono';
  double lineHeight = 1.55;

  /// Автоозвучка новых ответов модели (TTS), по умолчанию выключена.
  bool autoTts = false;

  /// Встроенный «Базовый поиск в интернете» для пресетов с поддержкой поиска.
  bool webSearchEnabled = true;

  /// Режим для профи (Advanced): полные настройки вместо быстрой настройки.
  bool advancedMode = true;

  /// Размер шрифта вынесен отдельно, чтобы щипок не перестраивал всё приложение.
  final ValueNotifier<double> fontSizeN = ValueNotifier<double>(17);

  SharedPreferences? _prefs;

  Palette get palette =>
      palettes.firstWhere((x) => x.id == paletteId, orElse: () => palettes.first);

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
    webSearchEnabled = p.getBool('webSearchEnabled') ?? true;
    advancedMode = p.getBool('advancedMode') ?? true;
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
    await p.setBool('webSearchEnabled', webSearchEnabled);
    await p.setBool('advancedMode', advancedMode);
  }

  Future<void> saveNow() => _persist();

  void setConnection({String? key, String? url, String? mdl, String? sys}) {
    if (key != null) apiKey = key;
    if (url != null) baseUrl = url;
    if (mdl != null) model = mdl;
    if (sys != null) systemPrompt = sys;
    _persist();
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

  void setWebSearch(bool v) {
    webSearchEnabled = v;
    _persist();
    notifyListeners();
  }

  void setAdvancedMode(bool v) {
    advancedMode = v;
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
