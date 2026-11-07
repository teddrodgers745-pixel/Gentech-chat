// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/active_model_capabilities.dart';
import '../../core/models/param_spec.dart';
import '../../theme.dart';
import 'video_gen_mode.dart';

/// Вариант выбора в выпадающем списке: машинный идентификатор
/// и подпись по-русски.
class _Choice {
  final String id;
  final String label;

  const _Choice(this.id, this.label);
}

/// Панель ввода режима генерации видео: большое поле промпта, выбор
/// пропорций, длительностей и разрешений ИЗ ПАРАМЕТРОВ активной модели
/// ([ActiveModelCapabilities.params]), кнопка прикрепления референсного
/// кадра. Статические наборы вариантов удалены: если у модели нет
/// параметров (params == null) либо она служебная
/// (confidence == 'skip'), панель не показывается ([SizedBox.shrink]).
/// Пропорции — DropdownButton (больше трёх — PopupMenuButton),
/// длительности и разрешения — DropdownButton.
class VideoGenInput extends StatefulWidget {
  /// Возможности активной модели (параметры генерации и т.п.).
  final ActiveModelCapabilities capabilities;
  final TextEditingController? controller;
  final bool streaming;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  const VideoGenInput({
    super.key,
    required this.capabilities,
    this.controller,
    this.streaming = false,
    this.onSend,
    this.onStop,
  });

  @override
  State<VideoGenInput> createState() => _VideoGenInputState();
}

class _VideoGenInputState extends State<VideoGenInput> {
  static const double _radius = 24;

  TextEditingController? _internalController;
  String _ratio = '';
  String _duration = '';
  String _resolution = '';
  PlatformFile? _frame;

  TextEditingController get _effectiveController =>
      widget.controller ?? (_internalController ??= TextEditingController());

  bool get _hidden {
    final p = widget.capabilities.params;
    return p == null || p.confidence == 'skip';
  }

  /// Пропорции модели (без статических fallback).
  List<String> get _ratioChoices {
    final list =
        widget.capabilities.params?.aspectRatios ?? const <String>[];
    return <String>[
      for (final r in list)
        if (r.trim().isNotEmpty) r.trim(),
    ];
  }

  /// Длительности модели: дискретный список либо опорные точки диапазона.
  /// Пустой список — селектор длительностей не показывается.
  List<_Choice> get _durationChoices =>
      _durationsFrom(widget.capabilities.params?.durations);

  /// Разрешения модели ('720p', '1080p', '1K' ...); пустой список —
  /// селектор разрешений не показывается.
  List<_Choice> get _resolutionChoices {
    final list = widget.capabilities.params?.resolutions ?? const <String>[];
    return <_Choice>[
      for (final r in list)
        if (r.trim().isNotEmpty) _Choice(r.trim(), r.trim()),
    ];
  }

  /// Разбор диапазона/списка длительностей в варианты выпадающего списка.
  static List<_Choice> _durationsFrom(DurationRange? range) {
    final d = range;
    if (d == null || d.isEmpty) return const <_Choice>[];
    final disc = d.discrete;
    if (disc != null && disc.isNotEmpty) {
      return <_Choice>[
        for (final v in disc) _Choice('$v', '$v с'),
      ];
    }
    final min = d.min;
    final max = d.max;
    if (min != null && max != null && max > min) {
      return <_Choice>[
        _Choice('$min', '$min с'),
        _Choice('$max', '$max с'),
      ];
    }
    final only = min ?? max;
    if (only == null) return const <_Choice>[];
    return <_Choice>[_Choice('$only', '$only с')];
  }

  @override
  void initState() {
    super.initState();
    _syncSelection();
  }

