// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../theme.dart';

/// Фрагмент разобранного сообщения модели: обычный markdown либо файл
/// (блок кода, у которого в строке языка указано имя файла).
class ContentSegment {
  final String text;
  final String fileName;
  final String code;
  final String lang;

  const ContentSegment.text(this.text)
      : fileName = '',
        code = '',
        lang = '';

  const ContentSegment.file(this.fileName, this.code, this.lang)
      : text = '';

  bool get isFile => fileName.isNotEmpty;
}

/// Разбор ответа: находим ограждённые блоки кода вида
/// ```html name=index.html ... ``` и превращаем их в файловые сегменты.
/// Обычный текст и код без имени файла остаются нетронутыми.
List<ContentSegment> splitFileBlocks(String raw) {
  final segments = <ContentSegment>[];
  final openRe = RegExp(r'^```[ \t]*(\S+)?(.*)$');
  final closeRe = RegExp(r'^```[ \t]*$');
  final nameRe = RegExp(r'name\s*=\s*(\S+)');
  final buf = <String>[];
  final lines = raw.split('\n');
  var i = 0;
  while (i < lines.length) {
    final m = openRe.firstMatch(lines[i]);
    var lang = (m?.group(1) ?? '').trim();
    var tail = m?.group(2) ?? '';
    // Случай «``` name=index.html» без языка: слово уходит в tail.
    if (lang.startsWith('name=')) {
      tail = ' $lang';
      lang = '';
    }
    if (m != null && nameRe.firstMatch(tail) != null) {
      final nameMatch = nameRe.firstMatch(tail)!;
      var j = i + 1;
      final codeLines = <String>[];
      var closed = false;
      while (j < lines.length) {
        if (closeRe.hasMatch(lines[j])) {
          closed = true;
          break;
        }
        codeLines.add(lines[j]);
        j++;
      }
      if (closed) {
        if (buf.isNotEmpty) {
          segments.add(ContentSegment.text(buf.join('\n')));
          buf.clear();
        }
        segments.add(ContentSegment.file(
          nameMatch.group(1)!.trim(),
          codeLines.join('\n'),
          lang,
        ));
        i = j + 1;
        continue;
      }
    }
    buf.add(lines[i]);
    i++;
  }
  if (buf.isNotEmpty) segments.add(ContentSegment.text(buf.join('\n')));
  return segments;
}

/// Карточка файла, созданного моделью: иконка, имя, размер
/// и кнопки «Сохранить» (Documents/GenTech) и «Поделиться».
class FileCard extends StatelessWidget {
  final String fileName;
  final String code;
  final String lang;

  const FileCard({
    super.key,
    required this.fileName,
    required this.code,
    this.lang = '',
  });

  static String _safeName(String raw) {
    final s = raw.trim().isEmpty ? 'file.txt' : raw.trim();
    return s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  static String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    }
    return '$bytes Б';
  }

  static IconData _iconFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final ext = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'html':
      case 'htm':
        return Icons.html;
      case 'js':
      case 'ts':
        return Icons.javascript;
      case 'py':
        return Icons.terminal;
      case 'md':
      case 'txt':
        return Icons.article_outlined;
      default:
        return Icons.code_rounded;
    }
  }

  /// Запись содержимого в папку; при совпадении имени — суффикс времени.
  Future<File> _writeToDir(Directory dir) async {
    final safe = _safeName(fileName);
    var file = File('${dir.path}/$safe');
    if (await file.exists()) {
      final dot = safe.lastIndexOf('.');
      final base = dot > 0 ? safe.substring(0, dot) : safe;
      final ext = dot > 0 ? safe.substring(dot) : '';
      file = File(
        '${dir.path}/${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
    }
    await file.writeAsString(code, flush: true);
    return file;
  }

  void _snack(BuildContext ctx, String text) {
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _save(BuildContext context) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final folder = Directory('${docs.path}/GenTech');
      await folder.create(recursive: true);
      final file = await _writeToDir(folder);
      if (!context.mounted) return;
      _snack(context, 'Файл сохранён: ${file.path}');
    } catch (_) {
      if (!context.mounted) return;
      _snack(context, 'Не удалось сохранить файл');
    }
  }

  Future<void> _share(BuildContext context) async {
    try {
      final tmp = await getTemporaryDirectory();
      final file = await _writeToDir(tmp);
      await Share.shareXFiles([XFile(file.path)]);
    } catch (_) {
      if (!context.mounted) return;
      _snack(context, 'Не удалось поделиться файлом');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = settings.palette;
        final bytes = utf8.encode(code).length;
        final label = lang.trim().isEmpty ? 'файл' : lang.trim();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(_iconFor(fileName), size: 22, color: p.accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: fontStyle(
                            settings.codeFont,
                            size: 14,
                            weight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$label · ${_fmtSize(bytes)}',
                          style: TextStyle(fontSize: 12, color: p.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _save(context),
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('Сохранить'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _share(context),
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: const Text('Поделиться'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
