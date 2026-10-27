// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/storage.dart';
import '../../models/mcp_server.dart';
import '../../models/tool.dart';
import '../../services/mcp_client.dart';
import '../../theme.dart';

/// Экран управления MCP-серверами: список, добавление, редактирование
/// и удаление. Готовый коннектор подключается одной кнопкой: сервер
/// сохраняется, затем сразу загружаются его инструменты.
class McpScreen extends StatefulWidget {
  const McpScreen({super.key});

  @override
  State<McpScreen> createState() => _McpScreenState();
}

/// Готовый коннектор из каталога: добавляется одной кнопкой, без ключа.
class _CatalogItem {
  final String name;
  final String url;
  final String description;
  const _CatalogItem(this.name, this.url, this.description);
}

class _McpScreenState extends State<McpScreen> {
  /// Каталог готовых коннекторов (MCP), доступных без ключа.
  static const List<_CatalogItem> _catalog = [
    _CatalogItem('Parallel Search', 'https://search.parallel.ai/mcp',
        'Поиск в интернете · без ключа'),
    _CatalogItem('DeepWiki', 'https://mcp.deepwiki.com/mcp',
        'Вики и документация репозиториев · без ключа'),
    _CatalogItem('Firecrawl', 'https://mcp.firecrawl.dev/mcp',
        'Извлечение и обход веб-страниц · без ключа'),
    _CatalogItem('Exa', 'https://mcp.exa.ai/mcp',
        'Семантический поиск в интернете · без ключа'),
    _CatalogItem('Tavily', 'https://mcp.tavily.com/mcp',
        'Поиск актуальной информации · без ключа'),
  ];

  List<McpServer> _servers = [];

  /// id серверов, для которых идёт загрузка инструментов.
  final Set<String> _loading = <String>{};

  /// URL готовых коннекторов, которые сейчас подключаются.
  final Set<String> _catalogLoading = <String>{};

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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                children: [
                  _catalogSection(p),
                  const SizedBox(height: 16),
                  if (_servers.isEmpty)
                    _empty(p)
                  else
                    for (final s in _servers) _tile(s, p),
                ],
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

  /// Секция готовых коннекторов: карточки с кнопкой «Добавить».
  Widget _catalogSection(Palette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'ГОТОВЫЕ КОННЕКТОРЫ',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: p.accent,
          ),
        ),
        const SizedBox(height: 10),
        for (final c in _catalog) _catalogTile(c, p),
      ],
    );
  }

  Widget _catalogTile(_CatalogItem c, Palette p) {
    final added = _servers.any((x) => x.url.trim() == c.url);
    final busy = _catalogLoading.contains(c.url);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w600, color: p.text),
                ),
                const SizedBox(height: 2),
                Text(
                  c.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  c.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontFamilyFallback: const ['monospace'],
                    fontSize: 11,
                    color: p.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            _busyButton(p)
          else if (added)
            Icon(Icons.check_circle_rounded, color: p.accent, size: 22)
          else
            TextButton(
              onPressed: () => _addFromCatalog(c),
              child: const Text('Добавить'),
            ),
        ],
      ),
    );
  }

  /// Кнопка в состоянии загрузки: индикатор вместо надписи.
  Widget _busyButton(Palette p) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  /// Подключение готового коннектора одним нажатием (без ключа):
  /// сервер сохраняется в Storage, затем сразу загружаются его инструменты.
  /// Дополнительных нажатий пользователю делать не нужно.
  Future<void> _addFromCatalog(_CatalogItem c) async {
    if (_catalogLoading.contains(c.url)) return;
    final list = await storage.getMcpServers();
    if (list.any((x) => x.url.trim() == c.url)) {
      _snack('Коннектор «${c.name}» уже добавлен');
      return;
    }

    final server = McpServer(id: newId(), name: c.name, url: c.url);
    list.add(server);
    await storage.setMcpServers(list);
    if (!mounted) return;
    setState(() {
      _catalogLoading.add(c.url);
      _servers = list;
    });

    List<Tool> fetched;
    try {
      fetched = await McpClient().fetchTools(server);
    } on McpClientException catch (e) {
      if (!mounted) return;
      setState(() => _catalogLoading.remove(c.url));
      _snack('Ошибка подключения: ${e.message}');
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _catalogLoading.remove(c.url));
      _snack('Ошибка подключения: не удалось соединиться с сервером');
      return;
    }

    final saved = await _saveTools(server, fetched);
    if (!mounted) return;
    setState(() => _catalogLoading.remove(c.url));
    if (saved) {
      _snack('Инструменты загружены');
    } else {
      _snack('Ошибка подключения: не удалось сохранить инструменты');
    }
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

    final saved = await _saveTools(s, fetched);
    if (!mounted) return;
    setState(() => _loading.remove(s.id));
    if (saved) {
      _snack('Загружено инструментов: ${fetched.length}');
    } else {
      _snack('Не удалось сохранить инструменты.');
    }
  }

  /// Сохраняет полученные инструменты в общий список (ключ 'tools'),
  /// заменяя прежние инструменты этого же сервера.
  Future<bool> _saveTools(McpServer s, List<Tool> fetched) async {
    final prefix = 'mcp_${_sanitize(s.name)}_';
    try {
      final all = await storage.getTools();
      all.removeWhere((t) => t.name.startsWith(prefix));
      for (final t in fetched) {
        t.name = '$prefix${_sanitize(t.name)}';
        all.add(t);
      }
      return await storage.setTools(all);
    } catch (_) {
      return false;
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
