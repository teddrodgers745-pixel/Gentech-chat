// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../../app_state.dart';
import '../../../core/models/param_spec.dart';
import '../../../theme.dart';

/// Показывает нижнюю шторку ручного ввода параметров модели.
/// Возвращает разобранный [ModelParameters] (confidence 'user') либо
/// null — шторка закрыта без сохранения.
Future<ModelParameters?> showManualParamsSheet(
  BuildContext context, {
  ModelParameters? initial,
}) {
  return showModalBottomSheet<ModelParameters>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ManualParamsSheet(initial: initial),
  );
}

/// Шторка ручного ввода параметров: пять текстовых полей
/// (пропорции, длительности, разрешения, размеры, качества).
/// Значения разбираются терпимо: списки через запятую,
/// длительности — «5, 10» либо диапазон «2-30».
class _ManualParamsSheet extends StatefulWidget {
  final ModelParameters? initial;

  const _ManualParamsSheet({this.initial});

  @override
  State<_ManualParamsSheet> createState() => _ManualParamsSheetState();
}

class _ManualParamsSheetState extends State<_ManualParamsSheet> {
  late final TextEditingController _ratios;
  late final TextEditingController _durations;
  late final TextEditingController _resolutions;
  late final TextEditingController _sizes;
  late final TextEditingController _qualities;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _ratios = TextEditingController(text: s?.aspectRatios.join(', ') ?? '');
    _durations = TextEditingController(text: _durationsText(s));
    _resolutions =
        TextEditingController(text: s?.resolutions.join(', ') ?? '');
    _sizes = TextEditingController(text: s?.sizes.join(', ') ?? '');
    _qualities = TextEditingController(text: s?.qualities.join(', ') ?? '');
  }

  /// Начальное значение поля длительностей: дискретный список через
  /// запятую либо диапазон 'min-max'.
  static String _durationsText(ModelParameters? s) {
    final d = s?.durations;
    if (d == null || d.isEmpty) return '';
    final disc = d.discrete;
    if (disc != null && disc.isNotEmpty) return disc.join(', ');
    final min = d.min;
    final max = d.max;
    if (min != null && max != null && max != min) return '$min-$max';
    return '${min ?? max ?? ''}';
  }

  @override
  void dispose() {
    _ratios.dispose();
    _durations.dispose();
    _resolutions.dispose();
    _sizes.dispose();
    _qualities.dispose();
    super.dispose();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  /// Разбор полей в [ModelParameters]; null — ни одно поле не заполнено.
  ModelParameters? _parse() {
    List<String> list(TextEditingController c) {
      final t = c.text.trim();
      if (t.isEmpty) return const <String>[];
      return <String>[
        for (final e in t.split(','))
          if (e.trim().isNotEmpty) e.trim(),
      ];
    }

    final ratios = list(_ratios);
    final resolutions = list(_resolutions);
    final sizes = list(_sizes);
    final qualities = list(_qualities);

    DurationRange? durations;
    final dRaw = _durations.text.trim();
    if (dRaw.isNotEmpty) {
      final range = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(dRaw);
      if (range != null) {
        final a = int.tryParse(range.group(1)!);
        final b = int.tryParse(range.group(2)!);
        if (a != null && b != null && b >= a) {
          durations = DurationRange(min: a, max: b);
        }
      } else {
        final discrete = <int>[
          for (final e in dRaw.split(','))
            if (int.tryParse(e.trim()) != null) int.parse(e.trim()),
        ];
        if (discrete.isNotEmpty) {
          durations = DurationRange(discrete: discrete);
        }
      }
    }

    if (ratios.isEmpty &&
        durations == null &&
        resolutions.isEmpty &&
        sizes.isEmpty &&
        qualities.isEmpty) {
      return null;
    }
    return ModelParameters(
      aspectRatios: ratios,
      durations: durations,
      resolutions: resolutions,
      sizes: sizes,
      qualities: qualities,
      confidence: 'user',
      isUserDefined: true,
    );
  }

  void _save() {
    final params = _parse();
    if (params == null) {
      _snack('Заполните хотя бы одно поле');
      return;
    }
    Navigator.of(context).pop(params);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 4,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'СВОИ ПАРАМЕТРЫ МОДЕЛИ',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: p.accent,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Значения сохраняются для этой модели и применяются '
                  'к чипсам панели.',
                  style: TextStyle(color: p.muted, fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _ratios,
                  autocorrect: false,
                  cursorColor: p.accent,
                  decoration: const InputDecoration(
                    labelText: 'Пропорции',
                    hintText: '1:1, 16:9, 9:16',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _durations,
                  autocorrect: false,
                  cursorColor: p.accent,
                  keyboardType: TextInputType.text,
                  decoration: const InputDecoration(
                    labelText: 'Длительности (для видео)',
                    hintText: '5, 10 или 2-30',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _resolutions,
                  autocorrect: false,
                  cursorColor: p.accent,
                  decoration: const InputDecoration(
                    labelText: 'Разрешения',
                    hintText: '720p, 1080p',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _sizes,
                  autocorrect: false,
                  cursorColor: p.accent,
                  decoration: const InputDecoration(
                    labelText: 'Размеры',
                    hintText: '1024x1024, 1792x1024',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _qualities,
                  autocorrect: false,
                  cursorColor: p.accent,
                  decoration: const InputDecoration(
                    labelText: 'Качество',
                    hintText: 'low, medium, high',
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check_rounded, size: 20),
                    label: const Text('Сохранить'),
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