  @override
  void didUpdateWidget(covariant VideoGenInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.capabilities.modelId != widget.capabilities.modelId) {
      _syncSelection();
    }
  }

  /// Синхронизация выбора с новыми списками модели: прежние значения
  /// сохраняются, если они есть в списках; иначе первые варианты
  /// ('16:9' приоритетен для пропорций).
  void _syncSelection() {
    final ratios = _ratioChoices;
    if (!ratios.contains(_ratio)) {
      _ratio = ratios.contains('16:9') ? '16:9' : (ratios.isEmpty ? '' : ratios.first);
    }
    final durs = _durationChoices;
    if (!durs.any((d) => d.id == _duration)) {
      _duration = durs.isEmpty ? '' : durs.first.id;
    }
    final ress = _resolutionChoices;
    if (!ress.any((r) => r.id == _resolution)) {
      _resolution = ress.isEmpty ? '' : ress.first.id;
    }
  }

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  /// Выбор референсного кадра (изображение) через системный пикер.
  Future<void> _pickFrame() async {
    if (widget.streaming) return;
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (!mounted) return;
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      if ((f.path ?? '').isEmpty) return;
      setState(() => _frame = f);
    } catch (_) {
      // Диалог выбора не открылся — просто игнорируем.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    // Ключ с идентификатором модели: при смене модели панель пересоздаётся
    // целиком (VideoGenMode.modeId участвует в ключе, импорт остаётся).
    return KeyedSubtree(
      key: ValueKey<String>(
        '${VideoGenMode.modeId}_${widget.capabilities.modelId}',
      ),
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final p = settings.palette;
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.bottomCenter,
              clipBehavior: Clip.none,
              child: Container(
                decoration: BoxDecoration(
                  color: p.card,
                  borderRadius: BorderRadius.circular(_radius),
                  border: Border.all(color: p.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 15,
                      spreadRadius: 1,
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 14,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _effectiveController,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      cursorColor: p.accent,
                      style: fontStyle(
                        settings.bodyFont,
                        size: 16,
                        color: p.text,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: false,
                        hintText: 'Опишите видео...',
                        hintStyle: TextStyle(color: p.muted),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.fromLTRB(16, 2, 16, 11.6),
                      ),
                      minLines: 1,
                      maxLines: 6,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _frameButton(p),
                                _ratioSelector(p),
                                _durationSelector(p),
                                _resolutionSelector(p),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        _sendButton(p),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Селектор пропорций: до трёх — DropdownButton, больше — PopupMenuButton.
  Widget _ratioSelector(Palette p) {
    final ratios = _ratioChoices;
    if (ratios.isEmpty) return const SizedBox.shrink();
    if (ratios.length > 3) return _ratioPopup(p, ratios);
    return _paramDropdown(
      p,
      value: _ratio,
      options: <_Choice>[for (final r in ratios) _Choice(r, r)],
      onChanged: (v) => setState(() => _ratio = v),
    );
  }

  Widget _ratioPopup(Palette p, List<String> ratios) {
    return PopupMenuButton<String>(
      enabled: !widget.streaming,
      initialValue: _ratio.isEmpty ? null : _ratio,
      color: p.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (v) => setState(() => _ratio = v),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        for (final r in ratios)
          PopupMenuItem<String>(value: r, child: Text(r)),
      ],
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        margin: const EdgeInsets.only(right: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _ratio.isEmpty ? '—' : _ratio,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            Icon(Icons.expand_more, size: 18, color: p.muted),
          ],
        ),
      ),
    );
  }

  Widget _durationSelector(Palette p) {
    final durs = _durationChoices;
    if (durs.isEmpty) return const SizedBox.shrink();
    return _paramDropdown(
      p,
      value: _duration,
      options: durs,
      onChanged: (v) => setState(() => _duration = v),
    );
  }

  Widget _resolutionSelector(Palette p) {
    final ress = _resolutionChoices;
    if (ress.isEmpty) return const SizedBox.shrink();
    return _paramDropdown(
      p,
      value: _resolution,
      options: ress,
      onChanged: (v) => setState(() => _resolution = v),
    );
  }

  /// Компактный выпадающий список параметра в стиле чипов панели.
  Widget _paramDropdown(
    Palette p, {
    required String value,
    required List<_Choice> options,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border),
      ),
      child: DropdownButton<String>(
        value: value,
        underline: const SizedBox.shrink(),
        isDense: true,
        dropdownColor: p.card,
        borderRadius: BorderRadius.circular(12),
        icon: Icon(Icons.expand_more, size: 18, color: p.muted),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: p.text,
        ),
        items: <DropdownMenuItem<String>>[
          for (final o in options)
            DropdownMenuItem<String>(value: o.id, child: Text(o.label)),
        ],
        onChanged: widget.streaming
            ? null
            : (v) {
                if (v != null) onChanged(v);
              },
      ),
    );
  }

  /// Кнопка/чип референсного кадра: пусто — иконка прикрепления,
  /// выбран кадр — чип с именем файла и удалением.
  Widget _frameButton(Palette p) {
    final frame = _frame;
    if (frame != null) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: InputChip(
          avatar: Icon(Icons.image_outlined, size: 16, color: p.accent),
          label: Text(
            frame.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: p.text),
          ),
          deleteIconColor: p.muted,
          onDeleted: widget.streaming
              ? null
              : () => setState(() => _frame = null),
        ),
      );
    }
    return IconButton(
      tooltip: 'Прикрепить референсный кадр',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      visualDensity: VisualDensity.compact,
      iconSize: 22,
      icon: Icon(Icons.image_outlined, size: 22, color: p.muted),
      onPressed: _pickFrame,
    );
  }

  Widget _sendButton(Palette p) {
    return IconButton.filled(
      tooltip: widget.streaming ? 'Остановить' : 'Создать видео',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: widget.streaming ? widget.onStop : widget.onSend,
      style: IconButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
      ),
      icon: Icon(
        widget.streaming ? Icons.stop_rounded : Icons.rocket_launch_rounded,
        size: 26,
      ),
    );
  }
}
