// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_state.dart';
import '../core/generation/generation_event.dart';
import '../core/generation/generation_request.dart';
import '../core/generation/generation_service.dart';
import '../core/generation/images_api_executor.dart';
import '../core/generation/model_type_override_store.dart';
import '../core/models/tool_media.dart';
import '../models/tool.dart';

/// Прогресс асинхронной медиа-задачи модели-инструмента.
class ModelToolProgress {
  /// Идентификатор задачи (виден в чате, нужен для возобновления
  /// после перезапуска без новой оплаты).
  final String jobId;

  /// Процент (0..100).
  final double percent;

  const ModelToolProgress({required this.jobId, this.percent = 0});
}

/// Завершение вызова модели-инструмента: текст и/или типизированное
/// медиа ([ToolMedia]), которое материализуется в чате, а не «текст
/// вместо картинки».
class ModelToolDone {
  final bool ok;
  final String text;
  final List<ToolMedia> media;

  const ModelToolDone({
    required this.ok,
    this.text = '',
    this.media = const <ToolMedia>[],
  });
}

class _ToolConn {
  final String baseUrl;
  final String apiKey;
  const _ToolConn(this.baseUrl, this.apiKey);
}

/// Потоковый запуск модели-инструмента: тип модели решает КАТАЛОГ
/// (`ModelTypeOverrideStore.resolveType`), а не захардкоженный список:
///  - текстовая модель — обычный (не потоковый) запрос chat/completions;
///  - картинка — единый `ImagesApiExecutor` (параметры/дефолты — каталог);
///  - видео — асинхронная задача через `GenerationService`, прогресс
///    отдаётся событиями [ModelToolProgress] (jobId/percent).
///
/// NOTE(heal1): постоянное место этого кода — services/model_tool.dart
/// (метод `ModelToolRunner.runStream`). По логу CI у `ModelToolRunner`
/// в репозитории нет `runStream` и событий ModelToolProgress/Done, а сам
/// файл не был прислан. Пока реализация живёт здесь; сигнатуры совместимы
/// с вызовом из `ChatService.sendMessage`. Как только model_tool.dart
/// появится с настоящим `runStream`, вызов в ChatService переключить
/// обратно на `ModelToolRunner.runStream`, а этот файл удалить.
class ModelToolStreamRunner {
  static const Duration _timeout = Duration(seconds: 60);

  static Stream<Object> run(Tool tool, String arguments) async* {
    final modelId = tool.modelId.trim();
    if (modelId.isEmpty) {
      yield const ModelToolDone(
        ok: false,
        text: 'Ошибка: у инструмента-модели не задан идентификатор модели.',
      );
      return;
    }
    final prompt = _promptFromArguments(arguments);
    if (prompt.isEmpty) {
      yield const ModelToolDone(
        ok: false,
        text: 'Ошибка: пустой промпт для модели-инструмента.',
      );
      return;
    }
    final conn = _connectionFor(tool);
    if (conn.baseUrl.isEmpty || conn.apiKey.isEmpty) {
      yield const ModelToolDone(
        ok: false,
        text: 'Ошибка: не задан адрес или ключ модели-инструмента.',
      );
      return;
    }
    String type;
    try {
      type = (await ModelTypeOverrideStore.instance.resolveType(modelId))
          .trim()
          .toLowerCase();
    } catch (_) {
      type = '';
    }
    if (type == 'video') {
      yield* _runVideo(conn, modelId, prompt);
      return;
    }
    if (type == 'image') {
      yield* _runImage(conn, modelId, prompt);
      return;
    }
    yield* _runText(conn, modelId, prompt);
  }

  /// Промпт из аргументов вызова: JSON-объект с известными ключами
  /// либо сырая строка.
  static String _promptFromArguments(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    try {
      final j = jsonDecode(s);
      if (j is Map) {
        for (final key in const <String>[
          'prompt',
          'query',
          'text',
          'input',
          'q',
          'запрос',
        ]) {
          final v = j[key];
          if (v is String && v.trim().isNotEmpty) return v.trim();
        }
        for (final v in j.values) {
          if (v is String && v.trim().isNotEmpty) return v.trim();
        }
      }
    } catch (_) {}
    return s;
  }

