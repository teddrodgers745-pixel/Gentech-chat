// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';

/// Кнопка уровня размышлений у поля ввода: циклически переключает
/// Low -> Medium -> High. Иконка и подпись залиты «металлическим»
/// градиентом через ShaderMask (Cyan / Blue / Purple).
class ReasoningButton extends StatelessWidget {
  final int level;

  /// null — кнопка неактивна (например, во время генерации ответа).
  final VoidCallback? onTap;

  const ReasoningButton({super.key, required this.level, required this.onTap});

  static const List<String> _labels = <String>['Low', 'Medium', 'High'];

  /// Градиенты уровней: Cyan, Blue, Purple.
  static const List<List<Color>> _gradients = <List<Color>>[
    <Color>[Color(0xFF22D3EE), Color(0xFF67E8F9)],
    <Color>[Color(0xFF3B82F6), Color(0xFF60A5FA)],
    <Color>[Color(0xFFA855F7), Color(0xFFC084FC)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _gradients[level];
    return IconButton(
      tooltip: 'Уровень размышлений: ${_labels[level]}',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      onPressed: onTap,
      icon: ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(bounds),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.psychology, size: 24, color: Colors.white),
            const SizedBox(height: 1),
            Text(
              _labels[level],
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: const TextStyle(
                fontSize: 11,
                height: 1.0,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
