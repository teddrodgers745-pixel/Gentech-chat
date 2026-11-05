// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../../app_state.dart';
import '../../../core/utils/reasoning_mapper.dart';

/// Открывает нижнюю шторку выбора уровня размышлений (Reasoning Effort).
/// Слайдер на N позиций — по уровням, которые разрешает активная модель
/// ([levels]); выбор сохраняется в настройках и применяется ко всем
/// последующим запросам.
Future<void> showReasoningSheet(
  BuildContext context, {
  required List<ReasoningLevel> levels,
  required String currentId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ReasoningSheet(levels: levels, currentId: currentId),
  );
}

class _ReasoningSheet extends StatefulWidget {
  final List<ReasoningLevel> levels;
  final String currentId;

  const _ReasoningSheet({required this.levels, required this.currentId});

  @override
  State<_ReasoningSheet> createState() => _ReasoningSheetState();
}

class _ReasoningSheetState extends State<_ReasoningSheet> {
  late int _index;

  @override
  void initState() {
    super.initState();
    final i = widget.levels
        .indexWhere((l) => l.id == widget.currentId.trim().toLowerCase());
    _index = i < 0 ? 0 : i;
  }

  static String _describe(ReasoningLevel l) => switch (l) {
        ReasoningLevel.off =>
          'Размышления выключены: поле в запрос не отправляется',
        ReasoningLevel.minimal =>
          'Минимальные размышления — самый быстрый ответ',
        ReasoningLevel.low => 'Небольшое размышление перед ответом',
        ReasoningLevel.medium => 'Сбалансированный режим по умолчанию',
        ReasoningLevel.high => 'Глубокое размышление для сложных задач',
        ReasoningLevel.xhigh =>
          'Максимальное размышление — самый долгий и внимательный ответ',
      };

  /// Сохраняет выбранный уровень в настройках и закрывает шторку.
  void _commit() {
    settings.setReasoningLevel(widget.levels[_index].id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final levels = widget.levels;
        if (levels.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Уровни размышлений для модели недоступны'),
          );
        }
        final current = levels[_index];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'МЫШЛЕНИЕ',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: p.accent,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  current.label,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _describe(current),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                if (levels.length > 1)
                  Slider(
                    value: _index.toDouble(),
                    min: 0,
                    max: (levels.length - 1).toDouble(),
                    divisions: levels.length - 1,
                    label: current.label,
                    activeColor: p.accent,
                    onChanged: (v) => setState(() => _index = v.round()),
                    onChangeEnd: (_) => _commit(),
                  ),
                if (levels.length > 1)
                  Row(
                    children: [
                      for (final l in levels)
                        Expanded(
                          child: Text(
                            l.label,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.2,
                              fontWeight: l == current
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: l == current ? p.accent : p.muted,
                            ),
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
