// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models/model_config.dart';
import '../../theme.dart';

/// Панель ввода режима генерации изображений: большое поле промпта
/// и выбор пропорций (1:1, 16:9, 9:16 ...). Визуально повторяет капсулу
/// текстового ввода: та же карточка, радиусы, акцент и кнопка отправки.
class ImageGenInput extends StatefulWidget {
  final ImageGenModelConfig config;
  final TextEditingController? controller;
  final bool streaming;

  /// Смена выбранной пропорции (идентификатор вида '16:9').
  final ValueChanged<String>? onAspectRatioChanged;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  const ImageGenInput({
    super.key,
    this.config = const ImageGenModelConfig(),
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
  late String _ratio;

  TextEditingController get _effectiveController =>
      widget.controller ?? (_internalController ??= TextEditingController());

  List<String> get _ratios {
    final list = widget.config.availableAspectRatios
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return list.isEmpty ? const <String>['1:1'] : list;
  }

  @override
  void initState() {
    super.initState();
    final list = _ratios;
    _ratio = list.contains('1:1') ? '1:1' : list.first;
  }

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  void _select(String ratio) {
    if (ratio == _ratio) return;
    setState(() => _ratio = ratio);
    widget.onAspectRatioChanged?.call(ratio);
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
                      hintText: 'Опишите изображение...',
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
                              Icon(
                                Icons.aspect_ratio_rounded,
                                size: 17,
                                color: p.muted,
                              ),
                              const SizedBox(width: 8),
                              for (final r in _ratios) _ratioChip(r, p),
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

  Widget _ratioChip(String ratio, Palette p) {
    final selected = ratio == _ratio;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: widget.streaming ? null : () => _select(ratio),
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
                ratio,
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

