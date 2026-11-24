// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../../app_state.dart';
import '../../../core/utils/reasoning_mapper.dart';

/// Открывает нижнюю шторку выбора уровня размышлений (Reasoning Effort).
///
/// Слайдер идёт по строкам `caps.reasoningLevels` как есть — без
/// enum-ремапа. Принимаем как `List<String>` (актуальный путь), так и
/// старый `List<ReasoningLevel>` (для обратной совместимости), чтобы
/// вызывающие места не ломались на переходный период.
Future<void> showReasoningSheet(
  BuildContext context, {
  required List<Object?> levels,
  required String currentId,
}) {
  final resolved = <String>[];
  for (final l in levels) {
    if (l is String) {
      final t = l.trim();
      if (t.isNotEmpty) resolved.add(t);
    } else if (l is ReasoningLevel) {
      final t = l.id.trim();
      if (t.isNotEmpty) resolved.add(t);
    }
  }
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ReasoningSheet(levels: resolved, currentId: currentId),
  );
}

class _ReasoningSheet extends StatefulWidget {
  final List<String> levels;
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
    final current = widget.currentId.trim().toLowerCase();
    final i = widget.levels.indexWhere((l) => l.toLowerCase() == current);
    _index = i < 0 ? 0 : i;
  }

  /// Презентационная метка уровня. Список усилий даёт только каталог —
  /// это лишь подписи для известных ключей, для незнакомых возвращаем
  /// строку как есть.
  static String _labelFor(String id) {
    switch (id.toLowerCase()) {
      case 'off':
        return 'Off';
      case 'none':
        return 'None';
      case 'min':
        return 'Min';
      case 'minimal':
        return 'Minimal';
      case 'low':
        return 'Low';
      case 'medium':
        return 'Medium';
      case 'high':
        return 'High';
      case 'xhigh':
        return 'XHigh';
      case 'max':
        return 'Max';
      default:
        return id;
    }
  }

  static String _describe(String id) {
    switch (id.toLowerCase()) {
      case 'off':
        return 'Размышления выключены (в запрос уходит none)';
      case 'none':
        return 'Размышления выключены (none)';
      case 'low':
        return 'Небольшое размышление перед ответом';
      case 'medium':
        return 'Сбалансированный режим по умолчанию';
      case 'high':
        return 'Глубокое размышление для сложных задач';
      case 'xhigh':
        return 'Расширенное размышление для очень сложных задач';
      case 'max':
        return 'Максимально глубокое размышление';
      default:
        return 'Уровень: $id';
    }
  }

  /// Сохраняет выбранный уровень в настройках и закрывает шторку.
  void _commit() {
    settings.setReasoningLevel(widget.levels[_index]);
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
        if (_index >= levels.length) _index = levels.length - 1;
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
                  _labelFor(current),
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
                    label: _labelFor(current),
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
                            _labelFor(l),
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
      }
    );
  }
}
