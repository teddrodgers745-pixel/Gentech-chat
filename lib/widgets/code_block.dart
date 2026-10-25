// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Блок кода внутри сообщения чата: моноширинный шрифт, горизонтальная
/// прокрутка длинных строк, кнопка копирования и лёгкая подсветка синтаксиса
/// (собственная, без внешних зависимостей).
class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language,
  });

  final String code;
  final String? language;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  static const _bg = Color(0xFF1B1815);
  static const _border = Color(0xFF332C25);
  static const _headerBg = Color(0xFF241F1A);
  static const _copper = Color(0xFFC68B5B);
  static const _muted = Color(0xFF9C9188);

  bool _copied = false;

  static const _monoFont = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: ['monospace'],
  );

  static const _codeStyle = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: ['monospace'],
    fontSize: 13.5,
    height: 1.55,
  );

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.code));
      if (!mounted) return;
      setState(() => _copied = true);
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      setState(() => _copied = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Не удалось скопировать код')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.language;
    final label = (lang == null || lang.trim().isEmpty) ? 'код' : lang.trim();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: _headerBg,
            padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _monoFont.merge(
                      const TextStyle(
                        fontSize: 11,
                        color: _muted,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 30,
                  width: 30,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    tooltip: 'Копировать',
                    color: _copied ? _copper : _muted,
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_rounded,
                    ),
                    onPressed: _copy,
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: SelectableText.rich(
              TextSpan(
                style: _codeStyle,
                children: CodeHighlighter.highlight(widget.code),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Очень лёгкая подсветка: комментарии, строки, числа и ключевые слова.
/// Специально написана вручную, чтобы не тянуть тяжёлые пакеты подсветки.
class CodeHighlighter {
  CodeHighlighter._();

  static const _plain = Color(0xFFE8E0D6);
  static const _keyword = Color(0xFFD8A268);
  static const _string = Color(0xFF9CBF8E);
  static const _comment = Color(0xFF79706A);
  static const _number = Color(0xFFD8B36A);

  static const _keywords = <String>{
    'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'default', 'def', 'do', 'double', 'else',
    'enum', 'extends', 'extension', 'external', 'false', 'final', 'finally',
    'float', 'for', 'function', 'get', 'if', 'implements', 'import', 'in',
    'int', 'interface', 'is', 'let', 'late', 'library', 'mixin', 'new',
    'null', 'operator', 'part', 'private', 'protected', 'public', 'return',
    'sealed', 'set', 'static', 'super', 'switch', 'sync', 'this', 'throw',
    'true', 'try', 'type', 'typedef', 'var', 'void', 'while', 'with', 'yield',
  };

  static final _pattern = RegExp(
    r'(//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/)'
    r'|("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`)'
    r'|(\b\d+(?:\.\d+)?\b)'
    r'|([A-Za-z_$][A-Za-z0-9_$]*)',
  );

  static List<TextSpan> highlight(String code) {
    if (code.isEmpty) {
      return const [TextSpan(text: '')];
    }
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _pattern.allMatches(code)) {
      if (m.start > last) {
        spans.add(_span(code.substring(last, m.start), _plain));
      }
      final text = m.group(0)!;
      final TextStyle style;
      if (m.group(1) != null) {
        style = const TextStyle(color: _comment);
      } else if (m.group(2) != null) {
        style = const TextStyle(color: _string);
      } else if (m.group(3) != null) {
        style = const TextStyle(color: _number);
      } else if (_keywords.contains(text)) {
        style = const TextStyle(color: _keyword);
      } else {
        style = const TextStyle(color: _plain);
      }
      spans.add(TextSpan(text: text, style: style));
      last = m.end;
    }
    if (last < code.length) {
      spans.add(_span(code.substring(last), _plain));
    }
    return spans;
  }

  static TextSpan _span(String text, Color color) => TextSpan(
        text: text,
        style: TextStyle(color: color),
      );
}
