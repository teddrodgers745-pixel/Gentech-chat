// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../../app_state.dart';
import '../../../core/models/param_spec.dart';

/// Показывает нижнюю шторку ручного ввода параметров модели.
/// Возвращает разобранный [ModelParameters] (confidence 'user') либо
/// null — шторка закрыта без сохранения.
///
/// [allowedResolutions] / [allowedQualities] — поддерживаемые моделью
/// значения из каталога (caps.params). Непустые списки включают секцию
/// MEDIA с чипсами: тап подставляет значение в соответствующее поле;
/// итог сохраняется вызывающим кодом в UserParamOverrideStore как раньше.
Future<ModelParameters?> showManualParamsSheet(
  BuildContext context, {
  ModelParameters? initial,
  List<String> allowedResolutions = const <String>[],
  List<String> allowedQualities = const <String>[],
}) {
  return showModalBottomSheet<ModelParameters>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ManualParamsSheet(
      initial: initial,
      allowedResolutions: allowedResolutions,
      allowedQualities: allowedQualities,
    ),
  );
}

/// Шторка ручного ввода параметров: пять текстовых полей
/// (пропорции, длительности, разрешения, размеры, качества).
/// Значения разбираются терпимо: списки через запятую,
/// длительности — «5, 10» либо диапазон «2-30».
class _ManualParamsSheet extends StatefulWidget {
  final ModelParameters? initial;

  /// Поддерживаемые моделью разрешения и качества (из caps.params);
  /// непустой список включает секцию MEDIA.
  final List<String> allowedResolutions;
  final List<String> allowedQualities;

  const _ManualParamsSheet({
    this.initial,
    this.allowedResolutions = const <String>[],
    this.allowedQualities = const <String>[],
  });

  @override
  State<_ManualParamsSheet> createState() => _ManualParamsSheetState();
}

class _ManualParamsSheetState extends State<_ManualParamsSheet> {
  late final TextEditingController _ratios;
  late final TextEditingController _durations;
  late final TextEditingController _resolutions;
  late final TextEditingController _sizes;
  late final TextEditingController _qualities;

  late final List<String> _chipResolutions;
  late final List<String> _chipQualities;

  /// Трим, дубликаты и пустые значения из списка caps убираются.
  static List<String> _cleanList(List<String> raw) {
    final out = <String>[];
    for (final e in raw) {
      final s = e.trim();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _chipResolutions = _cleanList(widget.allowedResolutions);
    _chipQualities = _cleanList(widget.allowedQualities);
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

  /// Секция MEDIA (Stage 2c): чипсы поддерживаемых моделью разрешений
  /// и качеств. Тап подставляет значение в соответствующее поле шторки;
  /// сохранение — общим путём через «Сохранить» (UserParamOverrideStore).
  Widget _mediaSection(Palette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MEDIA',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: p.accent,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Значения из каталога модели. Тап подставляет значение в поле '
          'ниже (поле можно отредактировать вручную).',
          style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.35),
        ),
        const SizedBox(height: 10),
        if (_chipResolutions.isNotEmpty) ...[
          Text(
            'Разрешения',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.text,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in _chipResolutions)
                _mediaChip(p, v, _resolutions),
            ],
          ),
          const SizedBox(height: 10),
        ],
        if (_chipQualities.isNotEmpty) ...[
          Text(
            'Качество',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.text,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in _chipQualities) _mediaChip(p, v, _qualities),
            ],
          ),
        ],
      ],
    );
  }

  Widget _mediaChip(
    Palette p,
    String value,
    TextEditingController target,
  ) {
    final selected = target.text.trim() == value;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        setState(() {
          target.text = value;
          target.selection = TextSelection.collapsed(offset: value.length);
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? p.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? p.accent : p.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 15, color: p.accent),
              const SizedBox(width: 4),
            ],
            Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: selected ? p.accent : p.muted,
              ),
            ),
          ],
        ),
      ),
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
                if (_chipResolutions.isNotEmpty || _chipQualities.isNotEmpty)
                  _mediaSection(p),
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
