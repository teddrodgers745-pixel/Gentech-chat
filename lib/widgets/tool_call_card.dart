// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../theme.dart';

/// Карточка вызова инструмента: сворачиваемая, с иконкой, названием,
/// аргументами и результатом. Показывается в общем списке сообщений чата.
class ToolCallCard extends StatefulWidget {
  final ChatMessage message;

  const ToolCallCard({super.key, required this.message});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  String _prettyArgs(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '{}';
    try {
      final d = jsonDecode(s);
      if (d is Map) {
        return const JsonEncoder.withIndent('  ').convert(d);
      }
    } catch (_) {}
    return s;
  }

  String _trimResult(String raw) {
    if (raw.length <= 4000) return raw;
    return '${raw.substring(0, 4000)}\n… показаны первые 4000 символов';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final m = widget.message;
        final running = m.toolStatus == toolStatusRunning;
        final failed = m.toolStatus == toolStatusError;
        final statusText = running
            ? 'Выполняется…'
            : failed
                ? 'Ошибка'
                : 'Готово';
        final statusColor = failed ? const Color(0xFFB3261E) : p.accent;

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: p.accent.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                        ),
                        child: running
                            ? Padding(
                                padding: const EdgeInsets.all(9),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: p.accent,
                                ),
                              )
                            : Icon(
                                failed
                                    ? Icons.error_outline_rounded
                                    : Icons.build_rounded,
                                size: 18,
                                color: statusColor,
                              ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.toolName.isEmpty ? 'Инструмент' : m.toolName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: p.text,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              statusText,
                              style: TextStyle(
                                fontSize: 12,
                                color: running ? p.muted : statusColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          Icons.expand_more,
                          size: 20,
                          color: p.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                sizeCurve: Curves.easeOutCubic,
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.toolArgs.trim().isNotEmpty) ...[
                        Text(
                          'АРГУМЕНТЫ',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: p.accent,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _monoBox(p, _prettyArgs(m.toolArgs)),
                      ],
                      if (m.toolResult.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'РЕЗУЛЬТАТ',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: p.accent,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _monoBox(p, _trimResult(m.toolResult)),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _monoBox(Palette p, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.codeBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'JetBrains Mono',
          fontFamilyFallback: const ['monospace'],
          fontSize: 12,
          height: 1.45,
          color: p.text,
        ),
      ),
    );
  }
}
