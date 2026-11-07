// Copyright (c) 2026 Minkail. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../app_state.dart' show settings;
import '../models/model_id_normalizer.dart';
import '../models/param_spec.dart';
import '../storage.dart';

/// Резолвер медиа-параметров (видео и изображения) по каталогу OpenRouter.
///
/// [syncCapabilities] проверяет TTL кэша (7 дней, ключ
/// `media_caps_last_sync` в SharedPreferences) и при необходимости
/// запрашивает два публичных GET-эндпоинта:
///  - `https://openrouter.ai/api/v1/videos/models` —
///    supported_durations (List<int>), supported_resolutions,
///    supported_aspect_ratios;
///  - `https://openrouter.ai/api/v1/images/models` —
///    aspect_ratio и resolution из блока supported_parameters.
///
/// Результат сохраняется в SharedPreferences (ключ `media_capabilities_v1`)
/// в виде Map<String, ModelParameters>. [getCapability] синхронно отдаёт
/// запись из кэша; null — модели в кэше нет.
///
/// Вызывается из main.dart в фоне: сбой сети никогда не влияет на запуск,
/// TTL не обновляется при неудачной синхронизации (попытка повторится
/// при следующем старте).
abstract final class GenerationCapabilityResolver {
  static const String _videoEndpoint =
      'https://openrouter.ai/api/v1/videos/models';
  static const String _imageEndpoint =
      'https://openrouter.ai/api/v1/images/models';
  static const String _cacheKey = 'media_capabilities_v1';
  static const String _lastSyncKey = 'media_caps_last_sync';
  static const Duration _ttl = Duration(days: 7);
  static const Duration _timeout = Duration(seconds: 20);

  /// Кэш в памяти: нормализованный идентификатор -> параметры.
  static Map<String, ModelParameters>? _cache;
  static bool _syncing = false;

  /// Сколько моделей сейчас в кэше (для диагностики).
  static int get cachedCount => _cache?.length ?? 0;

