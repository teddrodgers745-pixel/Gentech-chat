// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'preset_edit_screen.dart';

/// Чип с названием активного пресета в AppBar (под названием чата).
class PresetChip extends StatelessWidget {
  final VoidCallback onTap;

  const PresetChip({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = settings.palette;
    final preset = presets.active;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: p.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.accent.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 13, color: p.accent),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Text(
                preset == null || preset.name.trim().isEmpty
                    ? 'Без пресета'
                    : preset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  color: p.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 15, color: p.accent),
          ],
        ),
      ),
    );
  }
}

/// Нижняя шторка: список всех пресетов, выбор активного,
/// переход к созданию/редактированию.
class PresetsSheet extends StatelessWidget {
  const PresetsSheet({super.key});

  void _openEditor(BuildContext sheetCtx, {Preset? existing}) {
    final nav = Navigator.of(sheetCtx);
    nav.pop();
    nav.push(
      MaterialPageRoute(
        builder: (_) => PresetEditScreen(existing: existing),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: presets,
      builder: (context, _) {
        final p = settings.palette;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Пресеты',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: p.text,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      ListTile(
                        leading: Icon(Icons.settings_outlined, color: p.muted),
                        title: const Text('Без пресета'),
                        subtitle: Text(
                          'Глобальные настройки подключения',
                          style: TextStyle(color: p.muted, fontSize: 12),
                        ),
                        trailing: presets.active == null
                            ? Icon(Icons.check, color: p.accent)
                            : null,
                        onTap: () {
                          presets.clearActive();
                          Navigator.pop(context);
                        },
                      ),
                      for (final pr in presets.items)
                        ListTile(
                          leading: Icon(Icons.auto_awesome, color: p.accent),
                          title: Text(
                            pr.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            pr.model.trim().isEmpty ? 'Модель не задана' : pr.model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (presets.active?.id == pr.id)
                                Icon(Icons.check, color: p.accent),
                              IconButton(
                                tooltip: 'Изменить',
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                onPressed: () =>
                                    _openEditor(context, existing: pr),
                              ),
                            ],
                          ),
                          onTap: () {
                            presets.setActive(pr.id);
                            Navigator.pop(context);
                          },
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: ElevatedButton.icon(
                    onPressed: () => _openEditor(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Создать пресет'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
