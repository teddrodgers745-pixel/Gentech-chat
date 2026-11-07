// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/active_model_capabilities.dart';
import '../../models/model_config.dart';
import '../../theme.dart';

/// Панель ввода режима генерации изображений: большое поле промпта
/// и выбор пропорций ИЗ ПАРАМЕТРОВ активной модели
/// ([ActiveModelCapabilities.params]). Статические наборы пропорций
/// удалены: если у модели нет параметров (params == null) либо она
/// служебная (confidence == 'skip'), панель не показывается вовсе
/// ([SizedBox.shrink]). Больше трёх вариантов пропорций — всплывающее
/// меню ([PopupMenuButton]), иначе — [DropdownButton].
class ImageGenInput extends StatefulWidget {
  final ImageGenModelConfig config;

  /// Возможности активной модели (параметры генерации и т.п.).
  final ActiveModelCapabilities capabilities;
  final TextEditingController? controller;
  final bool streaming;

  /// Смена выбранной пропорции (идентификатор вида '16:9').
  final ValueChanged<String>? onAspectRatioChanged;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  const ImageGenInput({
    super.key,
    this.config = const ImageGenModelConfig(),
    required this.capabilities,
    this.controller,
    this.streaming = false,
    this.onAspectRatioChanged,
    this.onSend,
    this.onStop,
  });

  @override
  State<ImageGenInput> createState() => _ImageGenInputState();
}

class _ImageGenInputState extends State<ImageGenInput> {
  static const double _radius = 24;

  TextEditingController? _internalController;
  String _ratio = '';

  TextEditingController get _effectiveController =>
      widget.controller ?? (_internalController ??= TextEditingController());

  /// Скрывать ли панель: у модели нет параметров генерации либо она
  /// служебная (confidence == 'skip').
  bool get _hidden {
    final p = widget.capabilities.params;
    return p == null || p.confidence == 'skip';
  }

  /// Пропорции модели из capabilities.params (без статических fallback).
  List<String> get _ratios {
    final list =
        widget.capabilities.params?.aspectRatios ?? const <String>[];
    return <String>[
      for (final r in list)
        if (r.trim().isNotEmpty) r.trim(),
    ];
  }

  @override
  void initState() {
    super.initState();
    _syncSelection();
  }

  @override
  void didUpdateWidget(covariant ImageGenInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.capabilities.modelId != widget.capabilities.modelId) {
      _syncSelection();
    }
  }

  /// Синхронизация выбора со списком пропорций модели: прежний выбор
  /// сохраняется, если он есть в новом списке; иначе первый вариант
  /// ('1:1' приоритетен). Родителю сообщается актуальное значение.
  void _syncSelection() {
    final ratios = _ratios;
    if (ratios.isEmpty) {
      _ratio = '';
      return;
    }
    if (ratios.contains(_ratio)) return;
    _ratio = ratios.contains('1:1') ? '1:1' : ratios.first;
    widget.onAspectRatioChanged?.call(_ratio);
  }

  void _select(String ratio) {
    if (ratio == _ratio) return;
    setState(() => _ratio = ratio);
    widget.onAspectRatioChanged?.call(ratio);
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
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
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      hintText: 'Опишите изображение...',
                      hintStyle: TextStyle(color: p.muted),
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
                              if (_ratios.isNotEmpty) ...[
                                Icon(
                                  Icons.aspect_ratio_rounded,
                                  size: 17,
                                  color: p.muted,
                                ),
                                const SizedBox(width: 8),
                                _ratioSelector(p),
                              ],
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

  /// Селектор пропорций: до трёх вариантов — DropdownButton,
  /// больше — PopupMenuButton.
  Widget _ratioSelector(Palette p) {
    final ratios = _ratios;
    if (ratios.length > 3) return _ratioPopup(p, ratios);
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border),
      ),
      child: DropdownButton<String>(
        value: _ratio,
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
          for (final r in ratios) DropdownMenuItem<String>(value: r, child: Text(r)),
        ],
        onChanged: widget.streaming
            ? null
            : (v) {
                if (v != null) _select(v);
              },
      ),
    );
  }

  /// Всплывающее меню пропорций для моделей с обширной сеткой.
  Widget _ratioPopup(Palette p, List<String> ratios) {
    return PopupMenuButton<String>(
      enabled: !widget.streaming,
      initialValue: _ratio.isEmpty ? null : _ratio,
      color: p.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: _select,
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        for (final r in ratios)
          PopupMenuItem<String>(value: r, child: Text(r)),
      ],
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
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

  Widget _sendButton(Palette p) {
    return IconButton.filled(
      tooltip: widget.streaming ? 'Остановить' : 'Создать изображение',
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