  /// Подключение инструмента: адрес/ключ из настроек инструмента,
  /// недостающее — из активного подключения пользователя.
  static _ToolConn _connectionFor(Tool tool) {
    var base = tool.baseUrl.trim();
    var key = '';
    for (final e in tool.headers.entries) {
      if (e.key.toLowerCase() != 'authorization') continue;
      var v = e.value.trim();
      if (v.toLowerCase().startsWith('bearer ')) {
        v = v.substring(7).trim();
      }
      if (v.isNotEmpty) key = v;
    }
    if (base.isEmpty || key.isEmpty) {
      try {
        final cfg = effectiveConfig();
        if (base.isEmpty) base = cfg.baseUrl.trim();
        if (key.isEmpty) key = cfg.apiKey.trim();
      } catch (_) {}
    }
    return _ToolConn(
      base.replaceAll(RegExp(r'/+$'), ''),
      key.replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), ''),
    );
  }

  /// Текстовая модель-инструмент: обычный (не потоковый) запрос.
  static Stream<Object> _runText(
    _ToolConn conn,
    String modelId,
    String prompt,
  ) async* {
    final client = http.Client();
    try {
      final resp = await client
          .post(
            Uri.parse('${conn.baseUrl}/chat/completions'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${conn.apiKey}',
            },
            body: jsonEncode(<String, dynamic>{
              'model': modelId,
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'user', 'content': prompt},
              ],
              'stream': false,
            }),
          )
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        yield ModelToolDone(
          ok: false,
          text: 'Ошибка HTTP ${resp.statusCode} от модели-инструмента.',
        );
        return;
      }
      String text = '';
      try {
        final j = jsonDecode(resp.body);
        if (j is Map) {
          final choices = j['choices'];
          if (choices is List && choices.isNotEmpty) {
            final m = (choices[0] as Map)['message'];
            if (m is Map) {
              final c = m['content'];
              if (c is String) text = c;
            }
          }
        }
      } catch (_) {}
      if (text.trim().isEmpty) {
        yield const ModelToolDone(
          ok: false,
          text: 'Модель-инструмент не вернула текст.',
        );
        return;
      }
      yield ModelToolDone(ok: true, text: text);
    } on TimeoutException {
      yield const ModelToolDone(
        ok: false,
        text: 'Модель-инструмент не ответила за 60 секунд.',
      );
    } catch (e) {
      yield ModelToolDone(ok: false, text: 'Ошибка модели-инструмента: $e');
    } finally {
      client.close();
    }
  }

  /// Картинка: единый исполнитель генерации изображений (перевод
  /// параметров и дефолты — из каталога модели, blacklist warnings).
  static Stream<Object> _runImage(
    _ToolConn conn,
    String modelId,
    String prompt,
  ) async* {
    final executor = ImagesApiExecutor();
    try {
      yield* _mapMediaEvents(
        executor.run(_mediaRequest(conn, modelId, prompt, 'image')),
        kind: 'image',
      );
    } catch (e) {
      yield ModelToolDone(ok: false, text: 'Ошибка медиа-модели: $e');
    }
  }

  /// Видео: асинхронная задача через фасад генерации; прогресс —
  /// событиями [ModelToolProgress] (jobId — для восстановления).
  static Stream<Object> _runVideo(
    _ToolConn conn,
    String modelId,
    String prompt,
  ) async* {
    final service = GenerationService();
    try {
      yield* _mapMediaEvents(
        service.generate(_mediaRequest(conn, modelId, prompt, 'video')),
        kind: 'video',
      );
    } catch (e) {
      yield ModelToolDone(ok: false, text: 'Ошибка медиа-модели: $e');
    } finally {
      service.cancel();
    }
  }

  static GenerationRequest _mediaRequest(
    _ToolConn conn,
    String modelId,
    String prompt,
    String routeHint,
  ) {
    return GenerationRequest(
      baseUrl: conn.baseUrl,
      apiKey: conn.apiKey,
      model: modelId,
      messages: <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': prompt},
      ],
      stream: false,
      parameters: const <String, dynamic>{},
      estimatedUsd: null,
      routeHint: routeHint,
    );
  }

  /// События медиа-генерации -> события модели-инструмента.
  static Stream<Object> _mapMediaEvents(
    Stream<GenerationEvent> events, {
    required String kind,
  }) async* {
    await for (final ev in events) {
      if (ev is GenProgress) {
        yield ModelToolProgress(jobId: ev.jobId, percent: ev.percent);
      } else if (ev is GenCompleted) {
        final path = ev.localPath.trim();
        final url = path.isNotEmpty ? path : ev.remoteUrl.trim();
        if (url.isEmpty) {
          yield const ModelToolDone(
            ok: false,
            text: 'Медиа-модель не вернула результат.',
          );
          return;
        }
        yield ModelToolDone(
          ok: true,
          text: 'Медиа-результат: $url',
          media: <ToolMedia>[ToolMedia(url: url, kind: kind)],
        );
        return;
      } else if (ev is GenerationFailure) {
        yield ModelToolDone(ok: false, text: ev.error.message);
        return;
      }
    }
    yield const ModelToolDone(
      ok: false,
      text: 'Медиа-модель не завершила генерацию.',
    );
  }
}
