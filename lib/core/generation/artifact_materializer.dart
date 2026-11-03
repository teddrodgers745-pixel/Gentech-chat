// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Материализация артефактов: скачивание изображения по URL из ответа
/// провайдера в локальный файл (Documents/GenTech/images).
///
/// Зачем: ссылки на картинки у провайдеров часто временные (истекают
/// через часы), а чат хранится долго. Локальная копия гарантирует, что
/// сгенерированное изображение останется видимым в истории.
abstract final class ArtifactMaterializer {
  static const Duration _timeout = Duration(seconds: 90);

  /// Верхний предел размера скачиваемого файла.
  static const int _maxBytes = 25 * 1024 * 1024;

  /// Скачивает [url] и сохраняет содержимое в Documents/GenTech/images.
  /// Возвращает абсолютный путь файла либо null: сеть недоступна, ответ
  /// не похож на изображение, ошибка записи. Вызывающий код в случае
  /// null продолжает работать с исходной ссылкой.
  static Future<String?> materialize(String url, {http.Client? client}) async {
    final u = Uri.tryParse(url.trim());
    if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final resp = await c.get(u).timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final bytes = resp.bodyBytes;
      if (bytes.isEmpty || bytes.length > _maxBytes) return null;
      if (!_looksLikeImage(bytes)) return null;
      final docs = await getApplicationDocumentsDirectory();
      final folder = Directory('${docs.path}/GenTech/images');
      await folder.create(recursive: true);
      final file = File(
        '${folder.path}/img_${DateTime.now().millisecondsSinceEpoch}'
        '${_extFrom(resp)}',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    } finally {
      if (own) c.close();
    }
  }

  /// По магическим байтам: PNG, JPEG, GIF, BMP и WEBP (RIFF....WEBP).
  /// Защита от сохранения HTML-страницы ошибки как картинки.
  static bool _looksLikeImage(List<int> b) {
    if (b.length < 4) return false;
    if (b[0] == 0x89 && b[1] == 0x50) return true; // PNG
    if (b[0] == 0xFF && b[1] == 0xD8) return true; // JPEG
    if (b[0] == 0x47 && b[1] == 0x49) return true; // GIF
    if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && // 'RI'
        b[8] == 0x57 && b[9] == 0x45) {
      return true; // WEBP (RIFF....WEBP)
    }
    return false;
  }

  /// Расширение по Content-Type, затем по пути URL; по умолчанию .png.
  static String _extFrom(http.Response resp) {
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    if (ct.contains('jpeg') || ct.contains('jpg')) return '.jpg';
    if (ct.contains('webp')) return '.webp';
    if (ct.contains('gif')) return '.gif';
    final path = resp.request?.url.path.toLowerCase() ?? '';
    for (final e in const ['.png', '.jpg', '.jpeg', '.webp', '.gif']) {
      if (path.endsWith(e)) return e == '.jpeg' ? '.jpg' : e;
    }
    return '.png';
  }
}
