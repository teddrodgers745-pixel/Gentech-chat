// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

/// Кнопка луны в AppBar.
///
/// Тап открывает нижнюю шторку ([showModalBottomSheet]) со списком всех
/// четырёх тем (Светлая, Тёмная, Книжная, AMOLED) в виде ListView.
/// Тема НЕ переключается сразу при нажатии: выбор происходит в шторке,
/// чипом с цветной точкой и галочкой у выбранной (стиль секции
/// «Внешний вид» настроек). Иконка — луна, когда текущая тема светлая,
/// и солнце — когда тёмная.
class ThemeToggleAction extends StatelessWidget {
  const ThemeToggleAction({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final toDark = settings.paletteId == 'light';
        return Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _showThemeSheet(context),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(
                toDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Шторка выбора темы. Смена темы уведомляет слушателей: MaterialApp
  /// (ListenableBuilder в GenTechChatApp) перестраивается сразу,
  /// выбор сохраняется в SharedPreferences через settings.setPalette.
  void _showThemeSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _ThemeSheet(),
    );
  }
}

/// Шторка со списком тем: заголовок КАПСОМ акцентным цветом,
/// ListView из четырёх тем — чипы с точкой цвета темы и галочкой
/// у выбранной. Тап по кнопке луны только открывает шторку,
/// переключение темы выполняет выбор чипа.
class _ThemeSheet extends StatelessWidget {
  const _ThemeSheet();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'ТЕМА',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: p.accent,
                  ),
                ),
                const SizedBox(height: 10),
                ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final x in palettes)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ChoiceChip(
                          label: Text(
                            x.name,
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 4,
                          ),
                          visualDensity: VisualDensity.comfortable,
                          selected: x.id == settings.paletteId,
                          avatar: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: x.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          onSelected: (_) {
                            settings.setPalette(x.id);
                            Navigator.of(context).pop();
                          },
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
