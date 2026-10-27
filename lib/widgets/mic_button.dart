// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

/// Кнопка микрофона у поля ввода. В покое — приглушённая иконка;
/// во время записи — пульсирующая красная иконка микрофона.
class MicButton extends StatelessWidget {
  final bool listening;
  final VoidCallback? onTap;
  final Color mutedColor;

  const MicButton({
    super.key,
    required this.listening,
    required this.onTap,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    if (listening) {
      return IconButton(
        tooltip: 'Остановить запись',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
        icon: const _PulsingMic(),
      );
    }
    return IconButton(
      tooltip: 'Голосовой ввод',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      visualDensity: VisualDensity.compact,
      iconSize: 22,
      icon: Icon(Icons.mic_none_rounded, size: 22, color: mutedColor),
      onPressed: onTap,
    );
  }
}

/// Красный микрофон с плавной пульсацией яркости.
class _PulsingMic extends StatefulWidget {
  const _PulsingMic();

  @override
  State<_PulsingMic> createState() => _PulsingMicState();
}

class _PulsingMicState extends State<_PulsingMic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE53935);
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1.0).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: const Icon(Icons.mic_rounded, size: 22, color: red),
    );
  }
}
