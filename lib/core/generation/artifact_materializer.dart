// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
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
  static Future<String?> materialize(
    String url, {
    http.Client? client,
    String prompt = '',
    String modelId = '',
    double? cost,
  }) async {
    final trimmed = url.trim();
    if (trimmed.startsWith('data:')) {
      return materializeDataUrl(
        trimmed,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      );
    }
    final u = Uri.tryParse(trimmed);
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
      await registerImage(
        file.path,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      );
      return file.path;
    } catch (_) {
      return null;
    } finally {
      if (own) c.close();
    }
  }

  /// Сохраняет строку вида data:image/...;base64,... в локальный файл
  /// Documents/GenTech/images. Возвращает путь файла либо null, если
  /// строка не является data URL изображения, декодирование не удалось
  /// или содержимое не похоже на картинку.
  static Future<String?> materializeDataUrl(
    String dataUrl, {
    String prompt = '',
    String modelId = '',
    double? cost,
  }) async {
    final m = RegExp(
      r'^data:image/([a-zA-Z0-9.+-]+);base64,(.+)$',
      dotAll: true,
    ).firstMatch(dataUrl.trim());
    if (m == null) return null;
    final mime = m.group(1)!.toLowerCase();
    final raw = m.group(2)!.replaceAll(RegExp(r'\s'), '');
    if (raw.isEmpty) return null;
    final bytes = base64Decode(raw);
    if (bytes.isEmpty || bytes.length > _maxBytes) return null;
    if (!_looksLikeImage(bytes)) return null;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final folder = Directory('${docs.path}/GenTech/images');
      await folder.create(recursive: true);
      final file = File(
        '${folder.path}/img_${DateTime.now().millisecondsSinceEpoch}'
        '${_extFromMime(mime)}',
      );
      await file.writeAsBytes(bytes, flush: true);
      await registerImage(
        file.path,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Регистрирует сохранённое изображение в [ArtifactRepository]:
  /// артефакт попадает в JSON-индекс галереи. Ошибка регистрации
  /// не влияет на результат материализации.
  static Future<void> registerImage(
    String path, {
    String prompt = '',
    String modelId = '',
    double? cost,
  }) async {
    try {
      await ArtifactRepository.instance.register(Artifact(
        id: newId(),
        kind: Artifact.kindImage,
        localPath: path,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      ));
    } catch (_) {}
  }

  /// Регистрирует сохранённое видео в [ArtifactRepository].
  static Future<void> registerVideo(
    String path, {
    String prompt = '',
    String modelId = '',
    double? cost,
  }) async {
    try {
      await ArtifactRepository.instance.register(Artifact(
        id: newId(),
        kind: Artifact.kindVideo,
        localPath: path,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      ));
    } catch (_) {}
  }

  /// Расширение файла по mime-типу из data URL; по умолчанию .png.
  static String _extFromMime(String mime) {
    if (mime.contains('jpeg') || mime.contains('jpg')) return '.jpg';
    if (mime.contains('webp')) return '.webp';
    if (mime.contains('gif')) return '.gif';
    if (mime.contains('bmp')) return '.bmp';
    return '.png';
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

  // ---------- видео ----------

  /// Таймаут и лимит размера для видео (ролики заметно больше картинок).
  static const Duration _videoTimeout = Duration(seconds: 300);
  static const int _maxVideoBytes = 200 * 1024 * 1024;

  /// Скачивает видео [url] и сохраняет в Documents/GenTech/videos.
  /// Возвращает абсолютный путь файла либо null: сеть недоступна,
  /// содержимое не похоже на видео, ошибка записи.
  static Future<String?> materializeVideo(
    String url, {
    http.Client? client,
    String prompt = '',
    String modelId = '',
    double? cost,
  }) async {
    final trimmed = url.trim();
    if (trimmed.startsWith('data:')) {
      return _materializeVideoDataUrl(
        trimmed,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      );
    }
    final u = Uri.tryParse(trimmed);
    if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final resp = await c.get(u).timeout(_videoTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final bytes = resp.bodyBytes;
      if (bytes.isEmpty || bytes.length > _maxVideoBytes) return null;
      if (!_looksLikeVideo(bytes, resp)) return null;
      final docs = await getApplicationDocumentsDirectory();
      final folder = Directory('${docs.path}/GenTech/videos');
      await folder.create(recursive: true);
      final file = File(
        '${folder.path}/vid_${DateTime.now().millisecondsSinceEpoch}'
        '${_videoExt(resp, trimmed)}',
      );
      await file.writeAsBytes(bytes, flush: true);
      await registerVideo(
        file.path,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      );
      return file.path;
    } catch (_) {
      return null;
    } finally {
      if (own) c.close();
    }
  }

  /// Сохраняет data URL вида data:video/mp4;base64,... в локальный файл.
  static Future<String?> _materializeVideoDataUrl(
    String dataUrl, {
    String prompt = '',
    String modelId = '',
    double? cost,
  }) async {
    final m = RegExp(
      r'^data:video/([a-zA-Z0-9.+-]+);base64,(.+)$',
      dotAll: true,
    ).firstMatch(dataUrl.trim());
    if (m == null) return null;
    final mime = m.group(1)!.toLowerCase();
    final raw = m.group(2)!.replaceAll(RegExp(r'\s'), '');
    if (raw.isEmpty) return null;
    List<int> bytes;
    try {
      bytes = base64Decode(raw);
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty || bytes.length > _maxVideoBytes) return null;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final folder = Directory('${docs.path}/GenTech/videos');
      await folder.create(recursive: true);
      final file = File(
        '${folder.path}/vid_${DateTime.now().millisecondsSinceEpoch}'
        '${_videoExtFromMime(mime)}',
      );
      await file.writeAsBytes(bytes, flush: true);
      await registerVideo(
        file.path,
        prompt: prompt,
        modelId: modelId,
        cost: cost,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Похоже ли содержимое на видеофайл: mp4-магия 'ftyp' на смещении 4,
  /// либо Content-Type с video/mp4/octet-stream.
  static bool _looksLikeVideo(List<int> b, http.Response resp) {
    if (b.length >= 12 &&
        b[4] == 0x66 && // 'f'
        b[5] == 0x74 && // 't'
        b[6] == 0x79 && // 'y'
        b[7] == 0x70) {
      return true; // 'ftyp'
    }
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    return ct.contains('video') ||
        ct.contains('mp4') ||
        ct.contains('octet-stream');
  }

  static String _videoExtFromMime(String mime) {
    if (mime.contains('webm')) return '.webm';
    if (mime.contains('quicktime') || mime.contains('mov')) return '.mov';
    return '.mp4';
  }

  /// Расширение по Content-Type, затем по пути URL; по умолчанию .mp4.
  static String _videoExt(http.Response resp, String url) {
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    if (ct.contains('webm')) return '.webm';
    if (ct.contains('quicktime')) return '.mov';
    final path = url.split('?').first.toLowerCase();
    for (final e in const ['.mp4', '.webm', '.mov']) {
      if (path.endsWith(e)) return e;
    }
    return '.mp4';
  }
}
