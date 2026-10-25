// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/storage.dart';
import '../../models/tool.dart';
import '../../theme.dart';

/// Форма создания/редактирования инструмента:
/// название, описание, URL, метод, заголовки (JSON), схема параметров (JSON).
class ToolEditScreen extends StatefulWidget {
  final Tool? existing;

  const ToolEditScreen({super.key, this.existing});

  @override
  State<ToolEditScreen> createState() => _ToolEditScreenState();
}

class _ToolEditScreenState extends State<ToolEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _url;
  late final TextEditingController _headers;
  late final TextEditingController _schema;
  String _method = 'POST';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _desc = TextEditingController(text: e?.description ?? '');
    _url = TextEditingController(text: e?.endpoint ?? '');
    _method = (e?.method.toUpperCase() == 'GET') ? 'GET' : 'POST';
    _headers = TextEditingController(
      text: _pretty(e?.headers ?? const <String, String>{}),
    );
    _schema = TextEditingController(text: e?.parametersSchema ?? '');
  }

  static String _pretty(Map<String, String> headers) {
    if (headers.isEmpty) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(headers);
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _url.dispose();
    _headers.dispose();
    _schema.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('Введите название инструмента');
      return;
    }
    final url = _url.text.trim();
    final uri = Uri.tryParse(url);
    if (url.isEmpty ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _snack('URL должен начинаться с http:// или https://');
      return;
    }
    Map<String, String> headers = {};
    final hText = _headers.text.trim();
    if (hText.isNotEmpty) {
      try {
        final decoded = jsonDecode(hText);
        if (decoded is! Map) throw const FormatException('not a map');
        headers = decoded.map<String, String>(
          (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
        );
      } catch (_) {
        _snack('Заголовки: неверный JSON (нужен объект вида {"Ключ": "значение"})');
        return;
      }
    }
    final sText = _schema.text.trim();
    String schema = '';
    if (sText.isNotEmpty) {
      try {
        jsonDecode(sText);
        schema = sText;
      } catch (_) {
        _snack('Схема параметров: неверный JSON');
        return;
      }
    }
    final tool = Tool(
      id: widget.existing?.id ?? newId(),
      name: name,
      description: _desc.text.trim(),
      endpoint: url,
      method: _method,
      headers: headers,
      parametersSchema: schema,
    );
    final list = await storage.getTools();
    final i = list.indexWhere((x) => x.id == tool.id);
    if (i >= 0) {
      list[i] = tool;
    } else {
      list.add(tool);
    }
    await storage.setTools(list);
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить инструмент?'),
        content:
            Text(existing.name, maxLines: 2, overflow: TextOverflow.ellipsis),
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
      final list = await storage.getTools();
      list.removeWhere((x) => x.id == existing.id);
      await storage.setTools(list);
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
        title: Text(isNew ? 'Новый инструмент' : 'Изменить инструмент'),
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
            const SizedBox(height: 12),
            TextField(
              controller: _desc,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              cursorColor: p.accent,
              decoration: const InputDecoration(
                labelText: 'Описание',
                hintText: 'Что делает этот инструмент',
              ),
            ),
            _section(p, 'ЭНДПОИНТ'),
            TextField(
              controller: _url,
              autocorrect: false,
              keyboardType: TextInputType.url,
              cursorColor: p.accent,
              decoration: const InputDecoration(
                labelText: 'URL эндпоинта',
                hintText: 'https://example.com/api/action',
              ),
            ),
            const SizedBox(height: 12),
            Text('Метод запроса', style: TextStyle(color: p.muted, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final m in const ['GET', 'POST'])
                  ChoiceChip(
                    label: Text(m),
                    selected: _method == m,
                    onSelected: (_) => setState(() => _method = m),
                  ),
              ],
            ),
            _section(p, 'ДАННЫЕ'),
            TextField(
              controller: _headers,
              minLines: 2,
              maxLines: 6,
              autocorrect: false,
              cursorColor: p.accent,
              decoration: const InputDecoration(
                labelText: 'Заголовки (JSON)',
                hintText: '{"Content-Type": "application/json"}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _schema,
              minLines: 4,
              maxLines: 10,
              autocorrect: false,
              cursorColor: p.accent,
              decoration: const InputDecoration(
                labelText: 'Схема параметров (JSON)',
                hintText: '{"type": "object", "properties": {}}',
              ),
            ),
            if (!isNew) ...[
              const SizedBox(height: 16),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: p.accent),
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline, size: 20),
                label: const Text('Удалить инструмент'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

