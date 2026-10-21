import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'theme.dart';

final AppSettings settings = AppSettings();
final ChatStore store = ChatStore();

String newId() => DateTime.now().microsecondsSinceEpoch.toString();

class AppSettings extends ChangeNotifier {
  String apiKey = '';
  String baseUrl = 'https://api.deepseek.com';
  String model = 'deepseek-chat';
  String systemPrompt = '';
  String paletteId = 'light';
  String bodyFont = 'Literata';
  String codeFont = 'JetBrains Mono';
  double lineHeight = 1.55;

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
