// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/active_model_capabilities.dart';
import '../../core/models/param_spec.dart';
import '../../theme.dart';
import 'video_gen_mode.dart';

/// Вариант выбора чипса: машинный идентификатор и подпись по-русски.
class _Choice {
  final String id;
  final String label;

  const _Choice(this.id, this.label);
}

/// Панель ввода режима генерации видео: большое поле промпта, выбор
/// пропорций, длительностей и разрешений из параметров активной модели
/// ([ActiveModelCapabilities.params]), кнопка прикрепления референсного
/// кадра. Статические варианты VideoGenMode используются только как
/// fallback, когда модель неизвестна каталогу. Визуально повторяет
/// капсулу генерации изображений: та же карточка, радиусы, акцент.
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
  String _ratio = '16:9';
  String _duration = '5s';
  String _resolution = '';
  PlatformFile? _frame;

  TextEditingController get _effectiveController =>
      widget.controller ?? (_internalController ??= TextEditingController());

  /// Пропорции модели: из параметров, иначе статический набор режима.
  List<String> get _ratioChoices {
    final p = widget.capabilities.params;
    final list = (p != null && p.aspectRatios.isNotEmpty)
        ? p.aspectRatios
        : VideoGenMode.aspectRatios.map((e) => e.id).toList();
    final clean = <String>[
      for (final r in list)
        if (r.trim().isNotEmpty) r.trim(),
    ];
    return clean.isEmpty ? const <String>['16:9'] : clean;
  }

  /// Длительности модели: дискретный список либо опорные точки диапазона.
  /// Пустой список у модели -> статический fallback режима (5 с / 10 с).
  List<_Choice> get _durationChoices {
    final p = widget.capabilities.params;
    final out = _durationsFrom(p?.durations);
    if (out.isNotEmpty) return out;
    return <_Choice>[
      for (final d in VideoGenMode.durations) _Choice(d.id, d.label),
    ];
  }

  /// Разрешения модели ('720p', '1080p', '1K' ...); пустой список —
  /// селектор разрешений не показывается.
  List<_Choice> get _resolutionChoices {
    final p = widget.capabilities.params;
    final list = p?.resolutions ?? const <String>[];
    return <_Choice>[
      for (final r in list)
        if (r.trim().isNotEmpty) _Choice(r.trim(), r.trim()),
    ];
  }

  /// Разбор диапазона/списка длительностей в варианты чипсов.
  static List<_Choice> _durationsFrom(DurationRange? range) {
    final d = range;
    if (d == null || d.isEmpty) return const <_Choice>[];
    final disc = d.discrete;
    if (disc != null && disc.isNotEmpty) {
      return <_Choice>[
        for (final v in disc) _Choice('${v}s', '$v с'),
      ];
    }
    final min = d.min;
    final max = d.max;
    if (min != null && max != null && max > min) {
      return <_Choice>[
        _Choice('${min}s', '$min с'),
        _Choice('${max}s', '$max с'),
      ];
    }
    final only = min ?? max;
    if (only == null) return const <_Choice>[];
    return <_Choice>[_Choice('${only}s', '$only с')];
  }

  @override
  void initState() {
    super.initState();
    final ratios = _ratioChoices;
    _ratio = ratios.contains('16:9') ? '16:9' : ratios.first;
    final durs = _durationChoices;
    if (durs.isNotEmpty) _duration = durs.first.id;
    final ress = _resolutionChoices;
    if (ress.isNotEmpty) _resolution = ress.first.id;
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
    return ListenableBuilder(
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
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      hintText: 'Опишите видео...',
                      hintStyle: TextStyle(color: Color(0xFFA8A096)),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.fromLTRB(16, 2, 16, 11.6),
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
                              for (final r in _ratioChoices)
                                _chip(
                                  label: r,
                                  selected: _ratio == r,
                                  p: p,
                                  onTap: () => setState(() => _ratio = r),
                                ),
                              for (final d in _durationChoices)
                                _chip(
                                  label: d.label,
                                  selected: _duration == d.id,
                                  p: p,
                                  onTap: () =>
                                      setState(() => _duration = d.id),
                                ),
                              for (final res in _resolutionChoices)
                                _chip(
                                  label: res.label,
                                  selected: _resolution == res.id,
                                  p: p,
                                  onTap: () =>
                                      setState(() => _resolution = res.id),
                                ),
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

  Widget _chip({
    required String label,
    required bool selected,
    required Palette p,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: widget.streaming ? null : onTap,
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
      ),
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
