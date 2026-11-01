// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app_state.dart';
import '../../models/model_config.dart';
import '../../theme.dart';

/// Панель текстового ввода чата: капсула с полем сообщения,
/// капсулами мышления и поиска, микрофоном, скрепкой и кнопкой отправки.
class TextChatInput extends StatefulWidget {
  final TextModelConfig config;
  final TextEditingController? controller;
  final bool streaming;
  final int reasoningLevel;
  final VoidCallback? onCycleReasoning;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onToggleMic;
  final VoidCallback? onAttach;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  const TextChatInput({
    super.key,
    this.config = const TextModelConfig(),
    this.controller,
    this.streaming = false,
    this.reasoningLevel = 0,
    this.onCycleReasoning,
    this.onToggleSearch,
    this.onToggleMic,
    this.onAttach,
    this.onSend,
    this.onStop,
  });

  @override
  State<TextChatInput> createState() => _TextChatInputState();
}

class _TextChatInputState extends State<TextChatInput> {
  TextEditingController? _internalController;
  int _localReasoningLevel = 0;

  static const double _radius = 24;

  static const List<String> _reasoningLabels = <String>[
    'Low',
    'Medium',
    'High',
    'xHigh',
    'Max',
  ];

  static const List<Color> _reasoningFills = <Color>[
    Color(0xFF71594B),
    Color(0xFFC07650),
    Color(0xFFB85D4B),
    Color(0xFF9C4A34),
    Color(0xFF7D3524),
  ];

  static const List<Color> _reasoningLevelColors = <Color>[
    Color(0xFFFFC107),
    Color(0xFFBFDBFE),
    Color(0xFFFFF4F0),
    Color(0xFFFFCF9E),
    Color(0xFFFFEFD9),
  ];

  static const Color _searchFill = Color(0xFF3B82F6);
  static const Color _searchTextOn = Color(0xFFF3F7FF);

  TextEditingController get _effectiveController =>
      widget.controller ?? (_internalController ??= TextEditingController());

  int get _effectiveReasoningLevel =>
      widget.onCycleReasoning != null
          ? widget.reasoningLevel.clamp(0, 4)
          : _localReasoningLevel;

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  void _handleCycleReasoning() {
    HapticFeedback.lightImpact();
    if (widget.onCycleReasoning != null) {
      widget.onCycleReasoning!();
    } else {
      setState(() => _localReasoningLevel = (_localReasoningLevel + 1) % 5);
    }
  }

  void _handleToggleSearch() {
    HapticFeedback.lightImpact();
    if (widget.onToggleSearch != null) {
      widget.onToggleSearch!();
    } else {
      setState(() => settings.setWebSearch(!settings.webSearchEnabled));
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
                      hintText: 'Сообщение',
                      hintStyle: TextStyle(color: Color(0xFFA8A096)),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.fromLTRB(16, 2, 16, 11.6),
                    ),
                    minLines: 1,
                    maxLines: 6,
                  ),
                  const SizedBox(height: 13.3),
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _reasoningCapsule(),
                              if (widget.config.supportsWebSearch) ...[
                                const SizedBox(width: 8),
                                _searchCapsule(p),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        tooltip: 'Голосовой ввод',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                        visualDensity: VisualDensity.compact,
                        iconSize: 28,
                        icon: Icon(Icons.mic, size: 28, color: p.muted),
                        onPressed: widget.streaming ? null : widget.onToggleMic,
                      ),
                      if (widget.config.supportsAttachments) _attachButton(p),
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

  Widget _attachButton(Palette p) {
    return IconButton(
      tooltip: 'Прикрепить файл',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      visualDensity: VisualDensity.compact,
      iconSize: 26,
      icon: Icon(Icons.attach_file, size: 26, color: p.muted),
      onPressed: widget.streaming ? null : widget.onAttach,
    );
  }

  Widget _sendButton(Palette p) {
    return IconButton.filled(
      tooltip: widget.streaming ? 'Остановить' : 'Отправить',
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

  Widget _reasoningCapsule() {
    final level = _effectiveReasoningLevel;
    final label = _reasoningLabels[level];
    final fill = _reasoningFills[level];
    final levelColor = _reasoningLevelColors[level];
    final Widget leading;
    if (level == 0) {
      leading = Icon(Icons.speed, size: 32, color: levelColor);
    } else if (level == 1) {
      leading = Icon(Icons.lightbulb_outline, size: 32, color: levelColor);
    } else if (level == 2) {
      leading = Icon(Icons.troubleshoot, size: 32, color: levelColor);
    } else if (level == 4) {
      leading = Icon(Icons.biotech, size: 32, color: levelColor);
    } else {
      leading = Image.asset(
        'assets/icons/brain_high.png',
        width: 32,
        height: 32,
        fit: BoxFit.contain,
      );
    }
    return Tooltip(
      message: 'Уровень размышлений: $label',
      child: InkWell(
        borderRadius: BorderRadius.circular(_radius),
        onTap: widget.streaming ? null : _handleCycleReasoning,
        child: Container(
          height: 36,
          constraints: const BoxConstraints(minWidth: 112),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: fill),
            boxShadow: [
              BoxShadow(
                color: fill.withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              leading,
              const SizedBox(width: 6),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: levelColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchCapsule(Palette p) {
    final on = settings.webSearchEnabled;
    return InkWell(
      borderRadius: BorderRadius.circular(_radius),
      onTap: widget.streaming ? null : _handleToggleSearch,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 36,
        padding: const EdgeInsets.only(left: 12, right: 24),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: on ? _searchFill : Colors.transparent,
          borderRadius: BorderRadius.circular(_radius),
          border: Border.all(color: on ? _searchFill : p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/icons/search.svg',
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                on ? _searchTextOn : p.muted,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Поиск',
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: on ? _searchTextOn : p.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
