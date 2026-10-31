// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

/// Секция настройки поиска в интернете.
/// Главный тумблер «Использовать поиск»:
///  - выключен — режим принудительно 'off', радио-кнопки режимов и тумблер
///    Fetch полностью скрыты;
///  - включён — список режимов раскрывается плавно (анимация), а тумблер
///    «Чтение страниц (Fetch)» виден только для режима «Авто (Polza)».
/// Все значения сохраняются через AppSettings (SharedPreferences):
/// режим — webSearchMode, Fetch — webSearchEnabled.
class WebSearchSection extends StatelessWidget {
  const WebSearchSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final mode = settings.webSearchMode;
        final enabled = mode != 'off';
        final showFetch = enabled && mode == 'polza';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(p, 'ПОИСК В ИНТЕРНЕТЕ'),
            _masterTile(p, enabled),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 220),
              sizeCurve: Curves.easeOutCubic,
              crossFadeState: enabled
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  _modeTiles(p, mode),
                  if (showFetch) ...[
                    const SizedBox(height: 8),
                    _fetchTile(p),
                  ],
                ],
              ),
            ),
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

  /// Главный тумблер. Значение выводится из режима: включён = режим не 'off'.
  /// Выключение всегда приводит режим к 'off' и скрывает весь список;
  /// включение возвращает режим к «Авто (Polza)».
  Widget _masterTile(Palette p, bool enabled) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Использовать поиск'),
      subtitle: Text(
        'Включить инструменты поиска в чате',
        style: TextStyle(color: p.muted, fontSize: 12),
      ),
      value: enabled,
      onChanged: (v) => settings.setWebSearchMode(v ? 'polza' : 'off'),
      activeThumbColor: p.accent,
    );
  }

  /// Радио-список режимов. Начиная с Flutter 3.32 значение группы
  /// управляется виджетом-предком RadioGroup: у RadioListTile
  /// groupValue/onChanged больше не задаются напрямую.
  Widget _modeTiles(Palette p, String current) {
    const modes = <_ModeOption>[
      _ModeOption('off', 'Выключен', ''),
      _ModeOption('polza', 'Авто (Polza)', 'Базовый поиск через провайдера Polza'),
      _ModeOption('sonar', 'Sonar (Perplexity)', 'Поиск через Perplexity Sonar'),
      _ModeOption(
        'deepseek',
        'DeepSeek (все-в-одном)',
        'Поиск и чтение страниц. Модель сама решает, как ответить',
      ),
    ];

    return RadioGroup<String>(
      groupValue: current,
      onChanged: (v) => settings.setWebSearchMode(v!),
      child: Column(
        children: [
          for (final opt in modes) _modeTile(p, opt, current),
        ],
      ),
    );
  }

  Widget _modeTile(Palette p, _ModeOption opt, String current) {
    final selected = current == opt.value;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? p.accent : p.border,
          width: selected ? 2 : 1,
        ),
      ),
      child: RadioListTile<String>(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        visualDensity: VisualDensity.compact,
        dense: true,
        value: opt.value,
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
    );
  }

  /// Тумблер «Чтение страниц (Fetch)»: состояние в webSearchEnabled
  /// (как и раньше), виден только при включённом поиске в режиме polza.
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
        activeThumbColor: p.accent,
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
