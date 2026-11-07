// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/generation/model_type_override_store.dart';
import '../models.dart';
import '../theme.dart';

/// Шторка «Быстрый доступ»: список моделей из пресетов и общих настроек
/// и секция «Тип модели» — ручной override типа активной модели
/// (Авто / Текст / Изображение / Видео), сохраняемый в SharedPreferences.
class QuickAccessSheet extends StatefulWidget {
  /// Вызывается после сохранения override типа: экран чата переразрешает
  /// тип активной модели, не дожидаясь следующей пересборки.
  final void Function(String modelId)? onTypeChanged;

  const QuickAccessSheet({super.key, this.onTypeChanged});

  @override
  State<QuickAccessSheet> createState() => _QuickAccessSheetState();
}

class _QuickAccessSheetState extends State<QuickAccessSheet> {
  /// Активная модель: к ней применяется override типа.
  late final String _selected;

  /// Текущий override ('auto' — не задан, работает автораспознавание).
  String _type = ModelTypes.auto;

  @override
  void initState() {
    super.initState();
    _selected = effectiveConfig().model.trim();
    _loadType();
  }

  Future<void> _loadType() async {
    final t = await ModelTypeOverrideStore.instance.loadOverride(_selected);
    if (!mounted || t == null) return;
    setState(() => _type = t);
  }

  /// Выбор модели: активируется пресет с этой моделью, иначе модель
  /// записывается в активный пресет — единственный источник истины
  /// (PresetStore.updateActivePresetModel; при отсутствии активного
  /// пресета создаётся системный дефолтный). Шторка закрывается.
  Future<void> _pickModel(String m) async {
    Preset? matched;
    for (final pr in presets.items) {
      if (pr.model.trim() == m) {
        matched = pr;
        break;
      }
    }
    if (matched != null) {
      presets.setActive(matched.id);
    } else {
      await presets.updateActivePresetModel(m);
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  /// Сохранение override типа; «Авто» удаляет override из хранилища.
  Future<void> _setType(String t) async {
    setState(() => _type = t);
    final id = _selected.trim();
    if (id.isEmpty) return;
    if (t == ModelTypes.auto) {
      await ModelTypeOverrideStore.instance.clear(id);
    } else {
      await ModelTypeOverrideStore.instance.save(id, t);
    }
    widget.onTypeChanged?.call(id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, presets]),
      builder: (context, _) {
        final p = settings.palette;
        final models = <String>[];
        void addModel(String raw) {
          final m = raw.trim();
          if (m.isEmpty || models.contains(m)) return;
          models.add(m);
        }

        for (final pr in presets.items) {
          addModel(pr.model);
        }
        addModel(settings.model);
        final currentModel = effectiveConfig().model.trim();

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
                    'Быстрый доступ',
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
                      if (models.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Text(
                            'Моделей пока нет. Задайте модель в настройках провайдера.',
                            style: TextStyle(color: p.muted, fontSize: 13),
                          ),
                        )
                      else
                        for (final m in models)
                          ListTile(
                            dense: true,
                            title: Text(
                              m.replaceFirst(
                                RegExp(r'^models/', caseSensitive: false),
                                '',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: p.text,
                                fontFamily: 'JetBrains Mono',
                                fontFamilyFallback: const ['monospace'],
                              ),
                            ),
                            trailing: m == currentModel
                                ? Icon(Icons.check, size: 18, color: p.accent)
                                : null,
                            onTap: () => _pickModel(m),
                          ),
                      _typeSection(p),
                      _streamSection(p),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Секция «ГЕНЕРАЦИЯ»: тумблер «Поток (Stream)», привязанный к
  /// presets.active.stream (сохраняется через PresetStore). Если активного
  /// пресета нет, создаётся системный дефолтный.
  Widget _streamSection(Palette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'ГЕНЕРАЦИЯ',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: p.accent,
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Поток (Stream)'),
          subtitle: Text(
            'Ответ приходит по частям по мере генерации. '
            'Модели без поддержки стриминга получают stream: false '
            'автоматически.',
            style: TextStyle(color: p.muted, fontSize: 12, height: 1.35),
          ),
          value: presets.active?.stream ?? true,
          onChanged: (v) => presets.updateActivePresetStream(v),
        ),
      ],
    );
  }

  /// Секция «Тип модели»: четыре чипа — Авто / Текст / Изображение / Видео.
  Widget _typeSection(Palette p) {
    final id = _selected.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'ТИП МОДЕЛИ',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: p.accent,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: id.isEmpty
              ? Text(
                  'Модель не выбрана — тип задаётся после выбора модели.',
                  style: TextStyle(color: p.muted, fontSize: 12.5),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Ручной тип для модели «$id». «Авто» — тип определяется '
                      'автоматически по каталогу и параметрам.',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _typeChip('Авто', ModelTypes.auto, p),
                        _typeChip('Текст', ModelTypes.text, p),
                        _typeChip('Изображение', ModelTypes.image, p),
                        _typeChip('Видео', ModelTypes.video, p),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _typeChip(String label, String value, Palette p) {
    final selected = _type == value;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _setType(value),
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
}
