// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/storage.dart';
import '../../models/mcp_server.dart';
import '../../models/tool.dart';
import '../../services/mcp_client.dart';
import '../../theme.dart';

/// Экран управления MCP-серверами: список, добавление, редактирование
/// и удаление. Проверка подключения появится на следующем этапе.
class McpScreen extends StatefulWidget {
  const McpScreen({super.key});

  @override
  State<McpScreen> createState() => _McpScreenState();
}

class _McpScreenState extends State<McpScreen> {
  List<McpServer> _servers = [];

  /// id серверов, для которых идёт загрузка инструментов.
  final Set<String> _loading = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await storage.getMcpServers();
    if (!mounted) return;
    setState(() => _servers = list);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  static void _disposeControllers(List<TextEditingController> list) {
    for (final c in list) {
      c.dispose();
    }
  }

  Future<void> _openDialog({McpServer? existing}) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final url = TextEditingController(text: existing?.url ?? '');
    final token = TextEditingController(text: existing?.token ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Добавить сервер' : 'Изменить сервер'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'http://127.0.0.1:8080',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Токен (необязательно)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (saved != true) {
      _disposeControllers([name, url, token]);
      return;
    }
    if (!mounted) {
      _disposeControllers([name, url, token]);
      return;
    }

    final n = name.text.trim();
    final u = url.text.trim();
    final uri = Uri.tryParse(u);
    if (n.isEmpty) {
      _disposeControllers([name, url, token]);
      _snack('Введите название сервера');
      return;
    }
    if (u.isEmpty ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _disposeControllers([name, url, token]);
      _snack('URL должен начинаться с http:// или https://');
      return;
    }

    final server = McpServer(
      id: existing?.id ?? newId(),
      name: n,
      url: u,
      token: token.text.trim(),
    );
    _disposeControllers([name, url, token]);

    final list = await storage.getMcpServers();
    final i = list.indexWhere((x) => x.id == server.id);
    if (i >= 0) {
      list[i] = server;
    } else {
      list.add(server);
    }
    await storage.setMcpServers(list);
    if (!mounted) return;
    await _load();
  }

  Future<void> _confirmDelete(McpServer s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сервер?'),
        content: Text(s.name, maxLines: 2, overflow: TextOverflow.ellipsis),
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
      final list = await storage.getMcpServers();
      list.removeWhere((x) => x.id == s.id);
      await storage.setMcpServers(list);
      if (!mounted) return;
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    return Scaffold(
      appBar: AppBar(title: const Text('MCP-серверы')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _servers.isEmpty
                  ? _empty(p)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: _servers.length,
                      itemBuilder: (context, i) => _tile(_servers[i], p),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _openDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить сервер'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(McpServer s, Palette p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
            leading: Icon(Icons.dns_outlined, color: p.accent),
            title: Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w600, color: p.text),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  s.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontFamilyFallback: const ['monospace'],
                    fontSize: 12,
                    color: p.muted,
                  ),
                ),
                Text(
                  s.token.isEmpty ? 'Без токена' : 'Токен сохранён',
                  style: TextStyle(color: p.muted, fontSize: 11),
                ),
              ],
            ),
            trailing: IconButton(
              tooltip: 'Удалить',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _confirmDelete(s),
            ),
            onTap: () => _openDialog(existing: s),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _loading.contains(s.id)
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton.icon(
                      onPressed: () => _fetchTools(s),
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('Загрузить инструменты'),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Загружает инструменты сервера через MCP-клиент и сохраняет их
  /// в общем хранилище инструментов (ключ 'tools') с префиксом сервера.
  Future<void> _fetchTools(McpServer s) async {
    if (_loading.contains(s.id)) return;
    setState(() => _loading.add(s.id));

    List<Tool> fetched;
    try {
      fetched = await McpClient().fetchTools(s);
    } on McpClientException catch (e) {
      if (mounted) {
        setState(() => _loading.remove(s.id));
        _snack(e.message);
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() => _loading.remove(s.id));
        _snack('Не удалось соединиться с сервером. Проверьте адрес и сеть.');
      }
      return;
    }

    final prefix = 'mcp_${_sanitize(s.name)}_';
    var saved = true;
    try {
      final all = await storage.getTools();
      // Старые инструменты этого сервера заменяем свежим списком.
      all.removeWhere((t) => t.name.startsWith(prefix));
      for (final t in fetched) {
        t.name = '$prefix${_sanitize(t.name)}';
        all.add(t);
      }
      saved = await storage.setTools(all);
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    setState(() => _loading.remove(s.id));
    if (saved) {
      _snack('Загружено инструментов: ${fetched.length}');
    } else {
      _snack('Не удалось сохранить инструменты.');
    }
  }

  /// Допустимые символы имени функции: латиница, цифры, '_' и '-'.
  static String _sanitize(String raw) {
    final s = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return s.isEmpty ? 'tool' : s;
  }

  Widget _empty(Palette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 36, color: p.accent),
            const SizedBox(height: 16),
            Text(
              'Серверов пока нет',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'MCP-сервер расширяет возможности модели дополнительными инструментами. Добавьте первый сервер кнопкой ниже.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
