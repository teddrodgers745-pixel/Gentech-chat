// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/storage.dart';
import '../../models/tool.dart';
import '../../theme.dart';
import 'tool_edit_screen.dart';

/// Реестр инструментов: список, добавление, редактирование, удаление.
/// Вызов инструментов из чата будет добавлен на следующем этапе.
class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  List<Tool> _tools = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await storage.getTools();
    if (!mounted) return;
    setState(() => _tools = list);
  }

  Future<void> _openEditor({Tool? existing}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ToolEditScreen(existing: existing)),
    );
    if (mounted) _load();
  }

  Future<void> _confirmDelete(Tool t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить инструмент?'),
        content: Text(t.name, maxLines: 2, overflow: TextOverflow.ellipsis),
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
      _tools.removeWhere((x) => x.id == t.id);
      await storage.setTools(_tools);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    return Scaffold(
      appBar: AppBar(title: const Text('Инструменты')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _tools.isEmpty
                  ? _empty(p)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: _tools.length,
                      itemBuilder: (context, i) => _tile(_tools[i], p),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _openEditor(),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить инструмент'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Tool t, Palette p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        leading: Icon(
          t.isModel ? Icons.auto_awesome : Icons.build_outlined,
          color: p.accent,
        ),
        title: Text(
          t.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w600, color: p.text),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (t.description.trim().isNotEmpty)
              Text(
                t.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            const SizedBox(height: 2),
            Text(
              t.isModel
                  ? 'Модель · ${t.modelId.trim().isEmpty ? t.baseUrl.trim() : t.modelId.trim()}'
                  : '${t.method.toUpperCase()} · ${t.endpoint}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.transparent,
                fontSize: 11,
                fontFamily: 'JetBrains Mono',
                fontFamilyFallback: ['monospace'],
              ),
            ),
          ],
        ),
        trailing: IconButton(
          tooltip: 'Удалить',
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: () => _confirmDelete(t),
        ),
        onTap: () => _openEditor(existing: t),
      ),
    );
  }

  Widget _empty(Palette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.build_outlined, size: 36, color: p.accent),
            const SizedBox(height: 16),
            Text(
              'Инструментов пока нет',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Инструмент — внешний HTTP-эндпоинт, который модель сможет вызывать. Добавьте первый инструмент кнопкой ниже.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

