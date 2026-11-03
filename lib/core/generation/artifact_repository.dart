// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/artifact.dart';

/// Репозиторий артефактов: JSON-индекс в
/// Documents/GenTech/artifacts_index.json.
///
/// ChangeNotifier: галерея подписывается и перерисовывается. Все операции
/// терпимы к сбоям хранилища: ошибка чтения/записи не роняет генерацию —
/// артефакт просто не попадёт в индекс. Новые записи вставляются в начало
/// списка (свежие сверху), что удобно для сетки галереи.
class ArtifactRepository extends ChangeNotifier {
  ArtifactRepository._();

  static final ArtifactRepository instance = ArtifactRepository._();

  static const String _fileName = 'artifacts_index.json';

  final List<Artifact> _items = <Artifact>[];
  bool _loaded = false;
  bool _loading = false;

  /// Все артефакты (только для чтения, свежие сверху).
  List<Artifact> get items => List.unmodifiable(_items);

  /// Загружен ли индекс хотя бы один раз.
  bool get isLoaded => _loaded;

  /// Артефакт по идентификатору; null — не найден.
  Artifact? byId(String id) {
    for (final a in _items) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Артефакты заданного вида ([Artifact.kindImage] / [Artifact.kindVideo]).
  List<Artifact> byKind(String kind) =>
      <Artifact>[for (final a in _items) if (a.kind == kind) a];

  Future<File?> _indexFile() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/GenTech');
      await dir.create(recursive: true);
      return File('${dir.path}/$_fileName');
    } catch (_) {
      return null;
    }
  }

  /// Читает индекс с диска (один раз; повторные вызовы — no-op).
  Future<void> load() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final f = await _indexFile();
      if (f != null && await f.exists()) {
        final raw = await f.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is! Map) continue;
            try {
              final a = Artifact.fromJson(Map<String, dynamic>.from(e));
              if (a.id.isNotEmpty && byId(a.id) == null) _items.add(a);
            } catch (_) {
              // Битая запись пропускается.
            }
          }
        }
      }
    } catch (_) {
      // Битый индекс: начинаем с пустого списка.
    } finally {
      _loading = false;
      _loaded = true;
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final f = await _indexFile();
      if (f == null) return;
      await f.writeAsString(
        jsonEncode(_items.map((a) => a.toJson()).toList()),
        flush: true,
      );
    } catch (_) {
      // Хранилище недоступно — индекс останется в памяти до следующей записи.
    }
  }

  /// Добавляет артефакт либо обновляет существующий с тем же id.
  /// Перед первой записью индекс догружается с диска, чтобы не потерять
  /// прежние записи.
  Future<void> register(Artifact artifact) async {
    await load();
    final i = _items.indexWhere((x) => x.id == artifact.id);
    if (i >= 0) {
      _items[i] = artifact;
    } else {
      _items.insert(0, artifact);
    }
    await _persist();
    notifyListeners();
  }

  /// Удаляет артефакт из индекса и (по возможности) его локальный файл.
  Future<void> delete(String id) async {
    await load();
    final a = byId(id);
    if (a == null) return;
    _items.removeWhere((x) => x.id == id);
    await _persist();
    final path = a.localPath.trim();
    if (path.isNotEmpty) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // Файл занят или недоступен — запись из индекса всё равно удалена.
      }
    }
    notifyListeners();
  }
}
