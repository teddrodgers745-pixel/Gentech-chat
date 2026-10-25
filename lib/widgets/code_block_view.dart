// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Блок кода в ответе ассистента: тёмная тёплая подложка,
/// шапка с языком и кнопкой копирования, моноширинный текст.
class CodeBlockView extends StatelessWidget {
  const CodeBlockView({super.key, required this.code, this.language});

  final String code;
  final String? language;

  static const Color _bg = Color(0xFF23201C);
  static const Color _headerBg = Color(0xFF2B2723);
  static const Color _border = Color(0xFF3A342E);
  static const Color _accent = Color(0xFFC87F4A);
  static const Color _text = Color(0xFFE8E2D9);

  static const TextStyle _mono = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: <String>['monospace'],
  );

  @override
  Widget build(BuildContext context) {
    final String lang =
        (language == null || language!.trim().isEmpty) ? 'код' : language!.trim();
    return Container(
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            color: _headerBg,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    lang,
                    overflow: TextOverflow.ellipsis,
                    style: _mono.copyWith(fontSize: 12, color: _accent),
                  ),
                ),
                _CopyButton(code: code),
              ],
            ),
          ),
          SingleChildScrollView(
            horizontal: true,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              code,
              style: _mono.copyWith(fontSize: 13.5, height: 1.5, color: _text),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.code});

  final String code;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.code));
    } catch (_) {
      // Буфер обмена недоступен — молча игнорируем.
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _copied ? 'Скопировано' : 'Копировать',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _copied ? null : _copy,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            _copied ? Icons.check : Icons.copy_outlined,
            size: 18,
            color: _copied ? const Color(0xFF7FA96B) : CodeBlockView._accent,
          ),
        ),
      ),
    );
  }
}
