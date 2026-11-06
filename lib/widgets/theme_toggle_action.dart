// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';

/// Кнопка циклического переключения темы в AppBar:
/// Светлая -> Тёмная -> Книжная -> AMOLED -> Светлая.
/// При обычном тапе сразу меняет тему и иконку без выпадающих меню,
/// с лёгким тактильным откликом. Идентификаторы — из lib/theme.dart
/// ('sepia' — книжная тема).
class ThemeToggleAction extends StatelessWidget {
  const ThemeToggleAction({super.key});

  static const List<String> _cycleOrder = <String>[
    'light',
    'dark',
    'sepia',
    'amoled',
  ];

  void _cycleTheme() {
    HapticFeedback.lightImpact();
    final current = settings.paletteId.toLowerCase();
    final idx = _cycleOrder.indexOf(current);
    final nextId = _cycleOrder[(idx + 1) % _cycleOrder.length];
    settings.setPalette(nextId);
  }

  static IconData _iconFor(String paletteId) {
    switch (paletteId.toLowerCase()) {
      case 'light':
        return Icons.wb_sunny_outlined;
      case 'dark':
        return Icons.nightlight_round;
      case 'sepia':
        return Icons.menu_book_outlined;
      case 'amoled':
        return Icons.contrast_rounded;
      default:
        return Icons.wb_sunny_outlined;
    }
  }

  static String _labelFor(String paletteId) {
    switch (paletteId.toLowerCase()) {
      case 'light':
        return 'Тема: Светлая';
      case 'dark':
        return 'Тема: Тёмная';
      case 'sepia':
        return 'Тема: Книжная';
      case 'amoled':
        return 'Тема: AMOLED';
      default:
        return 'Сменить тему';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final id = settings.paletteId;
        return IconButton(
          tooltip: _labelFor(id),
          onPressed: _cycleTheme,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => RotationTransition(
              turns: Tween<double>(begin: 0.85, end: 1.0).animate(anim),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: Icon(
              _iconFor(id),
              key: ValueKey<String>(id),
            ),
          ),
        );
      },
    );
  }
}
