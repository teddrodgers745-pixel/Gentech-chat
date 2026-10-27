// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app_state.dart';

/// Секция «ПОДКЛЮЧЕНИЕ» в настройках: Base URL, API-ключ и модель
/// по умолчанию. Используются, когда не выбран ни один пресет.
/// Значения хранятся в SharedPreferences (ключи baseUrl/apiKey/model),
/// поэтому старые данные пользователя сохраняются при обновлении.
/// Поля Base URL и Модель по умолчанию пустые: адрес и модель вводит
/// пользователь, подсказки показаны в hintText.
/// Кнопка «Загрузить модели» запрашивает {Base URL}/models и предлагает
/// полученный список в выпадающем списке.
class GlobalConnectionSection extends StatefulWidget {
  const GlobalConnectionSection({super.key});

  @override
  State<GlobalConnectionSection> createState() =>
      _GlobalConnectionSectionState();
}

class _GlobalConnectionSectionState extends State<GlobalConnectionSection> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _showKey = false;
  bool _loadingModels = false;
  String? _modelsError;
  List<String> _models = const <String>[];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: settings.baseUrl);
    _key = TextEditingController(text: settings.apiKey);
    _model = TextEditingController(text: settings.model);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  /// Сохраняем с небольшой задержкой, чтобы не писать в хранилище
  /// на каждом нажатии клавиши.
  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      settings.setConnection(
        key: _key.text,
        url: _url.text,
        mdl: _model.text,
      );
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  /// GET {Base URL}/models с Authorization из поля «API-ключ».
  Future<void> _loadModels() async {
    if (_loadingModels) return;
    final base = _url.text.trim().replaceAll(RegExp(r'/+$'), '');
    final key = _key.text.trim();
    if (base.isEmpty ||
        !(base.startsWith('http://') || base.startsWith('https://'))) {
      _snack('Base URL должен начинаться с http:// или https://');
      return;
    }
    if (key.isEmpty) {
      _snack('Введите API-ключ');
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final resp = await http
          .get(
            Uri.parse('$base/models'),
            headers: <String, String>{'Authorization': 'Bearer $key'},
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (resp.statusCode != 200) {
        setState(() {
          _loadingModels = false;
          _modelsError =
              'Ошибка ${resp.statusCode}. Проверьте ключ и адрес.';
        });
        return;
      }
      final ids = <String>{};
      try {
        final j = jsonDecode(resp.body);
        if (j is Map && j['data'] is List) {
          for (final e in (j['data'] as List)) {
            String? id;
            if (e is Map) {
              final v = e['id'] ?? e['name'];
              if (v is String && v.trim().isNotEmpty) id = v.trim();
            } else if (e is String && e.trim().isNotEmpty) {
              id = e.trim();
            }
            if (id != null) ids.add(id);
          }
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _models = ids.toList()..sort();
        if (_models.isEmpty) {
          _modelsError = 'Сервер не вернул ни одной модели.';
        }
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _modelsError = 'Сервер не ответил за 30 секунд.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _modelsError =
            'Не удалось загрузить модели: проверьте адрес и сеть.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    final currentModel = _model.text.trim();
    final dropdownValue =
        _models.contains(currentModel) ? currentModel : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ПОДКЛЮЧЕНИЕ',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: p.accent,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Используется, когда не выбран ни один пресет.',
          style: TextStyle(color: p.muted, fontSize: 13),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _url,
          autocorrect: false,
          keyboardType: TextInputType.url,
          cursorColor: p.accent,
          onChanged: (_) => _changed(),
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.polza.ai/v1',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          obscureText: !_showKey,
          autocorrect: false,
          enableSuggestions: false,
          cursorColor: p.accent,
          onChanged: (_) => _changed(),
          decoration: InputDecoration(
            labelText: 'API-ключ',
            suffixIcon: IconButton(
              tooltip: _showKey ? 'Скрыть ключ' : 'Показать ключ',
              icon: Icon(
                _showKey ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _model,
          autocorrect: false,
          cursorColor: p.accent,
          onChanged: (_) => _changed(),
          decoration: const InputDecoration(
            labelText: 'Модель',
            hintText: 'ID модели',
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _loadingModels ? null : _loadModels,
          icon: _loadingModels
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_download, size: 18),
          label: const Text('Загрузить модели'),
        ),
        if (_modelsError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _modelsError!,
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ),
        if (_models.isNotEmpty) ...[
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            value: dropdownValue,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Выберите модель',
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
            onChanged: (v) {
              if (v == null) return;
              _model.text = v;
              _model.selection = TextSelection.collapsed(offset: v.length);
              _changed();
              setState(() {});
            },
          ),
        ],
      ],
    );
  }
}
