// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';

/// Секция «ПОДКЛЮЧЕНИЕ (ГЛОБАЛЬНОЕ)» в настройках: Base URL, API-ключ
/// и модель по умолчанию. Используются, когда не выбран ни один пресет.
/// Значения хранятся в SharedPreferences (ключи baseUrl/apiKey/model),
/// поэтому старые данные пользователя сохраняются при обновлении.
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

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ПОДКЛЮЧЕНИЕ (ГЛОБАЛЬНОЕ)',
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
            hintText: 'Идентификатор модели',
          ),
        ),
      ],
    );
  }
}
