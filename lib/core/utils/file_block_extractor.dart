// Copyright (c) 2026 Minkail. All rights reserved.

/// Один файл, извлечённый из ответа модели.
class ExtractedFile {
  /// Содержимое блока кода (текст файла без ограждений ```).
  final String content;

  /// Имя файла из строки языка (name=filename.ext).
  final String filename;

  /// Язык блока ('html', 'python', ''); пустая строка — язык не указан.
  final String language;

  const ExtractedFile({
    required this.content,
    required this.filename,
    this.language = '',
  });

  @override
  String toString() => 'ExtractedFile($filename, $language)';
}

/// Парсер файлов из ответа модели: ищет в тексте ограждённые блоки кода
/// вида ```lang name=filename.ext ... ``` и возвращает список [ExtractedFile].
///
/// Формат блока задан инструкцией kFileBlockInstruction
/// (lib/services/chat_service.dart): имя файла указывается в строке
/// открывающего ограждения после языка через `name=`. Блоки без имени
/// файла (обычный код в ответе) игнорируются.
abstract final class FileBlockExtractor {
  /// Строка открывающего ограждения: ```язык прочее
  static final RegExp _openRe = RegExp(r'^```[ \t]*(\S+)?(.*)$');

  /// Строка закрывающего ограждения: ``` (возможно с пробелами).
  static final RegExp _closeRe = RegExp(r'^```[ \t]*$');

  /// Имя файла внутри строки ограждения: name=filename.ext
  static final RegExp _nameRe = RegExp(r'name\s*=\s*(\S+)');

  /// Извлекает все файлы из текста ответа. Незакрытые блоки,
  /// блоки без имени файла и битые записи пропускаются.
  static List<ExtractedFile> extract(String raw) {
    final out = <ExtractedFile>[];
    final lines = raw.split('\n');
    var i = 0;
    while (i < lines.length) {
      final m = _openRe.firstMatch(lines[i]);
      var lang = (m?.group(1) ?? '').trim();
      var tail = m?.group(2) ?? '';
      // Случай «``` name=index.html» без языка: слово уходит в tail.
      if (lang.startsWith('name=')) {
        tail = ' $lang';
        lang = '';
      }
      final nameMatch = m == null ? null : _nameRe.firstMatch(tail);
      if (nameMatch == null) {
        i++;
        continue;
      }
      var j = i + 1;
      final codeLines = <String>[];
      var closed = false;
      while (j < lines.length) {
        if (_closeRe.hasMatch(lines[j])) {
          closed = true;
          break;
        }
        codeLines.add(lines[j]);
        j++;
      }
      if (closed) {
        final name = sanitizeFileName(nameMatch.group(1)!.trim());
        if (name.isNotEmpty) {
          out.add(ExtractedFile(
            content: codeLines.join('\n'),
            filename: name,
            language: lang,
          ));
        }
        i = j + 1;
      } else {
        i++;
      }
    }
    return out;
  }

  /// Безопасное имя файла: запрещённые для файловой системы символы
  /// заменяются на '_'; пустая строка возвращает пустую строку.
  static String sanitizeFileName(String raw) =>
      raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}
