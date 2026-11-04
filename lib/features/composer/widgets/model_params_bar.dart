// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app_state.dart';
import '../../../core/generation/curated_parameter_catalog.dart';
import '../../../core/generation/parameter_translator.dart';
import '../../../core/generation/user_param_override_store.dart';
import '../../../core/models/generation_schema.dart';
import '../../../core/models/param_spec.dart';
import '../../../theme.dart';
import 'manual_params_sheet.dart';

/// Блок параметров генерации в композере: чипсы по [ModelParameters]
/// активной модели.
///
/// Источник данных — [ParameterTranslator.resolveParams]: пользовательский
/// override ([UserParamOverrideStore]) имеет приоритет над курированным
/// каталогом. Если модель неизвестна ни там, ни там, показывается секция
/// с предложением указать параметры вручную либо открыть страницу моделей
/// провайдера в браузере (Base URL, без ключа).
///
/// Для override (confidence == 'user') над чипсами выводится подпись
/// «Ваши параметры» с кнопкой «Сбросить» (clear override).
class ModelParamsBar extends StatefulWidget {
  /// Идентификатор активной модели (effectiveConfig().model).
  final String modelId;

  const ModelParamsBar({super.key, required this.modelId});

  @override
  State<ModelParamsBar> createState() => _ModelParamsBarState();
}

class _ModelParamsBarState extends State<ModelParamsBar> {
  /// Разобранные параметры модели; null — модель неизвестна каталогу
  /// и override (либо модель ещё не разрешена).
  ModelParameters? _spec;

  /// Разрешение выполнено хотя бы один раз (до этого — пустой виджет).
  bool _loaded = false;

  /// Идентификатор модели, для которой выполнено последнее разрешение.
  String _resolvedFor = '';

  /// Текущий выбор по ключам ParamKeys ('aspect_ratio', 'duration', ...).
  final Map<String, String> _selected = <String, String>{};

  @override
  void initState() {
    super.initState();
    _resolve(widget.modelId.trim());
  }

  @override
  void didUpdateWidget(covariant ModelParamsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = widget.modelId.trim();
    if (id != _resolvedFor) _resolve(id);
  }

  /// Разрешает параметры модели: каталог догружается лениво, ошибки
  /// хранилища не роняют интерфейс. Защита от гонки: setState выполняется,
  /// только если модель не сменилась за время await.
  Future<void> _resolve(String modelId) async {
    _resolvedFor = modelId;
    final id = modelId;
    try {
      if (!CuratedParameterCatalog.isLoaded) {
        await CuratedParameterCatalog.load();
      }
    } catch (_) {
      // Каталог недоступен — останется пустым, byId вернёт null.
    }
    ModelParameters? spec;
    try {
      spec = await ParameterTranslator.resolveParams(id, userParamOverrideStore);
    } catch (_) {
      spec = null;
    }
    if (!mounted || _resolvedFor != id) return;
    setState(() {
      _spec = spec;
      _loaded = true;
      _selected.clear();
      if (spec != null) _preselect(spec);
    });
  }

  void _preselect(ModelParameters spec) {
    String first(List<String> list) => list.isEmpty ? '' : list.first;
    if (spec.aspectRatios.isNotEmpty) {
      _selected[ParamKeys.aspectRatio] = first(spec.aspectRatios);
    }
    final durs = spec.durations == null
        ? const <String>[]
        : _durationValues(spec.durations!);
    if (durs.isNotEmpty) _selected[ParamKeys.duration] = first(durs);
    if (spec.resolutions.isNotEmpty) {
      _selected[ParamKeys.resolution] = first(spec.resolutions);
    }
    if (spec.sizes.isNotEmpty) _selected[ParamKeys.size] = first(spec.sizes);
    if (spec.qualities.isNotEmpty) {
      _selected[ParamKeys.quality] = first(spec.qualities);
    }
  }

  /// Длительности в строках для чипсов: дискретный список либо
  /// несколько опорных значений диапазона (min, середина, max).
  static List<String> _durationValues(DurationRange d) {
    final disc = d.discrete;
    if (disc != null && disc.isNotEmpty) {
      return <String>[for (final v in disc) '$v'];
    }
    final min = d.min;
    final max = d.max;
    if (min == null && max == null) return const <String>[];
    if (min != null && max != null && max > min) {
      final mid = ((min + max) / 2).round();
      final vals = <int>[min];
      if (mid > min && mid < max) vals.add(mid);
      vals.add(max);
      return <String>[for (final v in vals) '$v'];
    }
    return <String>['${min ?? max}'];
  }

  // ---------- действия ----------

