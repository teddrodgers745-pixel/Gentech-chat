import 'package:flutter/material.dart';

import '../app_state.dart';

class HistoryDrawer extends StatelessWidget {
  /// false во время генерации ответа: переключать чаты нельзя.
  final bool enabled;

  /// Вызывается после открытия или создания чата (прокрутка вниз и т.п.).
  final VoidCallback onOpened;

  const HistoryDrawer({super.key, required this.enabled, required this.onOpened});

  String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<bool> _confirmDelete(BuildContext context, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить чат?'),
        content: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
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
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[store, settings]),
          builder: (context, _) {
            final p = settings.palette;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Чаты',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.add_comment_outlined, color: p.accent),
                  title: const Text('Новый чат'),
                  enabled: enabled,
                  onTap: () {
                    store.startNew();
                    Navigator.pop(context);
                    onOpened();
                  },
                ),
                const Divider(height: 1),
                Expanded(
                  child: store.chats.isEmpty
                      ? Center(
                          child: Text(
                            'Пока пусто',
                            style: TextStyle(color: p.muted),
                          ),
                        )
                      : ListView.builder(
                          itemCount: store.chats.length,
                          itemBuilder: (context, i) {
                            final c = store.chats[i];
                            return Dismissible(
                              key: ValueKey(c.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                color: const Color(0xFFB3261E),
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                child: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.white,
                                ),
                              ),
                              confirmDismiss: (_) => _confirmDelete(context, c.title),
                              onDismissed: (_) => store.delete(c),
                              child: ListTile(
                                selected: c == store.current,
                                selectedTileColor: p.userBg,
                                title: Text(
                                  c.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  _fmt(c.updatedAt),
                                  style: TextStyle(color: p.muted, fontSize: 12),
                                ),
                                onTap: enabled
                                    ? () {
                                        store.open(c);
                                        Navigator.pop(context);
                                        onOpened();
                                      }
                                    : null,
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
