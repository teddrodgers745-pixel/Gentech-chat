// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';

/// Быстрая настройка: подключение к провайдеру за три шага —
/// ключ, загрузка списка моделей, выбор модели и старт.
/// Источник один; адрес, ключ и модель можно изменить вручную.
class QuickSetupScreen extends StatefulWidget {
  const QuickSetupScreen({super.key});

  @override
  State<QuickSetupScreen> createState() => _QuickSetupScreenState();
}

class _QuickSetupScreenState extends State<QuickSetupScreen> {
  static const String _sourceName = 'Polza AI';
  static const String _providerId = 'polza';
  static const String _defaultBaseUrl = 'https://api.polza.ai/v1';

  late final TextEditingController _key;
  late final TextEditingController _baseUrl;
  bool _showKey = false;
  bool _loading = false;
  String? _error;
  List<String> _models = const <String>[];
  String? _selected;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController();
    _baseUrl = TextEditingController(text: _defaultBaseUrl);
  }

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _section(Palette p, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: p.accent,
        ),
      ),
    );
  }

  String _trimBase() =>
      _baseUrl.text.trim().replaceAll(RegExp(r'/+$'), '');

  bool _validBase(String base) {
    final uri = Uri.tryParse(base);
    return base.isNotEmpty &&
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  // ---------- загрузка моделей ----------

  Future<void> _loadModels() async {
    if (_loading) return;
    final key = _key.text.trim();
    final base = _trimBase();
    if (key.isEmpty) {
      _snack('Введите API-ключ');
      return;
    }
    if (!_validBase(base)) {
      _snack('Base URL должен начинаться с http:// или https://');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http
          .get(
            Uri.parse('$base/models'),
            headers: const <String, String>{
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 30));
      // Ключ передаётся отдельно, чтобы не попадал в строки ошибок логов.
      final authed = await _getWithAuth('$base/models', key);
      if (!mounted) return;
      if (authed.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = _describe(authed.statusCode);
        });
        return;
      }
      final models = _parseModels(authed.body);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (models.isEmpty) {
          _error = 'Сервер не вернул ни одной модели.';
        } else {
          _models = models;
          _selected =
              _models.contains(_selected) ? _selected : _models.first;
        }
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Сервер не ответил за 30 секунд.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить модели: проверьте ключ, адрес и сеть.';
      });
    }
  }

  Future<http.Response> _getWithAuth(String url, String key) {
    return http
        .get(
          Uri.parse(url),
          headers: <String, String>{'Authorization': 'Bearer $key'},
        )
        .timeout(const Duration(seconds: 30));
  }

  String _describe(int code) {
    switch (code) {
      case 401:
        return 'Неверный API-ключ (401). Проверьте ключ.';
      case 429:
        return 'Слишком много запросов (429). Подождите немного.';
    }
    return 'Ошибка $code. Проверьте ключ и адрес.';
  }

  /// Разбор ответа /models: список id из поля data, без дубликатов, по алфавиту.
  static List<String> _parseModels(String body) {
    final out = <String>{};
    try {
      final j = jsonDecode(body);
      if (j is Map && j['data'] is List) {
        for (final e in (j['data'] as List)) {
          if (e is Map) {
            final id = e['id'];
            if (id is String && id.trim().isNotEmpty) out.add(id.trim());
          } else if (e is String && e.trim().isNotEmpty) {
            out.add(e.trim());
          }
        }
      }
    } catch (_) {}
    final list = out.toList()..sort();
    return list;
  }

  // ---------- старт ----------

  Future<void> _start() async {
    final key = _key.text.trim();
    final base = _trimBase();
    final model = _selected;
    if (key.isEmpty) {
      _snack('Введите API-ключ');
      return;
    }
    if (!_validBase(base)) {
      _snack('Base URL должен начинаться с http:// или https://');
      return;
    }
    if (model == null || model.isEmpty) {
      _snack('Сначала загрузите и выберите модель');
      return;
    }
    final preset = Preset(
      id: newId(),
      name: _sourceName,
      providerId: _providerId,
      baseUrl: base,
      apiKey: key,
      model: model,
      stream: true,
    );
    await presets.upsert(preset);
    await presets.setActive(preset.id);
    await settings.saveNow();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ---------- интерфейс ----------

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    return Scaffold(
      appBar: AppBar(title: const Text('Быстрая настройка')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _section(p, 'ИСТОЧНИК'),
            _sourceCard(p),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrl,
              autocorrect: false,
              keyboardType: TextInputType.url,
              cursorColor: p.accent,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.example.com/v1',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              cursorColor: p.accent,
              decoration: InputDecoration(
                labelText: 'API-ключ',
                suffixIcon: IconButton(
                  icon: Icon(
                    _showKey ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Базовый поиск в интернете'),
              subtitle: Text(
                'Модель сможет искать актуальную информацию в сети',
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
              value: settings.webSearchEnabled,
              onChanged: (v) => settings.setWebSearch(v),
            ),
            _section(p, 'МОДЕЛЬ'),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              OutlinedButton.icon(
                onPressed: _loadModels,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Загрузить модели'),
              ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ],
            if (_models.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _selected,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Модель',
                ),
                items: [
                  for (final m in _models)
                    DropdownMenuItem<String>(
                      value: m,
                      child: Text(
                        m,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _selected = v),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Начать работу'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceCard(Palette p) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.accent.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.auto_awesome, size: 22, color: p.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _sourceName,
                  style: fontStyle(
                    settings.bodyFont,
                    size: 16,
                    weight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'OpenAI-совместимый API',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          Icon(Icons.check_circle_rounded, color: p.accent, size: 22),
        ],
      ),
    );
  }
}