  /// Читает сохранённый кэш с диска (если ещё не загружен). Ошибки
  /// хранилища и битый JSON не роняют код: кэш останется пустым.
  static Future<void> loadCache() async {
    if (_cache != null) return;
    final raw = await storage.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final models = decoded['models'];
      if (models is! Map) return;
      final out = <String, ModelParameters>{};
      models.forEach((key, value) {
        if (value is! Map) return;
        try {
          final p = ModelParameters.fromJson(
            Map<String, dynamic>.from(value),
          );
          if (p.hasAny) out[key.toString()] = p;
        } catch (_) {
          // Битая запись пропускается.
        }
      });
      _cache = out;
    } catch (_) {
      // Битый кэш игнорируется: будет перезаписан следующей синхронизацией.
    }
  }

  /// Синхронизация медиа-параметров с каталогом OpenRouter.
  /// Никогда не бросает исключений наружу: любой сбой оставляет прежний
  /// кэш в силе. Метка времени `media_caps_last_sync` обновляется только
  /// при успешном получении хотя бы одного списка моделей.
  static Future<void> syncCapabilities() async {
    if (_syncing) return;
    // Проверка TTL: если последняя успешная синхронизация моложе 7 дней —
    // ничего не делаем.
    try {
      final last = await storage.getString(_lastSyncKey);
      if (last != null && last.isNotEmpty) {
        final dt = DateTime.tryParse(last);
        if (dt != null &&
            DateTime.now().difference(dt) < _ttl) {
          return;
        }
      }
    } catch (_) {
      // Хранилище недоступно — считаем, что синхронизация нужна.
    }
    _syncing = true;
    final client = http.Client();
    try {
      final video =
          await _fetchAndParse(client, _videoEndpoint, _parseVideoEntries);
      final image =
          await _fetchAndParse(client, _imageEndpoint, _parseImageEntries);
      if (video.isEmpty && image.isEmpty) {
        // Оба запроса не дали данных (сеть, статус != 2xx): TTL не
        // обновляем, чтобы следующая попытка состоялась при новом старте.
        return;
      }
      await loadCache();
      final merged = <String, ModelParameters>{
        ...?_cache,
        ...video,
        ...image,
      };
      _cache = merged;
      await _persist(merged);
      await storage.setString(
        _lastSyncKey,
        DateTime.now().toIso8601String(),
      );
    } on TimeoutException {
      // Эндпоинты не ответили вовремя: работаем с прежним кэшем.
    } catch (_) {
      // Сетевая ошибка либо недоступное хранилище: не критично.
    } finally {
      client.close();
      _syncing = false;
    }
  }

  /// GET [url] и разбор поля data через [parse]. Любая ошибка (сеть,
  /// статус, битый JSON) возвращает пустую карту — синхронизация терпима.
  static Future<Map<String, ModelParameters>> _fetchAndParse(
    http.Client client,
    String url,
    Map<String, ModelParameters> Function(List<dynamic> data) parse,
  ) async {
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      final key = settings.apiKey.trim();
      if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
      final resp = await client
          .get(Uri.parse(url), headers: headers)
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const <String, ModelParameters>{};
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return const <String, ModelParameters>{};
      final data = decoded['data'];
      if (data is! List) return const <String, ModelParameters>{};
      return parse(data);
    } on TimeoutException {
      return const <String, ModelParameters>{};
    } catch (_) {
      return const <String, ModelParameters>{};
    }
  }

  /// Сохраняет кэш в SharedPreferences. Ошибка записи не роняет код:
  /// данные останутся в памяти до следующей синхронизации.
  static Future<void> _persist(Map<String, ModelParameters> caps) async {
    try {
      await storage.setString(
        _cacheKey,
        jsonEncode(<String, dynamic>{
          'syncedAt': DateTime.now().toIso8601String(),
          'models': <String, dynamic>{
            for (final e in caps.entries) e.key: e.value.toJson(),
          },
        }),
      );
    } catch (_) {}
  }

  /// Список строк из значения произвольного типа (терпимо к List<String>,
  /// List<dynamic>); null-элементы пропускаются.
  static List<String> _strings(Object? raw) {
    if (raw is! List) return const <String>[];
    return <String>[
      for (final v in raw)
        if (v != null) v.toString(),
    ];
  }

  /// Длительности видео: список дискретных значений (4, 8, 12 ...) либо
  /// объект-диапазон {min, max}. null — данных о длительности нет.
  static DurationRange? _durationsFrom(Object? raw) {
    if (raw is List) {
      final discrete = <int>[
        for (final v in raw)
          if (v is num) v.round(),
      ];
      if (discrete.isEmpty) return null;
      return DurationRange(discrete: discrete);
    }
    if (raw is Map) {
      try {
        final m = Map<String, dynamic>.from(raw);
        final dr = DurationRange(
          min: (m['min'] as num?)?.toInt(),
          max: (m['max'] as num?)?.toInt(),
        );
        return dr.isEmpty ? null : dr;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Разбор списка видео-моделей:
  /// supported_durations (List<int>), supported_resolutions,
  /// supported_aspect_ratios.
  static Map<String, ModelParameters> _parseVideoEntries(
    List<dynamic> data,
  ) {
    final out = <String, ModelParameters>{};
    for (final e in data) {
      if (e is! Map) continue;
      final id = ((e['id'] as String?) ?? '').trim();
      if (id.isEmpty) continue;
      final durations = _durationsFrom(e['supported_durations']);
      final resolutions = _strings(e['supported_resolutions']);
      final ratios = _strings(e['supported_aspect_ratios']);
      if (durations == null && resolutions.isEmpty && ratios.isEmpty) {
        continue;
      }
      out[ModelIdNormalizer.normalize(id)] = ModelParameters(
        type: 'video',
        aspectRatios: ratios,
        durations: durations,
        resolutions: resolutions,
        confidence: 'high',
        isUserDefined: false,
      );
    }
    return out;
  }

  /// Разбор списка моделей изображений: aspect_ratio и resolution
  /// из блока supported_parameters (объект). Записи без блока либо без
  /// списков пропускаются.
  static Map<String, ModelParameters> _parseImageEntries(
    List<dynamic> data,
  ) {
    final out = <String, ModelParameters>{};
    for (final e in data) {
      if (e is! Map) continue;
      final id = ((e['id'] as String?) ?? '').trim();
      if (id.isEmpty) continue;
      final rawParams = e['supported_parameters'];
      if (rawParams is! Map) continue;
      try {
        final params = Map<String, dynamic>.from(rawParams);
        final ratios = _strings(
          params['aspect_ratio'] ?? params['aspect_ratios'],
        );
        final resolutions = _strings(
          params['resolution'] ?? params['resolutions'],
        );
        if (ratios.isEmpty && resolutions.isEmpty) continue;
        out[ModelIdNormalizer.normalize(id)] = ModelParameters(
          type: 'image',
          aspectRatios: ratios,
          resolutions: resolutions,
          confidence: 'high',
          isUserDefined: false,
        );
      } catch (_) {
        // Битая запись пропускается.
      }
    }
    return out;
  }

  /// Данные из кэша для модели; null — модели нет в кэше
  /// (либо кэш ещё не загружен вызовом [loadCache]).
  /// Поиск: точное совпадение нормализованного идентификатора, затем
  /// без префикса владельца ('vendor/model' -> 'model').
  static ModelParameters? getCapability(String modelId) {
    final id = ModelIdNormalizer.normalize(modelId).trim();
    final c = _cache;
    if (id.isEmpty || c == null || c.isEmpty) return null;
    final direct = c[id];
    if (direct != null) return direct;
    final short = ModelIdNormalizer.withoutProviderPrefix(id);
    return c[short];
  }
}

