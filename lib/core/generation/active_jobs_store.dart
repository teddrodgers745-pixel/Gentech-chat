// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Запись асинхронной задачи генерации (видео), которая переживает
/// перезапуск приложения: идентификатор задачи у провайдера, адрес
/// и ключ провайдера, модель, промпт и текущий прогресс. Хранится
/// в SharedPreferences, чтобы после перезапуска опрос можно было
/// продолжить с того же места.
class AsyncJobRecord {
  /// Идентификатор задачи у провайдера.
  final String jobId;

  /// Base URL провайдера на момент создания задачи.
  final String baseUrl;

  /// API-ключ провайдера (нужен для авторизованного опроса статуса).
  final String apiKey;

  /// Модель, для которой создана задача.
  final String model;

  /// Промпт задачи.
  final String prompt;

  /// Последний известный прогресс в процентах (0..100).
  final double progress;

  /// Момент создания задачи.
  final DateTime createdAt;

  AsyncJobRecord({
    required this.jobId,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.prompt,
    this.progress = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'jobId': jobId,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'prompt': prompt,
        'progress': progress,
        'createdAt': createdAt.toIso8601String(),
      };

  factory AsyncJobRecord.fromJson(Map<String, dynamic> j) => AsyncJobRecord(
        jobId: (j['jobId'] as String?) ?? '',
        baseUrl: (j['baseUrl'] as String?) ?? '',
        apiKey: (j['apiKey'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        prompt: (j['prompt'] as String?) ?? '',
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        createdAt:
            DateTime.tryParse((j['createdAt'] as String?) ?? '') ??
                DateTime.now(),
      );
}

/// Хранилище активных асинхронных задач. Все операции терпимы
/// к сбоям хранилища: ошибка записи/чтения не роняет генерацию.
class ActiveJobsStore {
  ActiveJobsStore._();

  static final ActiveJobsStore instance = ActiveJobsStore._();

  static const String _key = 'active_async_jobs';

  /// Все сохранённые задачи (в порядке добавления).
  Future<List<AsyncJobRecord>> loadAll() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return const <AsyncJobRecord>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <AsyncJobRecord>[];
      final out = <AsyncJobRecord>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        try {
          out.add(AsyncJobRecord.fromJson(Map<String, dynamic>.from(e)));
        } catch (_) {
          // Битая запись пропускается.
        }
      }
      return out;
    } catch (_) {
      return const <AsyncJobRecord>[];
    }
  }

  Future<void> _persist(List<AsyncJobRecord> jobs) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _key,
        jsonEncode(jobs.map((j) => j.toJson()).toList()),
      );
    } catch (_) {
      // Хранилище недоступно — задача просто не восстановится.
    }
  }

  /// Добавляет задачу либо обновляет существующую с тем же jobId.
  Future<void> save(AsyncJobRecord record) async {
    final jobs = await loadAll();
    final i = jobs.indexWhere((j) => j.jobId == record.jobId);
    if (i >= 0) {
      jobs[i] = record;
    } else {
      jobs.add(record);
    }
    await _persist(jobs);
  }

  /// Обновляет прогресс задачи (запись создаётся заново: поля final).
  Future<void> updateProgress(String jobId, double progress) async {
    final jobs = await loadAll();
    final i = jobs.indexWhere((j) => j.jobId == jobId);
    if (i < 0) return;
    final old = jobs[i];
    jobs[i] = AsyncJobRecord(
      jobId: old.jobId,
      baseUrl: old.baseUrl,
      apiKey: old.apiKey,
      model: old.model,
      prompt: old.prompt,
      progress: progress,
      createdAt: old.createdAt,
    );
    await _persist(jobs);
  }

  /// Удаляет задачу из хранилища (успех, ошибка либо отмена).
  Future<void> remove(String jobId) async {
    final jobs = await loadAll();
    final before = jobs.length;
    jobs.removeWhere((j) => j.jobId == jobId);
    if (jobs.length != before) await _persist(jobs);
  }
}
