// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';

/// Экран создания/редактирования пресета:
/// название, Base URL, API-ключ, модель, системный промпт, стриминг.
class PresetEditScreen extends StatefulWidget {
  final Preset? existing;

  const PresetEditScreen({super.key, this.existing});

  @override
  State<PresetEditScreen> createState() => _PresetEditScreenState();
}

class _PresetEditScreenState extends State<PresetEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _sys;
  bool _stream = true;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _url = TextEditingController(text: e?.baseUrl ?? '');
    _key = TextEditingController(text: e?.apiKey ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _sys = TextEditingController(text: e?.systemPrompt ?? '');
    _stream = e?.stream ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _sys.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('Введите название пресета');
      return;
    }
    final preset = Preset(
      id: widget.existing?.id ?? newId(),
      name: name,
      providerId: widget.existing?.providerId ?? '',
      baseUrl: _url.text.trim(),
      apiKey: _key.text.trim(),
      model: _model.text.trim(),
      stream: _stream,
      temperature: widget.existing?.temperature ?? 1.0,
      systemPrompt: _sys.text,
    );
    await presets.upsert(preset);
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить пресет?'),
        content: Text(existing.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      await presets.remove(existing.id);
      if (!mounted) return;
      Navigator.pop(context);
    }
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

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    final isNew = widget.existing == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Создать пресет' : 'Изменить пресет'),
        actions: [
          IconButton(
            tooltip: 'Сохранить',
            icon: const Icon(Icons.check_rounded),
            onPressed: _save,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              cursorColor: p.accent,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            _section(p, 'ПОДКЛЮЧЕНИЕ'),
            TextField(
              controller: _url,
              autocorrect: false,
              keyboardType: TextInputType.url,
              cursorColor: p.accent,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.example.com',
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
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              autocorrect: false,
              cursorColor: p.accent,
              decoration: const InputDecoration(
                labelText: 'Модель',
                hintText: 'Название модели',
              ),
            ),
            _section(p, 'ПОВЕДЕНИЕ'),
            TextField(
              controller: _sys,
              minLines: 2,
              maxLines: 6,
              cursorColor: p.accent,
              decoration: const InputDecoration(
                labelText: 'Системный промпт (необязательно)',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: p.accent,
              title: const Text('Потоковый вывод (SSE)'),
              subtitle: Text(
                'Ответ появляется по мере генерации',
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
              value: _stream,
              onChanged: (v) => setState(() => _stream = v),
            ),
            if (!isNew) ...[
              const SizedBox(height: 16),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: p.accent),
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline, size: 20),
                label: const Text('Удалить пресет'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
