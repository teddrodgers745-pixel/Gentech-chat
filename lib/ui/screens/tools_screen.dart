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
        content: Text(
          _displayTitle(t),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
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

  /// В существующих записях префикс может быть в имени, а не в id.
  bool _isMcp(Tool t) =>
      t.id.startsWith('mcp_') || t.name.startsWith('mcp_');

  /// Название для отображения: убираем префикс 'mcp_' и заменяем
  /// подчёркивания пробелами, каждое слово — с заглавной буквы.
  /// Например, 'mcp_Parallel_Search_web_search' -> 'Parallel Search Web Search'.
  String _displayTitle(Tool t) {
    var s = t.name;
    if (s.startsWith('mcp_')) s = s.substring(4);
    s = s.replaceAll('_', ' ').trim();
    if (s.isEmpty) return t.name;
    return s
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  /// Перевод только для отображения: исходный текст остаётся в хранилище
  /// и передаётся модели без изменений.
  String _displaySubtitle(Tool t) {
    var s = t.description.trim();
    const purpose = 'Purpose:';
    if (s.toLowerCase().startsWith(purpose.toLowerCase())) {
      s = s.substring(purpose.length).trim();
    }
    if (!_isMcp(t) || s.isEmpty ||
        RegExp(r'[А-Яа-яЁё]').hasMatch(s) ||
        !RegExp(r'[A-Za-z]').hasMatch(s)) {
      return s;
    }

    final lower = s.toLowerCase();
    bool has(String pattern) => RegExp(pattern).hasMatch(lower);
    final search = has(r'\b(search\w*|find\w*|lookup|look up)\b');
    final fetch = has(r'\b(fetch\w*|read\w*|retriev\w*|extract\w*|scrap\w*|crawl\w*)\b');
    if (search && has(r'\b(web|internet|online)\b')) {
      return fetch
          ? 'Выполняет поиск в интернете и получает содержимое.'
          : 'Выполняет поиск в интернете.';
    }
    if (search) return 'Выполняет поиск по запросу.';
    if (fetch) return 'Получает и читает содержимое по запросу.';
    if (has(r'\b(list\w*)\b')) return 'Показывает список доступных данных.';
    if (has(r'\b(calculat\w*|comput\w*)\b')) {
      return 'Выполняет вычисления по запросу.';
    }
    if (has(r'\b(analy[sz]\w*)\b')) return 'Анализирует данные по запросу.';
    if (has(r'\b(creat\w*|generat\w*)\b')) {
      return 'Создаёт данные по запросу.';
    }
    if (has(r'\b(updat\w*|edit\w*|modif\w*)\b')) {
      return 'Изменяет данные по запросу.';
    }
    if (has(r'\b(delet\w*|remov\w*)\b')) {
      return 'Удаляет данные по запросу.';
    }
    return 'Инструмент MCP. Удерживайте описание, чтобы увидеть оригинал.';
  }

  Widget _tile(Tool t, Palette p) {
    final mcp = _isMcp(t);
    final subtitle = _displaySubtitle(t);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: mcp ? p.accent.withValues(alpha: 0.35) : p.border,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
        leading: Icon(
          mcp
              ? Icons.extension
              : (t.isModel ? Icons.auto_awesome : Icons.build_outlined),
          color: p.accent,
          size: 20,
        ),
        title: Text(
          _displayTitle(t),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w600, color: p.text),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mcp) ...[
              const SizedBox(height: 2),
              Text(
                'MCP-КОННЕКТОР',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.accent,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ],
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Tooltip(
                message: mcp ? t.description : '',
                child: Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 12, height: 1.35),
                ),
              ),
            ],
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

