// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

/// Секция настройки поиска в интернете.
/// Четыре режима: Выключен, Авто (Polza), Sonar (Perplexity), DeepSeek (все-в-одном).
/// Для режима «Авто (Polza)» доступен дополнительный тумблер «Чтение страниц (Fetch)».
class WebSearchSection extends StatelessWidget {
  const WebSearchSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final mode = settings.webSearchMode;
        final showFetch = mode == 'polza';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(p, 'ПОИСК В ИНТЕРНЕТЕ'),
            const SizedBox(height: 8),
            ..._modeTiles(p, mode),
            if (showFetch) ...[
              const SizedBox(height: 8),
              _fetchTile(p),
            ],
          ],
        );
      },
    );
  }

  Widget _sectionHeader(Palette p, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: p.accent,
      ),
    );
  }

  List<Widget> _modeTiles(Palette p, String current) {
    final modes = <_ModeOption>[
      _ModeOption('off', 'Выключен', ''),
      _ModeOption('polza', 'Авто (Polza)', 'Базовый поиск через провайдера Polza'),
      _ModeOption('sonar', 'Sonar (Perplexity)', 'Поиск через Perplexity Sonar'),
      _ModeOption(
        'deepseek',
        'DeepSeek (все-в-одном)',
        'Поиск и чтение страниц. Модель сама решает, как ответить',
      ),
    ];

    return [
      for (final opt in modes)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: current == opt.value ? p.accent : p.border,
              width: current == opt.value ? 2 : 1,
            ),
          ),
          child: RadioListTile<String>(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            visualDensity: VisualDensity.compact,
            dense: true,
            value: opt.value,
            groupValue: current,
            onChanged: (v) => settings.setWebSearchMode(v!),
            activeColor: p.accent,
            title: Text(
              opt.label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            subtitle: opt.subtitle.isNotEmpty
                ? Text(
                    opt.subtitle,
                    style: TextStyle(color: p.muted, fontSize: 12),
                  )
                : null,
            controlAffinity: ListTileControlAffinity.trailing,
          ),
        ),
    ];
  }

  Widget _fetchTile(Palette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Чтение страниц (Fetch)'),
        subtitle: Text(
          'Позволяет модели загружать и читать содержимое найденных страниц',
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
        value: settings.webSearchEnabled,
        onChanged: (v) => settings.setWebSearch(v),
        activeColor: p.accent,
      ),
    );
  }
}

class _ModeOption {
  final String value;
  final String label;
  final String subtitle;

  const _ModeOption(this.value, this.label, this.subtitle);
}

// trigger rebuild