  /// Открывает Base URL провайдера в браузере (без ключа).
  Future<void> _openDocs() async {
    final url = effectiveConfig().baseUrl.trim();
    if (url.isEmpty) {
      _snack('Base URL не задан в настройках');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _snack('Base URL должен начинаться с http:// или https://');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted && !ok) return;
      if (!ok) _snack('Не удалось открыть браузер');
    } catch (_) {
      if (mounted) _snack('Не удалось открыть браузер');
    }
  }

  /// Ручной ввод параметров: шторка с пятью полями. При сохранении
  /// override сохраняется и чипсы перестраиваются.
  Future<void> _manual() async {
    final current = _spec;
    final initial =
        (current != null && current.isUserDefined) ? current : null;
    final res = await showManualParamsSheet(context, initial: initial);
    if (res == null) return;
    await userParamOverrideStore.save(widget.modelId.trim(), res);
    if (!mounted) return;
    await _resolve(widget.modelId.trim());
  }

  /// Сброс пользовательского override: параметры возвращаются
  /// к курированному каталогу либо к секции ручного ввода.
  Future<void> _reset() async {
    await userParamOverrideStore.clear(widget.modelId.trim());
    if (!mounted) return;
    await _resolve(widget.modelId.trim());
  }

  void _pick(String key, String value) {
    setState(() => _selected[key] = value);
  }

  void _snack(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  // ---------- интерфейс ----------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        if (widget.modelId.trim().isEmpty) return const SizedBox.shrink();
        if (!_loaded) return const SizedBox.shrink();
        final spec = _spec;
        if (spec == null) return _unknownSection(p);
        final confidence = spec.confidence;
        // TTS/voice/upscale: генераторам параметры не нужны — панель скрыта.
        if (confidence == 'skip') return const SizedBox.shrink();
        // Обычная текстовая LLM (auto без ar/dur/res/sizes): панель не нужна.
        if (confidence == 'auto' && _isEmptyAutoSpec(spec)) {
          return const SizedBox.shrink();
        }
        if (!spec.hasAny) {
          // Пользовательский override без значений: подпись и ручной ввод.
          if (confidence == 'user' || spec.isUserDefined) {
            return _userOnlySection(p);
          }
          return const SizedBox.shrink();
        }
        return _specSection(p, spec);
      },
    );
  }

  /// Секция неизвестной модели: подсказка и две кнопки.
  Widget _unknownSection(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Параметры для этой модели не подтверждены. '
            'Укажите вручную или посмотрите в документации провайдера.',
            style: TextStyle(fontSize: 12.5, height: 1.35, color: p.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _smallButton(
                p,
                'Открыть страницу моделей',
                Icons.open_in_new_rounded,
                _openDocs,
              ),
              _smallButton(
                p,
                'Указать параметры вручную',
                Icons.edit_outlined,
                _manual,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Секция с чипсами параметров известной модели.
  Widget _specSection(Palette p, ModelParameters spec) {
    final chips = <Widget>[];
    void group(List<String> values, String key, {String suffix = ''}) {
      for (final v in values) {
        chips.add(
          _chip(
            p,
            value: v,
            key: key,
            label: '$v$suffix',
            selected: _selected[key] == v,
          ),
        );
      }
    }

    if (spec.aspectRatios.isNotEmpty) {
      group(spec.aspectRatios, ParamKeys.aspectRatio);
    }
    final durs = spec.durations == null
        ? const <String>[]
        : _durationValues(spec.durations!);
    if (durs.isNotEmpty) group(durs, ParamKeys.duration, suffix: ' с');
    if (spec.resolutions.isNotEmpty) {
      group(spec.resolutions, ParamKeys.resolution);
    }
    if (spec.sizes.isNotEmpty) group(spec.sizes, ParamKeys.size);
    if (spec.qualities.isNotEmpty) group(spec.qualities, ParamKeys.quality);
    if (chips.isEmpty) return const SizedBox.shrink();

    final isUser = spec.confidence == 'user' || spec.isUserDefined;
    final isAuto = spec.confidence == 'auto';
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isUser) ...[
            _userRow(p),
            const SizedBox(height: 6),
          ] else if (isAuto) ...[
            Text(
              'Параметры из каталога RouterAI',
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                color: p.muted,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Wrap(spacing: 8, runSpacing: 8, children: chips),
          if (isAuto) ...[
            const SizedBox(height: 8),
            _smallButton(
              p,
              'Указать параметры вручную',
              Icons.edit_outlined,
              _manual,
            ),
          ],
        ],
      ),
    );
  }

  /// Пустая auto-спецификация: обычная текстовая LLM без параметров
  /// генерации — панель не показывается вовсе.
  bool _isEmptyAutoSpec(ModelParameters spec) {
    final durs = spec.durations;
    return spec.aspectRatios.isEmpty &&
        (durs == null || durs.isEmpty) &&
        spec.resolutions.isEmpty &&
        spec.sizes.isEmpty;
  }

  /// Секция пользовательского override без чипсов: подпись, кнопка
  /// «Сбросить» и ручной ввод для коррекции.
  Widget _userOnlySection(Palette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _userRow(p),
          const SizedBox(height: 8),
          _smallButton(
            p,
            'Указать параметры вручную',
            Icons.edit_outlined,
            _manual,
          ),
        ],
      ),
    );
  }

  /// Подпись «Ваши параметры» с карандашом и кнопкой «Сбросить».
  Widget _userRow(Palette p) {
    return Row(
      children: [
        Icon(Icons.edit_outlined, size: 13, color: p.accent),
        const SizedBox(width: 5),
        Text(
          'Ваши параметры',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.2,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: p.accent,
          ),
        ),
        const Spacer(),
        SizedBox(
          height: 28,
          child: TextButton(
            onPressed: _reset,
            style: TextButton.styleFrom(
              foregroundColor: p.muted,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: const Text('Сбросить'),
          ),
        ),
      ],
    );
  }

  Widget _chip(
    Palette p, {
    required String value,
    required String key,
    required String label,
    required bool selected,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _pick(key, value),
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
              label,
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

  Widget _smallButton(
    Palette p,
    String label,
    IconData icon,
    VoidCallback onTap,
  ) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: p.accent,
        side: BorderSide(color: p.accent.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
