// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Анимированная плашка «🧠 Думает... Nс» для reasoning-моделей.
///
/// Показывается, пока идёт стриминг, а текст ответа ещё не пришёл
/// (модели o1/o3/gemini-thinking думают 10-20 секунд до первого токена).
/// Таймер счётчика секунд запускается при появлении виджета в дереве
/// (старт стрима с пустым content) и отменяется в dispose, когда пришёл
/// первый токен и плашка скрылась.
class ThinkingIndicator extends StatefulWidget {
  final Palette p;

  const ThinkingIndicator({super.key, required this.p});

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds += 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PulsingBrain(),
            const SizedBox(width: 10),
            Text(
              'Думает... ${_seconds}с',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Пульсирующая иконка 🧠: плавное изменение масштаба и прозрачности.
class _PulsingBrain extends StatefulWidget {
  const _PulsingBrain();

  @override
  State<_PulsingBrain> createState() => _PulsingBrainState();
}

class _PulsingBrainState extends State<_PulsingBrain>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_c.value);
        return Opacity(
          opacity: 0.55 + 0.45 * t,
          child: Transform.scale(
            scale: 1.0 + 0.15 * t,
            child: child,
          ),
        );
      },
      child: const Text('🧠', style: TextStyle(fontSize: 20)),
    );
  }
}
