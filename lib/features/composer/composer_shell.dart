// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme.dart';
import 'composer_controller.dart';
import 'composer_mode.dart';
import 'widgets/cost_estimate_badge.dart';

/// Панель ввода (композер): поле сообщения и кнопки инструментов,
/// которые разрешает активный [ComposerMode]. Пока не подключена к
/// экрану чата — самостоятельный виджет для следующего этапа.
///
/// Работает только через [ComposerController]: ни режимы, ни инструменты
/// не вводятся напрямую, состояние приходит от контроллера.
class ComposerShell extends StatefulWidget {
  /// Контроллер можно передать снаружи (владелец тогда сам его освобождает);
  /// по умолчанию создаётся внутренний и освобождается виджетом.
  final ComposerController? controller;

  /// Колбэки инструментов. Реальную отправку подключает вызывающий код;
  /// null означает «кнопка не активна».
  final VoidCallback? onSend;
  final VoidCallback? onStop;
  final VoidCallback? onAttach;
  final VoidCallback? onToggleMic;

  const ComposerShell({
    super.key,
    this.controller,
    this.onSend,
    this.onStop,
    this.onAttach,
    this.onToggleMic,
  });

  @override
  State<ComposerShell> createState() => _ComposerShellState();
}

class _ComposerShellState extends State<ComposerShell> {
  ComposerController? _internal;
  final FocusNode _focus = FocusNode();

  ComposerController get _ctl =>
      widget.controller ?? (_internal ??= ComposerController());

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant ComposerShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?.removeListener(_onChanged);
      _internal?.dispose();
      _internal = null;
      _ctl.addListener(_onChanged);
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctl.removeListener(_onChanged);
    _internal?.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, presets]),
      builder: (context, _) {
        final p = settings.palette;
        final mode = _ctl.mode;
        final streaming = _ctl.streaming;

        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Container(
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(24),
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
                  controller: _ctl.text,
                  focusNode: _focus,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  cursorColor: p.accent,
                  enabled: !streaming || true,
                  style: fontStyle(
                    settings.bodyFont,
                    size: 16,
                    color: p.text,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    hintText: 'Сообщение',
                    hintStyle: TextStyle(color: p.muted),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                  ),
                  minLines: 1,
                  maxLines: 6,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _modeBadge(mode, p),
                            CostEstimateBadge(
                              modelId: effectiveConfig().model,
                              p: p,
                              textController: _ctl.text,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (mode.supports(ComposerTool.attach) && !streaming)
                      _iconButton(
                        tooltip: 'Прикрепить файл',
                        icon: Icons.attach_file,
                        color: p.muted,
                        onPressed: widget.onAttach,
                      ),
                    if (mode.supports(ComposerTool.mic) && !streaming)
                      _iconButton(
                        tooltip: 'Голосовой ввод',
                        icon: Icons.mic_none_rounded,
                        color: p.muted,
                        onPressed: widget.onToggleMic,
                      ),
                    const SizedBox(width: 4),
                    _actionButton(p, mode, streaming),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Небольшая подпись активного режима слева — аккуратный чип
  /// в общей тёплой гамме.
  Widget _modeBadge(ComposerMode mode, Palette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        mode.label,
        maxLines: 1,
        style: TextStyle(
          fontSize: 12,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: p.accent,
        ),
      ),
    );
  }

  Widget _iconButton({
    required String tooltip,
    required IconData icon,
    required Color color,
    VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      visualDensity: VisualDensity.compact,
      iconSize: 24,
      icon: Icon(icon, size: 24, color: color),
      onPressed: onPressed,
    );
  }

  /// Главная кнопка справа: «отправить» либо «стоп» во время генерации.
  /// Активна только когда есть текст (или идёт генерация).
  Widget _actionButton(Palette p, ComposerMode mode, bool streaming) {
    final showStop = streaming && mode.supports(ComposerTool.stop);
    final showSend = !streaming && mode.supports(ComposerTool.send);
    if (!showStop && !showSend) return const SizedBox(width: 48, height: 48);

    final enabled = showStop || (_ctl.hasText && widget.onSend != null);
    return IconButton.filled(
      tooltip: showStop ? 'Остановить' : 'Отправить',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: enabled
          ? (showStop ? (widget.onStop ?? () {}) : widget.onSend)
          : null,
      style: IconButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.accent.withValues(alpha: 0.35),
        shape: const CircleBorder(),
      ),
      icon: Icon(
        showStop ? Icons.stop_rounded : Icons.rocket_launch_rounded,
        size: 26,
      ),
    );
  }
}
